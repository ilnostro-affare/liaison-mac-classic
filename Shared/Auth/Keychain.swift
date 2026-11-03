import Foundation
import Security

/// Generic-password items for the Memberstack tokens.
/// The data-protection keychain needs a keychain-access-groups entitlement (and a provisioning profile);
/// the app has neither today, so Developer ID builds too get errSecMissingEntitlement and use the login
/// keychain. Login-keychain items belong to the signing identity, so the sign-in survives signed updates.
enum Keychain {
    private static let service = "com.liaisone.mac.auth"

    private static func base(_ account: String, modern: Bool) -> [String: Any] {
        var q: [String: Any] = [kSecClass as String: kSecClassGenericPassword,
                                kSecAttrService as String: service,
                                kSecAttrAccount as String: account]
        #if os(macOS)
        if modern { q[kSecUseDataProtectionKeychain as String] = true }
        #endif
        return q
    }

    /// Decided once per launch: does the data-protection keychain accept us?
    private static let modern: Bool = {
        #if os(macOS)
        var probe = base("_probe", modern: true)
        probe[kSecReturnData as String] = false
        let st = SecItemCopyMatching(probe as CFDictionary, nil)
        return st != errSecMissingEntitlement
        #else
        return true
        #endif
    }()

    /// Tries the data-protection keychain first; when it refuses the item (an ad-hoc or unsigned build has no
    /// application identifier, and the probe above cannot always tell), the login keychain takes it.
    @discardableResult
    static func set(_ value: String, for account: String) -> Bool {
        for m in modern ? [true, false] : [false] {
            SecItemDelete(base(account, modern: m) as CFDictionary)
            var add = base(account, modern: m)
            add[kSecValueData as String] = Data(value.utf8)
            // Not synced to iCloud, not moved to another device.
            add[kSecAttrAccessible as String] = kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly
            if SecItemAdd(add as CFDictionary, nil) == errSecSuccess { return true }
        }
        return false
    }

    static func get(_ account: String) -> String? {
        for m in modern ? [true, false] : [false] {
            var query = base(account, modern: m)
            query[kSecReturnData as String] = true
            query[kSecMatchLimit as String] = kSecMatchLimitOne
            var out: AnyObject?
            if SecItemCopyMatching(query as CFDictionary, &out) == errSecSuccess, let data = out as? Data {
                return String(data: data, encoding: .utf8)
            }
        }
        return nil
    }

    static func delete(_ account: String) {
        for m in modern ? [true, false] : [false] { SecItemDelete(base(account, modern: m) as CFDictionary) }
    }
}
