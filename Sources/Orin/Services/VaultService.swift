import CryptoKit
import Foundation
import LocalAuthentication
import Security

enum VaultError: Error {
    case authenticationFailed
    case keychainError
}

final class VaultService: Service {
    private let keychainServiceKey = "com.orin.vault.masterkey"

    var canUseBiometrics: Bool {
        let context = LAContext()
        var error: NSError?
        return context.canEvaluatePolicy(.deviceOwnerAuthenticationWithBiometrics, error: &error) && error == nil
    }

    func unlockVault() async -> Result<SymmetricKey, VaultError> {
        let context = LAContext()
        var biometricError: NSError?
        // Prefer biometrics-only to avoid the double-prompt from deviceOwnerAuthentication.
        // Fall back to password-only if biometrics are unavailable.
        let policy: LAPolicy = context.canEvaluatePolicy(
            .deviceOwnerAuthenticationWithBiometrics, error: &biometricError
        ) ? .deviceOwnerAuthenticationWithBiometrics : .deviceOwnerAuthentication

        let reason = policy == .deviceOwnerAuthenticationWithBiometrics
            ? "Use Touch ID to unlock your Orin Vault."
            : "Enter your password to unlock your Orin Vault."

        do {
            let success = try await context.evaluatePolicy(policy, localizedReason: reason)
            guard success else { return .failure(.authenticationFailed) }
            return .success(try retrieveOrCreateMasterKey())
        } catch {
            return .failure(.authenticationFailed)
        }
    }

    func encrypt(_ data: Data, using key: SymmetricKey) throws -> Data {
        try AES.GCM.seal(data, using: key).combined ?? Data()
    }

    func decrypt(_ cipherText: Data, using key: SymmetricKey) throws -> Data {
        let sealedBox = try AES.GCM.SealedBox(combined: cipherText)
        return try AES.GCM.open(sealedBox, using: key)
    }

    /// Returns a human-readable recovery key (hex groups) derived from the vault master key.
    /// Show this to the user once on first setup so they can recover data if biometrics change.
    func recoveryKeyString(from key: SymmetricKey) -> String {
        let hex = key.withUnsafeBytes { Data($0) }
            .map { String(format: "%02X", $0) }
            .joined()
        // Format as 8-character groups separated by dashes
        var result = ""
        for (i, char) in hex.enumerated() {
            if i > 0 && i % 8 == 0 { result += "-" }
            result.append(char)
        }
        return result
    }

    private func retrieveOrCreateMasterKey() throws -> SymmetricKey {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: keychainServiceKey,
            kSecReturnData as String: true
        ]

        var result: AnyObject?
        let status = SecItemCopyMatching(query as CFDictionary, &result)
        if status == errSecSuccess, let keyData = result as? Data {
            return SymmetricKey(data: keyData)
        }

        let newKey = SymmetricKey(size: .bits256)
        let keyData = newKey.withUnsafeBytes { Data($0) }
        let addQuery: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: keychainServiceKey,
            kSecValueData as String: keyData,
            kSecAttrAccessible as String: kSecAttrAccessibleWhenUnlockedThisDeviceOnly
        ]

        guard SecItemAdd(addQuery as CFDictionary, nil) == errSecSuccess else {
            throw VaultError.keychainError
        }
        return newKey
    }
}
