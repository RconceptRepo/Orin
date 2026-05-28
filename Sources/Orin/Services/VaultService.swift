import CryptoKit
import Foundation
import LocalAuthentication
import OSLog
import Security

enum VaultError: Error {
    /// User dismissed the authentication prompt — no error should be shown.
    case userCancelled
    /// Authentication failed after all available methods were tried.
    case authenticationFailed
    /// A Security framework error occurred during keychain access.
    case keychainError(OSStatus)
}

enum VaultState: String {
    case locked
    case unlocked
    case resetting
    case corrupted
    case recoveryRequired
}

final class VaultService: Service {

    // MARK: - Constants

    private let keychainServiceKey      = "com.orin.vault.masterkey"
    private let verificationTokenUDKey  = "orin.vault.verificationToken"
    private let failCountUDKey          = "orin.vault.recovery.failCount"
    private let lockoutUntilUDKey       = "orin.vault.recovery.lockoutUntil"
    private let maxAttempts             = 5
    private let lockoutDuration: TimeInterval = 1800   // 30 minutes
    private let sessionDuration: TimeInterval = 300    // 5 minutes
    private let logger = Logger(subsystem: "com.clavrit.orin", category: "Vault")

    // MARK: - Session (in-process RAM only; CryptoKit zeroes on dealloc)

    private var sessionKey: SymmetricKey?
    private var sessionExpiry: Date = .distantPast
    /// The `LAContext` that was evaluated when the vault was last unlocked.
    /// Retained so that `resetVault()` can include it in the `SecItemDelete`
    /// query, allowing the Keychain daemon to authorise deletion of an item
    /// protected by `.userPresence` access control without a new prompt.
    private var sessionContext: LAContext?

    // MARK: - Public API

    var canUseBiometrics: Bool {
        let ctx = LAContext()
        var error: NSError?
        return ctx.canEvaluatePolicy(.deviceOwnerAuthenticationWithBiometrics, error: &error)
    }

    /// Clears the in-process session. Call when the user explicitly locks the vault.
    func clearSession() {
        logger.info("Vault session cleared")
        sessionKey = nil
        sessionExpiry = .distantPast
        sessionContext = nil
    }

    /// Authenticates the user and returns the vault master key.
    /// Returns a cached session key within the 5-minute window.
    func unlockVault() async -> Result<SymmetricKey, VaultError> {
        logger.info("Vault unlock attempt")
        if let key = sessionKey, Date() < sessionExpiry {
            logger.info("Vault unlock used cached session")
            return .success(key)
        }
        let result = await authenticate()
        if case .success(let key) = result {
            sessionKey = key
            sessionExpiry = Date().addingTimeInterval(sessionDuration)
            logger.info("Vault unlock succeeded")
        } else {
            logger.error("Vault unlock failed")
        }
        return result
    }

    func currentState(hasVaultItems: Bool) -> VaultState {
        if sessionKey != nil, Date() < sessionExpiry { return .unlocked }
        // No keychain item AND no verification token = never set up
        if !hasVerificationToken && !hasKeychainItem() { return .locked }  // treat as locked (will self-initialize on first unlock)
        if hasVaultItems && !hasVerificationToken { return .corrupted }
        if !hasKeychainItem() { return .recoveryRequired }
        return .locked
    }

    // MARK: - Recovery key lifecycle

    var hasVerificationToken: Bool {
        UserDefaults.standard.string(forKey: verificationTokenUDKey) != nil
    }

    var isRecoveryLocked: Bool {
        guard let until = UserDefaults.standard.object(forKey: lockoutUntilUDKey) as? Date else {
            return false
        }
        return Date() < until
    }

    var recoveryLockoutUntil: Date? {
        guard isRecoveryLocked else { return nil }
        return UserDefaults.standard.object(forKey: lockoutUntilUDKey) as? Date
    }

    var remainingRecoveryAttempts: Int {
        let used = UserDefaults.standard.integer(forKey: failCountUDKey)
        return max(0, maxAttempts - used)
    }

    /// Stores an HMAC-SHA256 verification token in UserDefaults.
    /// This is NOT the key — it is a one-way MAC that proves knowledge of
    /// the key without revealing it. Safe to store without protection.
    func storeVerificationToken(for key: SymmetricKey) {
        UserDefaults.standard.set(computeToken(for: key), forKey: verificationTokenUDKey)
        logger.info("Vault recovery verification token stored")
    }

    /// Cryptographically checks whether a user-entered recovery key string is
    /// valid **without** touching the brute-force counter or the lockout state.
    ///
    /// Use this for informational verification (Vault Settings → "Verify Saved Key")
    /// where the user is confirming a key they have already saved. Because this
    /// path does not increment `recordFailedAttempt()`, it cannot exhaust the
    /// allowed recovery attempts and does not need to respect `isRecoveryLocked`.
    ///
    /// For an actual vault-recovery operation (unlocking a locked vault), use
    /// `verifyAndParseRecoveryKey(_:)` which enforces brute-force protections.
    func verifyRecoveryKey(_ input: String) -> Bool {
        guard let keyData = parseRecoveryKeyData(input) else { return false }
        let candidate = SymmetricKey(data: keyData)
        return computeToken(for: candidate) ==
               UserDefaults.standard.string(forKey: verificationTokenUDKey)
    }

    /// Validates a user-entered recovery key string.
    /// Returns the SymmetricKey on success, nil on failure.
    /// Increments the brute-force counter only for semantically valid but wrong keys.
    func verifyAndParseRecoveryKey(_ input: String) -> SymmetricKey? {
        guard !isRecoveryLocked else { return nil }
        // Parse failures (wrong format, length) are not brute-force attempts
        guard let keyData = parseRecoveryKeyData(input) else { return nil }
        let candidate = SymmetricKey(data: keyData)
        guard computeToken(for: candidate) ==
              UserDefaults.standard.string(forKey: verificationTokenUDKey) else {
            recordFailedAttempt()  // Only count semantically valid but wrong keys
            return nil
        }
        resetFailCount()
        return candidate
    }

    /// Re-authenticates and stores the recovered master key back into the keychain
    /// so subsequent unlocks use biometrics/password as normal.
    func relinkToKeychain(_ key: SymmetricKey) async -> Result<Void, VaultError> {
        let context = LAContext()
        context.touchIDAuthenticationAllowableReuseDuration = sessionDuration

        do {
            let reason = canUseBiometrics
                ? "Use Touch ID or your password to re-link your Orin Vault."
                : "Enter your password to re-link your Orin Vault."
            try await context.evaluatePolicy(.deviceOwnerAuthentication, localizedReason: reason)
        } catch let laError as LAError {
            switch laError.code {
            case .userCancel, .appCancel, .systemCancel:
                return .failure(.userCancelled)
            default:
                return .failure(.authenticationFailed)
            }
        } catch {
            return .failure(.authenticationFailed)
        }

        // Delete any existing item, then write the fresh key.
        let deleteQuery: [String: Any] = [
            kSecClass as String:       kSecClassGenericPassword,
            kSecAttrService as String: keychainServiceKey
        ]
        SecItemDelete(deleteQuery as CFDictionary)

        do {
            try storeMasterKey(key, context: context)
        } catch let vaultError as VaultError {
            return .failure(vaultError)
        } catch {
            return .failure(.authenticationFailed)
        }

        sessionKey = key
        sessionExpiry = Date().addingTimeInterval(sessionDuration)
        sessionContext = context
        return .success(())
    }

    /// Removes the master key from the Keychain and resets all vault state.
    ///
    /// Encrypted items in SwiftData must be deleted by the caller — they cannot
    /// be decrypted after this call returns `.success`.
    ///
    /// - Returns: `.success(())` when the item was deleted or was already absent.
    @discardableResult
    func resetVault(context: LAContext? = nil) -> Result<Void, VaultError> {
        logger.warning("Vault reset started")
        let deleteQuery: [String: Any] = [
            kSecClass as String:       kSecClassGenericPassword,
            kSecAttrService as String: keychainServiceKey
        ]
        let deleteStatus = SecItemDelete(deleteQuery as CFDictionary)
        guard deleteStatus == errSecSuccess || deleteStatus == errSecItemNotFound else {
            logger.error("Vault keychain delete failed status=\(deleteStatus)")
            return .failure(.keychainError(deleteStatus))
        }
        UserDefaults.standard.removeObject(forKey: verificationTokenUDKey)
        resetFailCount()
        clearSession()
        logger.warning("Vault reset cleared keychain and recovery state")
        return .success(())
    }

    func resetAndRegenerateVault() -> Result<(key: SymmetricKey, recoveryKey: String), VaultError> {
        switch resetVault() {
        case .failure(let error):
            return .failure(error)
        case .success:
            let key = SymmetricKey(size: .bits256)
            do {
                try storeMasterKey(key, context: nil)
                storeVerificationToken(for: key)
                sessionKey = key
                sessionExpiry = Date().addingTimeInterval(sessionDuration)
                let recoveryKey = recoveryKeyString(from: key)
                logger.warning("Vault reset regenerated clean key and recovery key")
                return .success((key, recoveryKey))
            } catch let vaultError as VaultError {
                logger.error("Vault reset key regeneration failed")
                return .failure(vaultError)
            } catch {
                logger.error("Vault reset key regeneration failed with unknown error")
                return .failure(.authenticationFailed)
            }
        }
    }

    // MARK: - Encryption (AES-GCM, 256-bit)

    func encrypt(_ data: Data, using key: SymmetricKey) throws -> Data {
        try AES.GCM.seal(data, using: key).combined ?? Data()
    }

    func decrypt(_ cipherText: Data, using key: SymmetricKey) throws -> Data {
        let sealedBox = try AES.GCM.SealedBox(combined: cipherText)
        return try AES.GCM.open(sealedBox, using: key)
    }

    /// Returns the master key as dash-grouped uppercase hex (8 chars per group).
    /// This string IS the recovery key — handle with the same care as the key itself.
    func recoveryKeyString(from key: SymmetricKey) -> String {
        let hex = key.withUnsafeBytes { Data($0) }
            .map { String(format: "%02X", $0) }
            .joined()
        var result = ""
        for (i, char) in hex.enumerated() {
            if i > 0 && i % 8 == 0 { result += "-" }
            result.append(char)
        }
        return result
    }

    // MARK: - Authentication flow

    /// Authenticates the user and returns the vault master key.
    ///
    /// Uses `.deviceOwnerAuthentication` which presents Touch ID first on Macs
    /// that support it, then automatically falls back to the login password if
    /// biometrics fail or are unavailable — no separate fallback path needed.
    private func authenticate() async -> Result<SymmetricKey, VaultError> {
        let context = LAContext()
        context.touchIDAuthenticationAllowableReuseDuration = sessionDuration

        let reason = canUseBiometrics
            ? "Use Touch ID or enter your password to unlock your Orin Vault."
            : "Enter your password to unlock your Orin Vault."

        do {
            try await context.evaluatePolicy(.deviceOwnerAuthentication, localizedReason: reason)
            let key = try masterKey(context: context)
            sessionContext = context
            logger.info("Vault unlock succeeded")
            return .success(key)
        } catch let laError as LAError {
            switch laError.code {
            case .userCancel, .appCancel, .systemCancel:
                logger.info("Vault authentication cancelled by user")
                return .failure(.userCancelled)
            default:
                logger.error("Vault authentication failed: \(laError.localizedDescription)")
                return .failure(.authenticationFailed)
            }
        } catch let vaultError as VaultError {
            logger.error("Vault keychain failure after authentication")
            return .failure(vaultError)
        } catch {
            logger.error("Vault unknown failure: \(error)")
            return .failure(.authenticationFailed)
        }
    }

    // MARK: - Keychain master key

    private func masterKey(context: LAContext) throws -> SymmetricKey {
        let readQuery: [String: Any] = [
            kSecClass as String:                    kSecClassGenericPassword,
            kSecAttrService as String:              keychainServiceKey,
            kSecReturnData as String:               true,
            kSecUseAuthenticationContext as String: context
        ]

        var result: AnyObject?
        let status = SecItemCopyMatching(readQuery as CFDictionary, &result)

        if status == errSecSuccess, let keyData = result as? Data {
            return SymmetricKey(data: keyData)
        }
        guard status == errSecItemNotFound else {
            logger.error("Vault keychain read failed status=\(status)")
            throw VaultError.keychainError(status)
        }

        // If a verification token exists, the vault was previously set up but the
        // keychain item is gone. Signal recovery is needed instead of silently
        // creating a new incompatible key.
        if hasVerificationToken {
            logger.warning("Vault keychain item missing but verification token exists — recovery required")
            throw VaultError.keychainError(errSecItemNotFound)
        }

        return try createMasterKey(context: context)
    }

    private func createMasterKey(context: LAContext) throws -> SymmetricKey {
        let key = SymmetricKey(size: .bits256)
        try storeMasterKey(key, context: context)
        // Store verification token immediately so recovery works from first unlock.
        storeVerificationToken(for: key)
        logger.info("Vault master key created")
        return key
    }

    private func storeMasterKey(_ key: SymmetricKey, context: LAContext?) throws {
        let keyData = key.withUnsafeBytes { Data($0) }

        // Store with kSecAttrAccessibleWhenUnlockedThisDeviceOnly (device-bound,
        // not migratable, cleared when device is unenrolled).
        // User-presence is enforced at the app layer: authenticate() is always
        // called before any masterKey() read. This avoids kSecAccessControl with
        // .userPresence which requires a Developer Team ID (fails on ad-hoc builds).
        var addQuery: [String: Any] = [
            kSecClass as String:          kSecClassGenericPassword,
            kSecAttrService as String:    keychainServiceKey,
            kSecValueData as String:      keyData,
            kSecAttrAccessible as String: kSecAttrAccessibleWhenUnlockedThisDeviceOnly
        ]
        if let context {
            addQuery[kSecUseAuthenticationContext as String] = context
        }

        let addStatus = SecItemAdd(addQuery as CFDictionary, nil)
        guard addStatus == errSecSuccess else {
            logger.error("Vault keychain add failed status=\(addStatus)")
            throw VaultError.keychainError(addStatus)
        }
        logger.info("Vault master key stored in keychain")
    }

    private func hasKeychainItem() -> Bool {
        let query: [String: Any] = [
            kSecClass as String:       kSecClassGenericPassword,
            kSecAttrService as String: keychainServiceKey,
            kSecReturnAttributes as String: true,
            kSecUseAuthenticationUI as String: kSecUseAuthenticationUISkip
        ]
        var result: AnyObject?
        let status = SecItemCopyMatching(query as CFDictionary, &result)
        return status == errSecSuccess || status == errSecInteractionNotAllowed
    }

    // MARK: - Recovery helpers (private)

    /// HMAC-SHA256 of a fixed label using the master key as the HMAC key.
    /// One-way: storing this reveals nothing about the key.
    private func computeToken(for key: SymmetricKey) -> String {
        let mac = HMAC<SHA256>.authenticationCode(
            for: Data("orin.vault.verify.v1".utf8),
            using: key
        )
        return Data(mac).base64EncodedString()
    }

    /// Parses a user-entered recovery key string into raw key bytes.
    /// Strips dashes and spaces, normalises to uppercase, validates length.
    private func parseRecoveryKeyData(_ input: String) -> Data? {
        let hex = input
            .replacingOccurrences(of: "-", with: "")
            .replacingOccurrences(of: " ", with: "")
            .uppercased()
        guard hex.count == 64 else { return nil }
        var data = Data(capacity: 32)
        var idx = hex.startIndex
        while idx < hex.endIndex {
            let next = hex.index(idx, offsetBy: 2)
            guard let byte = UInt8(hex[idx..<next], radix: 16) else { return nil }
            data.append(byte)
            idx = next
        }
        return data.count == 32 ? data : nil
    }

    private func recordFailedAttempt() {
        let count = UserDefaults.standard.integer(forKey: failCountUDKey) + 1
        UserDefaults.standard.set(count, forKey: failCountUDKey)
        if count >= maxAttempts {
            let until = Date().addingTimeInterval(lockoutDuration)
            UserDefaults.standard.set(until, forKey: lockoutUntilUDKey)
            UserDefaults.standard.set(0, forKey: failCountUDKey)
        }
    }

    private func resetFailCount() {
        UserDefaults.standard.removeObject(forKey: failCountUDKey)
        UserDefaults.standard.removeObject(forKey: lockoutUntilUDKey)
    }
}
