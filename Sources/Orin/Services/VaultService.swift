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
        do {
            let success = try await context.evaluatePolicy(
                .deviceOwnerAuthentication,
                localizedReason: "Authenticate to unlock your secure vault."
            )
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
