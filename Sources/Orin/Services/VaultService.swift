import CryptoKit
import Foundation
import LocalAuthentication
import Security

enum VaultError: Error {
    /// User dismissed the authentication prompt — no error should be shown.
    case userCancelled
    /// Authentication failed after all available methods were tried.
    case authenticationFailed
    /// A Security framework error occurred during keychain access.
    case keychainError(OSStatus)
}

final class VaultService: Service {
    private let keychainServiceKey = "com.orin.vault.masterkey"

    // 5-minute in-process session: avoids re-prompting on tab switches /
    // view recreations. The SymmetricKey lives in process RAM only — it is
    // never written to disk in plaintext. CryptoKit zeroes it on dealloc.
    private let sessionDuration: TimeInterval = 300
    private var sessionKey: SymmetricKey?
    private var sessionExpiry: Date = .distantPast

    // MARK: - Public API

    var canUseBiometrics: Bool {
        let ctx = LAContext()
        var error: NSError?
        return ctx.canEvaluatePolicy(.deviceOwnerAuthenticationWithBiometrics, error: &error)
    }

    /// Clears the in-process session. Call when the user explicitly locks the vault
    /// so that reopening the view requires re-authentication.
    func clearSession() {
        sessionKey = nil
        sessionExpiry = .distantPast
    }

    /// Authenticates the user and returns the vault master key.
    /// Biometrics are tried first; password fallback is automatic on lockout
    /// or when biometrics are unavailable. A cached session is returned
    /// immediately within the 5-minute window.
    func unlockVault() async -> Result<SymmetricKey, VaultError> {
        if let key = sessionKey, Date() < sessionExpiry {
            return .success(key)
        }

        let result = await authenticate()
        if case .success(let key) = result {
            sessionKey = key
            sessionExpiry = Date().addingTimeInterval(sessionDuration)
        }
        return result
    }

    // MARK: - Encryption (AES-GCM, 256-bit)

    func encrypt(_ data: Data, using key: SymmetricKey) throws -> Data {
        try AES.GCM.seal(data, using: key).combined ?? Data()
    }

    func decrypt(_ cipherText: Data, using key: SymmetricKey) throws -> Data {
        let sealedBox = try AES.GCM.SealedBox(combined: cipherText)
        return try AES.GCM.open(sealedBox, using: key)
    }

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

    private func authenticate() async -> Result<SymmetricKey, VaultError> {
        let context = LAContext()
        // Allow OS to reuse a recent biometric within the session window —
        // prevents a redundant Touch ID sheet if the user just authenticated.
        context.touchIDAuthenticationAllowableReuseDuration = sessionDuration

        var biometricError: NSError?
        let biometricsAvailable = context.canEvaluatePolicy(
            .deviceOwnerAuthenticationWithBiometrics, error: &biometricError
        )

        if biometricsAvailable {
            return await tryBiometrics(context: context)
        }

        // Biometrics unavailable — fall directly to password.
        return await tryPassword(context: context, lockedOut: false)
    }

    private func tryBiometrics(context: LAContext) async -> Result<SymmetricKey, VaultError> {
        do {
            try await context.evaluatePolicy(
                .deviceOwnerAuthenticationWithBiometrics,
                localizedReason: "Use Touch ID to unlock your Orin Vault."
            )
            let key = try masterKey(context: context)
            return .success(key)
        } catch let laError as LAError {
            switch laError.code {
            case .userCancel, .appCancel, .systemCancel:
                return .failure(.userCancelled)
            case .biometryLockout:
                // Touch ID locked after repeated failures — fall back to password
                // automatically so the user has a recovery path.
                return await tryPassword(context: LAContext(), lockedOut: true)
            default:
                return .failure(.authenticationFailed)
            }
        } catch let vaultError as VaultError {
            return .failure(vaultError)
        } catch {
            return .failure(.authenticationFailed)
        }
    }

    private func tryPassword(context: LAContext, lockedOut: Bool) async -> Result<SymmetricKey, VaultError> {
        let reason = lockedOut
            ? "Touch ID is locked. Enter your password to unlock your Orin Vault."
            : "Enter your password to unlock your Orin Vault."
        do {
            try await context.evaluatePolicy(.deviceOwnerAuthentication, localizedReason: reason)
            let key = try masterKey(context: context)
            return .success(key)
        } catch let laError as LAError {
            switch laError.code {
            case .userCancel, .appCancel, .systemCancel:
                return .failure(.userCancelled)
            default:
                return .failure(.authenticationFailed)
            }
        } catch let vaultError as VaultError {
            return .failure(vaultError)
        } catch {
            return .failure(.authenticationFailed)
        }
    }

    // MARK: - Keychain master key

    /// Reads or creates the 256-bit vault master key.
    ///
    /// The pre-evaluated `LAContext` is passed via `kSecUseAuthenticationContext`
    /// so the keychain never issues a second authentication prompt — even if the
    /// item carries a user-presence ACL.
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
            throw VaultError.keychainError(status)
        }

        return try createMasterKey(context: context)
    }

    /// Generates a new 256-bit master key and stores it with a user-presence
    /// access control so the raw bytes cannot be extracted from the keychain
    /// without authentication, even by direct database inspection.
    private func createMasterKey(context: LAContext) throws -> SymmetricKey {
        let key = SymmetricKey(size: .bits256)
        let keyData = key.withUnsafeBytes { Data($0) }

        guard let access = SecAccessControlCreateWithFlags(
            kCFAllocatorDefault,
            kSecAttrAccessibleWhenUnlockedThisDeviceOnly,
            .userPresence,
            nil
        ) else {
            throw VaultError.keychainError(errSecParam)
        }

        let addQuery: [String: Any] = [
            kSecClass as String:                    kSecClassGenericPassword,
            kSecAttrService as String:              keychainServiceKey,
            kSecValueData as String:                keyData,
            kSecAttrAccessControl as String:        access,
            kSecUseAuthenticationContext as String: context
        ]

        let addStatus = SecItemAdd(addQuery as CFDictionary, nil)
        guard addStatus == errSecSuccess else {
            throw VaultError.keychainError(addStatus)
        }
        return key
    }
}
