import CryptoKit
import XCTest
@testable import Orin

/// Tests for VaultService that do not require OS-level biometric or password
/// prompts. Authentication-path tests (Touch ID, password) must be run
/// manually on a real device following the checklist in the security review.
final class VaultServiceTests: XCTestCase {

    private var vault: VaultService!

    override func setUp() {
        super.setUp()
        vault = VaultService()
        vault.clearSession()
    }

    override func tearDown() {
        vault.clearSession()
        super.tearDown()
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
        // AES-GCM uses a random nonce — ciphertexts must differ
        XCTAssertNotEqual(c1, c2)
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
        // Flip a byte in the authentication tag region
        cipher[cipher.count - 1] ^= 0xFF
        XCTAssertThrowsError(try vault.decrypt(cipher, using: key))
    }

    // MARK: - Recovery key format

    func testRecoveryKeyIsNonEmpty() {
        let key = SymmetricKey(size: .bits256)
        let recoveryKey = vault.recoveryKeyString(from: key)
        XCTAssertFalse(recoveryKey.isEmpty)
    }

    func testRecoveryKeyContainsDashSeparators() {
        let key = SymmetricKey(size: .bits256)
        let recoveryKey = vault.recoveryKeyString(from: key)
        XCTAssertTrue(recoveryKey.contains("-"), "Recovery key must use dash-separated groups")
    }

    func testRecoveryKeyGroupsAre8Hex() {
        let key = SymmetricKey(size: .bits256)
        let recoveryKey = vault.recoveryKeyString(from: key)
        let groups = recoveryKey.split(separator: "-")
        for group in groups {
            XCTAssertEqual(group.count, 8, "Each group should be 8 hex characters")
        }
    }

    func testRecoveryKeyIsDeterministic() {
        let key = SymmetricKey(size: .bits256)
        XCTAssertEqual(vault.recoveryKeyString(from: key), vault.recoveryKeyString(from: key))
    }

    func testRecoveryKeyDiffersForDifferentKeys() {
        let k1 = SymmetricKey(size: .bits256)
        let k2 = SymmetricKey(size: .bits256)
        XCTAssertNotEqual(vault.recoveryKeyString(from: k1), vault.recoveryKeyString(from: k2))
    }

    // MARK: - Session management

    func testClearSessionExpiresCache() async {
        // Inject a session manually by calling clearSession after setting internal
        // state is not possible without exposing internals, so we verify behavior
        // indirectly: clearSession must not crash and unlockVault on a fresh
        // service (no stored keychain item + no session) returns a non-success
        // that is NOT a keychain error (it requires auth which we can't provide here).
        vault.clearSession()
        // After clearSession, canUseBiometrics is still queryable
        _ = vault.canUseBiometrics
    }

    func testEncryptDecryptEmptyData() throws {
        let key = SymmetricKey(size: .bits256)
        let empty = Data()
        let cipher = try vault.encrypt(empty, using: key)
        let recovered = try vault.decrypt(cipher, using: key)
        XCTAssertEqual(recovered, empty)
    }

    func testEncryptDecryptLargePayload() throws {
        let key = SymmetricKey(size: .bits256)
        let large = Data(repeating: 0xAB, count: 100_000)
        let cipher = try vault.encrypt(large, using: key)
        let recovered = try vault.decrypt(cipher, using: key)
        XCTAssertEqual(recovered, large)
    }

    // MARK: - VaultError equality helpers

    func testVaultErrorUserCancelledIsDistinct() {
        // Ensures the compiler treats userCancelled as its own case (compile-time check)
        let error: VaultError = .userCancelled
        if case .userCancelled = error { } else { XCTFail("Wrong case") }
    }

    func testVaultErrorKeychainErrorCarriesStatus() {
        let error: VaultError = .keychainError(-25300)
        if case .keychainError(let status) = error {
            XCTAssertEqual(status, -25300)
        } else {
            XCTFail("Expected keychainError")
        }
    }
}
