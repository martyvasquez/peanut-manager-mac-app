import Foundation
import Security

/// Stores secrets (the ChatGPT sign-in, the Claude API key) in the keychain. They are never written anywhere else.
/// Items live in the data protection keychain, where access follows the app's entitlements instead of a password
/// prompt per item: a synced item in iCloud Keychain (entered once on every device), the rest on this device only.
/// Items saved by older builds sit in the login keychain until they move (`move`); if the data protection keychain
/// isn't available, new items fall back there too.
enum Keychain {
    nonisolated private static let service = "com.martyvasquez.PeanutManager"

    nonisolated private enum Place { case login, device, iCloud }

    nonisolated private static func query(_ account: String, _ place: Place) -> [String: Any] {
        var query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
        ]
        if place != .login {
            query[kSecUseDataProtectionKeychain as String] = true
            query[kSecAttrSynchronizable as String] = place == .iCloud
        }
        return query
    }

    nonisolated private static func copy(_ account: String, _ place: Place) -> Data? {
        var query = query(account, place)
        query[kSecReturnData as String] = true
        query[kSecMatchLimit as String] = kSecMatchLimitOne
        var item: CFTypeRef?
        guard SecItemCopyMatching(query as CFDictionary, &item) == errSecSuccess else { return nil }
        return item as? Data
    }

    nonisolated private static func add(_ data: Data, for account: String, _ place: Place) -> Bool {
        var attributes = query(account, place)
        attributes[kSecValueData as String] = data
        return SecItemAdd(attributes as CFDictionary, nil) == errSecSuccess
    }

    /// Any keychain item by account name, wherever it is. Safe off the main actor.
    nonisolated static func data(_ account: String) -> Data? {
        copy(account, .iCloud) ?? copy(account, .device) ?? copy(account, .login)
    }

    /// Whether the item is in iCloud Keychain.
    nonisolated static func isSynced(_ account: String) -> Bool {
        copy(account, .iCloud) != nil
    }

    /// Moves an item from the login keychain into the data protection keychain (iCloud Keychain when `synced`),
    /// removing the old copy only once the new one is saved.
    nonisolated static func move(_ account: String, synced: Bool) {
        let place: Place = synced ? .iCloud : .device
        guard copy(account, place) == nil, let data = copy(account, .login) else { return }
        if add(data, for: account, place) { SecItemDelete(query(account, .login) as CFDictionary) }
    }

    /// Replaces the item, or deletes it (on every device, when synced) when `data` is nil.
    /// `synced` puts it in iCloud Keychain; otherwise it stays on this device.
    nonisolated static func set(_ data: Data?, for account: String, synced: Bool = false) {
        for place in [Place.iCloud, .device, .login] { SecItemDelete(query(account, place) as CFDictionary) }
        guard let data else { return }
        // iCloud Keychain off: this device. No data protection keychain at all: the login keychain.
        for place in synced ? [Place.iCloud, .device, .login] : [.device, .login] where add(data, for: account, place) { return }
    }
}
