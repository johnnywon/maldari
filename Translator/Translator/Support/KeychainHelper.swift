import Foundation
import Security

/// Minimal Keychain wrapper for storing API credentials as generic passwords.
enum KeychainHelper {
    @discardableResult
    static func save(_ value: String, service: String, account: String) -> Bool {
        guard let data = value.data(using: .utf8) else { return false }
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
        ]
        SecItemDelete(query as CFDictionary)
        var add = query
        add[kSecValueData as String] = data
        return SecItemAdd(add as CFDictionary, nil) == errSecSuccess
    }

    static func load(service: String, account: String) -> String? {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
            kSecReturnData as String: true,
            kSecMatchLimit as String: kSecMatchLimitOne,
        ]
        var result: AnyObject?
        guard SecItemCopyMatching(query as CFDictionary, &result) == errSecSuccess,
              let data = result as? Data else { return nil }
        return String(data: data, encoding: .utf8)
    }

    /// Whether an item exists, WITHOUT decrypting it.
    ///
    /// Load-bearing, and the fix for an app that could not launch. The keychain's
    /// access-control gate is on returning the item's *data*: an attribute-only
    /// query answers immediately, while `kSecReturnData: true` from a binary the
    /// item's ACL does not trust makes macOS put up a modal
    /// "Maldari wants to access key … enter the login keychain password" dialog and
    /// BLOCK the calling thread until it is answered.
    ///
    /// `Credentials.has*` is read from SwiftUI view bodies, which are evaluated on
    /// the main thread — including while `applySettings()` is constructing the
    /// windows at launch. So one untrusted-ACL read there blocked the main thread
    /// inside window creation and the app started with no windows at all, looking
    /// like a hang. The ACL stops trusting the binary on every `make-app.sh`
    /// re-sign, because ad-hoc signing gives each build a different code identity,
    /// so this was reachable on any rebuild.
    ///
    /// Presence is all `has*` ever needed. The secret itself is only fetched when a
    /// request is actually being made, off the launch path.
    static func exists(service: String, account: String) -> Bool {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
            // NOT kSecReturnData — see above. Attributes only.
            kSecReturnAttributes as String: true,
            kSecMatchLimit as String: kSecMatchLimitOne,
        ]
        var result: AnyObject?
        return SecItemCopyMatching(query as CFDictionary, &result) == errSecSuccess
    }

    static func delete(service: String, account: String) {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
        ]
        SecItemDelete(query as CFDictionary)
    }
}
