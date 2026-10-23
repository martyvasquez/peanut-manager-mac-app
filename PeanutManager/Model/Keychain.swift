import Foundation
import Security

/// Stores secrets (the ChatGPT sign-in, the Claude API key) in the keychain. They are never written anywhere else.
/// A synced item goes to iCloud Keychain so it's entered once on every device; that needs the app's iCloud
/// entitlement, and until then (or if iCloud Keychain is off) it stays in this Mac's login keychain.
enum Keychain {
    nonisolated private static let service = "com.martyvasquez.PeanutManager"

    nonisolated private static func query(_ account: String, synced: Bool) -> [String: Any] {
        var query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
        ]
        if synced {
            query[kSecUseDataProtectionKeychain as String] = true
            query[kSecAttrSynchronizable as String] = true
        }
        return query
    }

    nonisolated private static func copy(_ account: String, synced: Bool) -> Data? {
        var query = query(account, synced: synced)
        query[kSecReturnData as String] = true
        query[kSecMatchLimit as String] = kSecMatchLimitOne
        var item: CFTypeRef?
        guard SecItemCopyMatching(query as CFDictionary, &item) == errSecSuccess else { return nil }
        return item as? Data
    }

    /// Any keychain item by account name, synced copy first. Safe off the main actor.
    nonisolated static func data(_ account: String) -> Data? {
        copy(account, synced: true) ?? copy(account, synced: false)
    }

    /// Whether the item is already in iCloud Keychain.
    nonisolated static func isSynced(_ account: String) -> Bool {
        copy(account, synced: true) != nil
    }

    /// Moves an item saved on this Mac into iCloud Keychain, removing the local copy only once the move worked.
    nonisolated static func moveToICloud(_ account: String) {
        guard !isSynced(account), let data = copy(account, synced: false) else { return }
        var attributes = query(account, synced: true)
        attributes[kSecValueData as String] = data
        if SecItemAdd(attributes as CFDictionary, nil) == errSecSuccess {
            SecItemDelete(query(account, synced: false) as CFDictionary)
        }
    }

    /// Replaces the item, or deletes it (on every device, when synced) when `data` is nil.
    /// `synced` puts it in iCloud Keychain when the app can, and in this Mac's keychain otherwise.
    nonisolated static func set(_ data: Data?, for account: String, synced: Bool = false) {
        SecItemDelete(query(account, synced: true) as CFDictionary)
        SecItemDelete(query(account, synced: false) as CFDictionary)
        guard let data else { return }
        if synced {
            var attributes = query(account, synced: true)
            attributes[kSecValueData as String] = data
            if SecItemAdd(attributes as CFDictionary, nil) == errSecSuccess { return }
        }
        var attributes = query(account, synced: false)
        attributes[kSecValueData as String] = data
        SecItemAdd(attributes as CFDictionary, nil)
    }
}
