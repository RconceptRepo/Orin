import Foundation
import Security

/// Thin Keychain wrapper for storing external AI provider API keys.
/// Keys are stored per-account under a shared service identifier so
/// they survive app restarts but stay device-local.
enum AIKeychainService {
    private static let keychainService = "com.orin.ai-provider-keys"

    @discardableResult
    static func save(_ key: String, account: String) -> Bool {
        guard !key.isEmpty, let data = key.data(using: .utf8) else { return false }
        // Delete any existing entry first to avoid errSecDuplicateItem.
        delete(account: account)
        let query: [String: Any] = [
            kSecClass as String:            kSecClassGenericPassword,
            kSecAttrService as String:      keychainService,
            kSecAttrAccount as String:      account,
            kSecValueData as String:        data,
            kSecAttrAccessible as String:   kSecAttrAccessibleWhenUnlockedThisDeviceOnly
        ]
        return SecItemAdd(query as CFDictionary, nil) == errSecSuccess
    }

    static func load(account: String) -> String? {
        let query: [String: Any] = [
            kSecClass as String:        kSecClassGenericPassword,
            kSecAttrService as String:  keychainService,
            kSecAttrAccount as String:  account,
            kSecReturnData as String:   true,
            kSecMatchLimit as String:   kSecMatchLimitOne
        ]
        var result: AnyObject?
        guard SecItemCopyMatching(query as CFDictionary, &result) == errSecSuccess,
              let data = result as? Data else { return nil }
        return String(data: data, encoding: .utf8)
    }

    static func delete(account: String) {
        let query: [String: Any] = [
            kSecClass as String:        kSecClassGenericPassword,
            kSecAttrService as String:  keychainService,
            kSecAttrAccount as String:  account
        ]
        SecItemDelete(query as CFDictionary)
    }

    static func hasKey(for account: String) -> Bool {
        load(account: account) != nil
    }
}
