import CryptoKit
import XCTest
@testable import Orin

/// Tests for VaultService that do not require OS-level biometric or password
/// prompts. Authentication-path tests (Touch ID, password) must be run
/// manually on a real device following the checklist at the bottom of this file.
final class VaultServiceTests: XCTestCase {

    private var vault: VaultService!

    // Isolation: each test uses its own UserDefaults keys via a fresh VaultService.
    // The real app's UserDefaults keys are under "orin.vault.*"; these tests write
    // to the same keys but tearDown removes them unconditionally.

    override func setUp() {
        super.setUp()
        vault = VaultService()
        vault.clearSession()
        cleanUserDefaults()
    }

    override func tearDown() {
        vault.clearSession()
        cleanUserDefaults()
        super.tearDown()
    }

    private func cleanUserDefaults() {
        UserDefaults.standard.removeObject(forKey: "orin.vault.verificationToken")
        UserDefaults.standard.removeObject(forKey: "orin.vault.recovery.failCount")
        UserDefaults.standard.removeObject(forKey: "orin.vault.recovery.lockoutUntil")
    }

    // MARK: - Encryption round-trip

    func testEncryptDecryptRoundTrip() throws {
        let key = SymmetricKey(size: .bits256)
        let original = Data("super-secret-value".utf8)
        let cipher = try vault.encrypt(original, using: key)
        let recovered = try vault.decrypt(cipher, using: key)
        XCTAssertEqual(recovered, original)
    }

    func testEncryptProducesDifferentCiphertextEachCall() throws {
        let key = SymmetricKey(size: .bits256)
        let data = Data("same-input".utf8)
        let c1 = try vault.encrypt(data, using: key)
        let c2 = try vault.encrypt(data, using: key)
        XCTAssertNotEqual(c1, c2, "AES-GCM random nonce — ciphertexts must differ")
    }

    func testDecryptWithWrongKeyThrows() throws {
        let key1 = SymmetricKey(size: .bits256)
        let key2 = SymmetricKey(size: .bits256)
        let cipher = try vault.encrypt(Data("secret".utf8), using: key1)
        XCTAssertThrowsError(try vault.decrypt(cipher, using: key2))
    }

    func testDecryptCorruptedCiphertextThrows() throws {
        let key = SymmetricKey(size: .bits256)
        var cipher = try vault.encrypt(Data("secret".utf8), using: key)
        cipher[cipher.count - 1] ^= 0xFF  // flip a byte in the auth tag
        XCTAssertThrowsError(try vault.decrypt(cipher, using: key))
    }

    func testEncryptDecryptEmptyData() throws {
        let key = SymmetricKey(size: .bits256)
        let cipher = try vault.encrypt(Data(), using: key)
        XCTAssertEqual(try vault.decrypt(cipher, using: key), Data())
    }

    func testEncryptDecryptLargePayload() throws {
        let key = SymmetricKey(size: .bits256)
        let large = Data(repeating: 0xAB, count: 100_000)
        XCTAssertEqual(try vault.decrypt(try vault.encrypt(large, using: key), using: key), large)
    }

    // MARK: - Recovery key format

    func testRecoveryKeyIsNonEmpty() {
        XCTAssertFalse(vault.recoveryKeyString(from: SymmetricKey(size: .bits256)).isEmpty)
    }

    func testRecoveryKeyContainsDashSeparators() {
        let s = vault.recoveryKeyString(from: SymmetricKey(size: .bits256))
        XCTAssertTrue(s.contains("-"))
    }

    func testRecoveryKeyGroupsAre8HexChars() {
        let groups = vault.recoveryKeyString(from: SymmetricKey(size: .bits256)).split(separator: "-")
        XCTAssertEqual(groups.count, 8)
        for g in groups { XCTAssertEqual(g.count, 8) }
    }

    func testRecoveryKeyIs8Groups() {
        let key = SymmetricKey(size: .bits256)
        let groups = vault.recoveryKeyString(from: key).split(separator: "-")
        XCTAssertEqual(groups.count, 8, "256-bit key → 64 hex chars → 8 groups of 8")
    }

    func testRecoveryKeyIsDeterministic() {
        let key = SymmetricKey(size: .bits256)
        XCTAssertEqual(vault.recoveryKeyString(from: key), vault.recoveryKeyString(from: key))
    }

    func testRecoveryKeyDiffersForDifferentKeys() {
        XCTAssertNotEqual(
            vault.recoveryKeyString(from: SymmetricKey(size: .bits256)),
            vault.recoveryKeyString(from: SymmetricKey(size: .bits256))
        )
    }

    // MARK: - Verification token

    func testStoreVerificationTokenSetsFlag() {
        XCTAssertFalse(vault.hasVerificationToken)
        vault.storeVerificationToken(for: SymmetricKey(size: .bits256))
        XCTAssertTrue(vault.hasVerificationToken)
    }

    func testVerificationTokenIsDeterministic() {
        let key = SymmetricKey(size: .bits256)
        vault.storeVerificationToken(for: key)
        let t1 = UserDefaults.standard.string(forKey: "orin.vault.verificationToken")
        vault.storeVerificationToken(for: key)
        let t2 = UserDefaults.standard.string(forKey: "orin.vault.verificationToken")
        XCTAssertEqual(t1, t2, "Same key must always produce the same HMAC")
    }

    func testVerificationTokenDiffersForDifferentKeys() {
        let k1 = SymmetricKey(size: .bits256)
        let k2 = SymmetricKey(size: .bits256)
        vault.storeVerificationToken(for: k1)
        let t1 = UserDefaults.standard.string(forKey: "orin.vault.verificationToken")
        vault.storeVerificationToken(for: k2)
        let t2 = UserDefaults.standard.string(forKey: "orin.vault.verificationToken")
        XCTAssertNotEqual(t1, t2)
    }

    func testResetVaultClearsVerificationToken() {
        vault.storeVerificationToken(for: SymmetricKey(size: .bits256))
        XCTAssertTrue(vault.hasVerificationToken)
        vault.resetVault()
        XCTAssertFalse(vault.hasVerificationToken)
    }

    // MARK: - Recovery key validation (generate → verify round-trip)

    func testValidRecoveryKeyRoundTrip() {
        let key = SymmetricKey(size: .bits256)
        vault.storeVerificationToken(for: key)
        let keyStr = vault.recoveryKeyString(from: key)
        let recovered = vault.verifyAndParseRecoveryKey(keyStr)
        XCTAssertNotNil(recovered, "Correct key must parse successfully")
    }

    func testRecoveredKeyMatchesOriginal() throws {
        let key = SymmetricKey(size: .bits256)
        vault.storeVerificationToken(for: key)
        let keyStr = vault.recoveryKeyString(from: key)
        guard let recovered = vault.verifyAndParseRecoveryKey(keyStr) else {
            return XCTFail("Recovery key did not parse")
        }
        // Encrypt with original, decrypt with recovered — they must be equal
        let plaintext = Data("round-trip-test".utf8)
        let cipher = try vault.encrypt(plaintext, using: key)
        let decrypted = try vault.decrypt(cipher, using: recovered)
        XCTAssertEqual(decrypted, plaintext)
    }

    func testRecoveryKeyWithoutDashesIsAccepted() {
        let key = SymmetricKey(size: .bits256)
        vault.storeVerificationToken(for: key)
        let withoutDashes = vault.recoveryKeyString(from: key).replacingOccurrences(of: "-", with: "")
        XCTAssertNotNil(vault.verifyAndParseRecoveryKey(withoutDashes))
    }

    func testRecoveryKeyLowercaseIsAccepted() {
        let key = SymmetricKey(size: .bits256)
        vault.storeVerificationToken(for: key)
        let lower = vault.recoveryKeyString(from: key).lowercased()
        XCTAssertNotNil(vault.verifyAndParseRecoveryKey(lower))
    }

    // MARK: - Invalid recovery key rejection

    func testWrongKeyIsRejected() {
        vault.storeVerificationToken(for: SymmetricKey(size: .bits256))
        let wrongKey = vault.recoveryKeyString(from: SymmetricKey(size: .bits256))
        XCTAssertNil(vault.verifyAndParseRecoveryKey(wrongKey), "Different key must be rejected")
    }

    func testEmptyInputIsRejected() {
        vault.storeVerificationToken(for: SymmetricKey(size: .bits256))
        XCTAssertNil(vault.verifyAndParseRecoveryKey(""))
    }

    func testTooShortInputIsRejected() {
        vault.storeVerificationToken(for: SymmetricKey(size: .bits256))
        XCTAssertNil(vault.verifyAndParseRecoveryKey("AABBCCDD"))
    }

    func testTooLongInputIsRejected() {
        vault.storeVerificationToken(for: SymmetricKey(size: .bits256))
        XCTAssertNil(vault.verifyAndParseRecoveryKey(String(repeating: "A", count: 66)))
    }

    func testNonHexInputIsRejected() {
        vault.storeVerificationToken(for: SymmetricKey(size: .bits256))
        XCTAssertNil(vault.verifyAndParseRecoveryKey(String(repeating: "Z", count: 64)))
    }

    func testSingleBitFlipIsRejected() {
        let key = SymmetricKey(size: .bits256)
        vault.storeVerificationToken(for: key)
        var keyStr = vault.recoveryKeyString(from: key)
        // Flip the last hex character
        let last = keyStr.last!
        let flipped: Character = last == "F" ? "E" : "F"
        keyStr.replaceSubrange(keyStr.index(before: keyStr.endIndex)..., with: [flipped])
        XCTAssertNil(vault.verifyAndParseRecoveryKey(keyStr))
    }

    // MARK: - Brute-force protection

    func testFailedAttemptsIncrementCounter() {
        vault.storeVerificationToken(for: SymmetricKey(size: .bits256))
        let before = vault.remainingRecoveryAttempts
        _ = vault.verifyAndParseRecoveryKey("AABBCCDD" + String(repeating: "00", count: 28))
        XCTAssertEqual(vault.remainingRecoveryAttempts, before - 1)
    }

    func testFiveFailuresTriggersLockout() {
        vault.storeVerificationToken(for: SymmetricKey(size: .bits256))
        let badKey = String(repeating: "00", count: 64)
        for _ in 0..<5 {
            _ = vault.verifyAndParseRecoveryKey(badKey)
        }
        XCTAssertTrue(vault.isRecoveryLocked, "5 failures must lock recovery")
    }

    func testLockedVaultRejectsCorrectKey() {
        let key = SymmetricKey(size: .bits256)
        vault.storeVerificationToken(for: key)
        let badKey = String(repeating: "00", count: 64)
        for _ in 0..<5 {
            _ = vault.verifyAndParseRecoveryKey(badKey)
        }
        XCTAssertTrue(vault.isRecoveryLocked)
        // Even the correct key is rejected when locked
        let correctKeyStr = vault.recoveryKeyString(from: key)
        XCTAssertNil(vault.verifyAndParseRecoveryKey(correctKeyStr))
    }

    func testLockoutUntilIsFutureDate() {
        vault.storeVerificationToken(for: SymmetricKey(size: .bits256))
        let badKey = String(repeating: "00", count: 64)
        for _ in 0..<5 { _ = vault.verifyAndParseRecoveryKey(badKey) }
        if let until = vault.recoveryLockoutUntil {
            XCTAssertGreaterThan(until, Date())
        } else {
            XCTFail("Expected a lockout date after 5 failures")
        }
    }

    func testSuccessfulRecoveryResetsFailCount() {
        let key = SymmetricKey(size: .bits256)
        vault.storeVerificationToken(for: key)
        let badKey = String(repeating: "00", count: 64)
        // Use 4 out of 5 allowed attempts
        for _ in 0..<4 { _ = vault.verifyAndParseRecoveryKey(badKey) }
        XCTAssertFalse(vault.isRecoveryLocked)
        // Correct key should succeed and reset the counter
        _ = vault.verifyAndParseRecoveryKey(vault.recoveryKeyString(from: key))
        XCTAssertEqual(vault.remainingRecoveryAttempts, 5, "Counter must reset after success")
    }

    func testResetVaultClearsLockoutState() {
        vault.storeVerificationToken(for: SymmetricKey(size: .bits256))
        let badKey = String(repeating: "00", count: 64)
        for _ in 0..<5 { _ = vault.verifyAndParseRecoveryKey(badKey) }
        XCTAssertTrue(vault.isRecoveryLocked)
        vault.resetVault()
        XCTAssertFalse(vault.isRecoveryLocked)
    }

    // MARK: - Session management

    func testClearSessionDoesNotCrash() {
        vault.clearSession()
        vault.clearSession()   // idempotent
    }

    func testCanUseBiometricsIsQueryable() {
        _ = vault.canUseBiometrics  // Should not crash; result varies by machine
    }

    // MARK: - VaultError cases

    func testVaultErrorUserCancelledIsDistinct() {
        let error: VaultError = .userCancelled
        if case .userCancelled = error { } else { XCTFail("Wrong case") }
    }

    func testVaultErrorAuthenticationFailedIsDistinct() {
        let error: VaultError = .authenticationFailed
        if case .authenticationFailed = error { } else { XCTFail("Wrong case") }
    }

    func testVaultErrorKeychainErrorCarriesStatus() {
        let error: VaultError = .keychainError(-25300)
        if case .keychainError(let s) = error { XCTAssertEqual(s, -25300) }
        else { XCTFail("Expected keychainError") }
    }
}

/*
 MANUAL TESTING CHECKLIST
 ========================
 These scenarios require real Touch ID hardware and cannot be automated.

 [First unlock]
 □ Launch fresh install → unlock → recovery key onboarding sheet appears
 □ Sheet shows complete 64-char key in 8 dash-separated groups
 □ Copy button copies exact key to clipboard
 □ Export button opens save panel, saved .txt file contains key + instructions
 □ Print button opens macOS print dialog with formatted recovery sheet
 □ "Done" button is disabled until toggle is confirmed
 □ After confirmation, sheet dismisses and doesn't appear again on subsequent unlocks

 [Touch ID available]
 □ Locked vault → "Unlock with Touch ID" label → single Touch ID prompt → unlocked
 □ No password prompt appears after Touch ID succeeds
 □ "Can't unlock? Use Recovery Key" link is visible in locked state

 [Touch ID disabled / not enrolled]
 □ Button label changes to "Unlock" (no Touch ID mention)
 □ Locked state description reads the password variant
 □ Single password dialog, no Touch ID sheet

 [Touch ID locked after 5 failures]
 □ Fail Touch ID 5 times → macOS locks it
 □ "Can't unlock?" flow works as password fallback
 □ Vault unlocks normally with password

 [Recovery key unlock]
 □ Tap "Can't unlock? Use Recovery Key"
 □ Entry sheet appears with instructions and paste button
 □ Paste works and normalises to uppercase
 □ Lowercase input accepted (normalised internally)
 □ Key with dashes accepted
 □ Key without dashes accepted
 □ Wrong key shows "That recovery key is incorrect." message
 □ Remaining attempts counter decrements on each failure
 □ 5 failures triggers lockout banner with live countdown timer
 □ Lockout banner shows MM:SS countdown
 □ After lockout expires, entry is accepted again
 □ Correct key unlocks vault, recovery banner appears at top of vault

 [Re-link after recovery]
 □ Recovery banner shows "Re-link to Touch ID" button
 □ Tapping Re-link shows VaultRelinkView sheet
 □ Re-link with Touch ID: single Touch ID prompt → "Re-linked successfully"
 □ Skip for Now: closes sheet, vault remains unlocked
 □ After re-link, subsequent unlock uses Touch ID (no recovery key needed)

 [Lost recovery key]
 □ Entry sheet → "I've lost my recovery key" link → VaultLostKeyView
 □ Lost key view explains data is unrecoverable
 □ "I Found My Key" returns to entry view
 □ "Create a New Vault" → VaultResetConfirmView
 □ Confirm view requires typing DELETE to enable button
 □ Typing DELETE enables red button; confirmation deletes all items and resets vault
 □ After reset, fresh unlock shows new recovery key onboarding

 [Vault security settings]
 □ Gear icon visible in both locked and unlocked states
 □ Settings shows "Registered" badge when verification token exists
 □ Verify key section accepts correct key → green "valid" message
 □ Verify key section rejects wrong key → red "incorrect" message
 □ Verify uses the brute-force counter (5 wrong attempts → locked)
 □ "Re-export Recovery Key" only enabled when vault is unlocked
 □ Re-export shows full onboarding sheet with export/print options
 □ Reset Vault button only enabled when vault is unlocked
 □ Reset Vault → confirm → deletes all items, generates new key, shows onboarding

 [App restart]
 □ Unlock → Lock → restart app → fresh Touch ID prompt on next unlock
 □ Session does not persist across process restarts
 □ Verification token persists in UserDefaults across restarts
 □ Lockout persists across restarts (lockout timestamp survives in UserDefaults)

 [Existing vault migration]
 □ First unlock on a vault created before this feature stores the verification token
 □ hasVerificationToken is true after the migrating unlock
 □ Subsequent recovery key entry works immediately after migration
 */
