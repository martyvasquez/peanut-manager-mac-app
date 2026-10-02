import Foundation
import Security

/// Stores the OpenRouter API key in the login keychain. It is never written anywhere else.
enum Keychain {
    private static let service = "com.martyvasquez.PeanutManager"
    private static let account = "openrouter-api-key"

    static var apiKey: String {
        get {
            let query: [String: Any] = [
                kSecClass as String: kSecClassGenericPassword,
                kSecAttrService as String: service,
                kSecAttrAccount as String: account,
                kSecReturnData as String: true,
                kSecMatchLimit as String: kSecMatchLimitOne,
            ]
            var item: CFTypeRef?
            guard SecItemCopyMatching(query as CFDictionary, &item) == errSecSuccess,
                  let data = item as? Data else { return "" }
            return String(decoding: data, as: UTF8.self)
        }
        set {
            let query: [String: Any] = [
                kSecClass as String: kSecClassGenericPassword,
                kSecAttrService as String: service,
                kSecAttrAccount as String: account,
            ]
            SecItemDelete(query as CFDictionary)
            let trimmed = newValue.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !trimmed.isEmpty else { return }
            var attributes = query
            attributes[kSecValueData as String] = Data(trimmed.utf8)
            SecItemAdd(attributes as CFDictionary, nil)
        }
    }
}

enum AppSettings {
    static let lineupModelKey = "lineupModel"
}
