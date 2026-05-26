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

    // MARK: - Vault reset lifecycle (Issue #5: stale Keychain item after reset)
    //
    // These tests exercise the observable state machine around resetVault().
    // Full keychain-level verification (item truly removed, recreation succeeds)
    // requires a signed app and is covered by the manual checklist at the bottom
    // of this file.

    /// In the test environment no Keychain item is present, so SecItemDelete
    /// returns errSecItemNotFound which resetVault maps to success (§ "already absent").
    func testResetVaultWithNilContextSucceedsWhenNoItemPresent() {
        let result = vault.resetVault(context: nil)
        if case .failure(let err) = result {
            XCTFail("resetVault must succeed when no item exists in the Keychain: \(err)")
        }
    }

    /// After a successful reset the old recovery key string must be rejected —
    /// the verification token tied to that key is gone.
    func testResetVaultOldRecoveryKeyRejectedAfterReset() {
        let originalKey = SymmetricKey(size: .bits256)
        vault.storeVerificationToken(for: originalKey)
        let oldKeyStr = vault.recoveryKeyString(from: originalKey)

        vault.resetVault(context: nil)

        XCTAssertNil(
            vault.verifyAndParseRecoveryKey(oldKeyStr),
            "Old recovery key must not validate after vault reset"
        )
    }

    /// Simulates the Create → Reset → Recreate cycle at the UserDefaults / token
    /// layer (the part that can be exercised without OS authentication).
    /// After reset a fresh vault identity can be established without interference
    /// from the previous token.
    func testResetVaultAllowsNewVerificationTokenAfterReset() {
        let key1 = SymmetricKey(size: .bits256)
        vault.storeVerificationToken(for: key1)
        vault.resetVault(context: nil)
        XCTAssertFalse(vault.hasVerificationToken, "Token must be absent after reset")

        // Re-initialise with a new key — mirrors what createMasterKey does on first unlock.
        let key2 = SymmetricKey(size: .bits256)
        vault.storeVerificationToken(for: key2)
        XCTAssertTrue(vault.hasVerificationToken, "New token must be storable after reset")

        // The new recovery key must round-trip correctly against the new token.
        let newKeyStr = vault.recoveryKeyString(from: key2)
        XCTAssertNotNil(
            vault.verifyAndParseRecoveryKey(newKeyStr),
            "New recovery key must validate after reset + re-initialisation"
        )
    }

    /// After reset + re-init the brute-force counter must be at its full quota.
    /// This guards against the counter state leaking from one vault identity to
    /// the next and causing a spurious lockout immediately after a reset.
    func testResetVaultRestoresBruteForceCounterForNewVault() {
        vault.storeVerificationToken(for: SymmetricKey(size: .bits256))
        let badKey = String(repeating: "00", count: 64)
        for _ in 0..<4 { _ = vault.verifyAndParseRecoveryKey(badKey) }
        XCTAssertEqual(vault.remainingRecoveryAttempts, 1, "Precondition: one attempt left")

        vault.resetVault(context: nil)

        // Establish the new vault identity.
        vault.storeVerificationToken(for: SymmetricKey(size: .bits256))
        XCTAssertEqual(
            vault.remainingRecoveryAttempts, 5,
            "Brute-force counter must be restored to 5 for the new vault"
        )
    }

    /// resetVault is @discardableResult — callers that don't need the result (e.g.
    /// the lost-key reset path which has no session context) must compile without
    /// a warning, and the side-effects must still apply.
    func testResetVaultDiscardableResultStillClearsState() {
        vault.storeVerificationToken(for: SymmetricKey(size: .bits256))
        vault.resetVault()   // intentionally not capturing Result
        XCTAssertFalse(vault.hasVerificationToken, "Token must be cleared even when result is discarded")
    }

    // MARK: - Recovery key verification — settings path (Issue #2)
    //
    // verifyRecoveryKey(_:) is the side-effect-free counterpart to
    // verifyAndParseRecoveryKey(_:). It performs the same cryptographic check
    // but never calls recordFailedAttempt(), never checks isRecoveryLocked,
    // and never returns the SymmetricKey. Use it for informational verification
    // in Vault Settings where the user is confirming a saved key, not recovering.

    func testVerifyRecoveryKeyReturnsTrueForValidKey() {
        let key = SymmetricKey(size: .bits256)
        vault.storeVerificationToken(for: key)
        let keyStr = vault.recoveryKeyString(from: key)
        XCTAssertTrue(vault.verifyRecoveryKey(keyStr),
                      "verifyRecoveryKey must return true for the correct key")
    }

    func testVerifyRecoveryKeyReturnsFalseForWrongKey() {
        vault.storeVerificationToken(for: SymmetricKey(size: .bits256))
        let wrongKeyStr = vault.recoveryKeyString(from: SymmetricKey(size: .bits256))
        XCTAssertFalse(vault.verifyRecoveryKey(wrongKeyStr),
                       "verifyRecoveryKey must return false for a different key")
    }

    func testVerifyRecoveryKeyReturnsFalseForEmptyInput() {
        vault.storeVerificationToken(for: SymmetricKey(size: .bits256))
        XCTAssertFalse(vault.verifyRecoveryKey(""))
    }

    func testVerifyRecoveryKeyReturnsFalseForMalformedInput() {
        vault.storeVerificationToken(for: SymmetricKey(size: .bits256))
        XCTAssertFalse(vault.verifyRecoveryKey("not-a-valid-key"))
    }

    func testVerifyRecoveryKeyAcceptsDashlessInput() {
        let key = SymmetricKey(size: .bits256)
        vault.storeVerificationToken(for: key)
        let noDashes = vault.recoveryKeyString(from: key).replacingOccurrences(of: "-", with: "")
        XCTAssertTrue(vault.verifyRecoveryKey(noDashes),
                      "verifyRecoveryKey must accept hex without dash separators")
    }

    func testVerifyRecoveryKeyAcceptsLowercaseInput() {
        let key = SymmetricKey(size: .bits256)
        vault.storeVerificationToken(for: key)
        let lower = vault.recoveryKeyString(from: key).lowercased()
        XCTAssertTrue(vault.verifyRecoveryKey(lower),
                      "verifyRecoveryKey must accept lowercase hex")
    }

    /// Core guarantee: informational verify must NEVER consume a brute-force attempt.
    func testVerifyRecoveryKeyDoesNotIncrementFailCountForInvalidKey() {
        vault.storeVerificationToken(for: SymmetricKey(size: .bits256))
        let before = vault.remainingRecoveryAttempts
        let wrongKeyStr = vault.recoveryKeyString(from: SymmetricKey(size: .bits256))

        _ = vault.verifyRecoveryKey(wrongKeyStr)

        XCTAssertEqual(vault.remainingRecoveryAttempts, before,
                       "verifyRecoveryKey must not decrement the remaining recovery attempts")
    }

    /// Even many wrong attempts via verifyRecoveryKey must not lock the recovery path.
    func testVerifyRecoveryKeyDoesNotCauseLockout() {
        vault.storeVerificationToken(for: SymmetricKey(size: .bits256))
        let wrongKeyStr = vault.recoveryKeyString(from: SymmetricKey(size: .bits256))

        // More than the lockout threshold (5) — must not lock.
        for _ in 0..<10 { _ = vault.verifyRecoveryKey(wrongKeyStr) }

        XCTAssertFalse(vault.isRecoveryLocked,
                       "verifyRecoveryKey must never trigger the brute-force lockout")
        XCTAssertEqual(vault.remainingRecoveryAttempts, 5,
                       "Remaining attempts must be untouched after verifyRecoveryKey calls")
    }

    /// Verify the independence of the two paths: verifyRecoveryKey does not
    /// interfere with verifyAndParseRecoveryKey's counter.
    func testVerifyRecoveryKeyAndParseAreCounterIndependent() {
        let realKey = SymmetricKey(size: .bits256)
        vault.storeVerificationToken(for: realKey)
        let wrongKeyStr = vault.recoveryKeyString(from: SymmetricKey(size: .bits256))

        // Exhaust verifyRecoveryKey calls — should not affect the parse counter.
        for _ in 0..<20 { _ = vault.verifyRecoveryKey(wrongKeyStr) }

        // Use one actual recovery attempt.
        _ = vault.verifyAndParseRecoveryKey(wrongKeyStr)   // consumes 1 attempt
        XCTAssertEqual(vault.remainingRecoveryAttempts, 4,
                       "Only verifyAndParseRecoveryKey may decrement the attempt counter")
    }

    /// verifyRecoveryKey must work even when the recovery lockout is active —
    /// it bypasses the lockout because it doesn't touch the counter.
    func testVerifyRecoveryKeyWorksWhenRecoveryIsLocked() {
        let realKey = SymmetricKey(size: .bits256)
        vault.storeVerificationToken(for: realKey)
        let badKey = String(repeating: "00", count: 64)

        // Trigger lockout via the real recovery path.
        for _ in 0..<5 { _ = vault.verifyAndParseRecoveryKey(badKey) }
        XCTAssertTrue(vault.isRecoveryLocked, "Precondition: vault is locked")

        // Settings verify must still work.
        let correctStr = vault.recoveryKeyString(from: realKey)
        XCTAssertTrue(vault.verifyRecoveryKey(correctStr),
                      "verifyRecoveryKey must succeed even when the recovery path is locked")
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

 [Vault security settings — Verify Saved Key (Issue #2 fix)]
 □ Gear icon visible in both locked and unlocked states
 □ Settings shows "Registered" badge when verification token exists

 UI feedback visibility (these verify the SwiftUI fix — results must persist):
 □ Paste correct key → click "Verify Key" → green banner "Recovery key is correct." appears
 □ Green banner stays visible; input field still shows the submitted key
 □ Paste wrong key → click "Verify Key" → red banner "That is not the correct recovery key." appears
 □ Red banner stays visible; input field still shows the submitted key
 □ Editing the input field clears the result banner immediately
 □ Clicking the × button on the result banner clears both the banner and the input field
 □ After dismiss, "Verify Key" button is re-enabled (input is now empty)

 Brute-force isolation (verifyRecoveryKey must not consume attempts):
 □ Enter wrong key 6× via Verify button → recovery attempts counter stays at 5
 □ "Can't unlock? Use Recovery Key" entry sheet is NOT locked after settings verify failures
 □ Entering wrong key in the recovery entry sheet DOES decrement the counter
 □ 5 wrong attempts in recovery entry sheet triggers lockout banner
 □ Settings "Verify Key" button remains enabled and functional while recovery is locked
   (recovery lockout no longer disables the settings verify path)

 Accessibility:
 □ VoiceOver on result banner reads "Verification passed. Your recovery key is correct."
   or "Verification failed. The key you entered does not match your vault."
 □ × dismiss button announces "Dismiss verification result and clear input"
 □ Paste button announces "Paste recovery key from clipboard"

 Other settings checks:
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
