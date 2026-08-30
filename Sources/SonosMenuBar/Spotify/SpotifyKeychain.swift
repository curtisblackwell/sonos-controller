import Foundation
import Security

/// Stores Spotify's access and refresh tokens. Not `UserDefaults`/`PreferencesStore` like the
/// Sonos group selection - these are credentials, not preferences.
enum SpotifyKeychain {
    private static let service = "com.curtisblackwell.sonos-controller.spotify"

    static func set(_ value: String, forKey key: String) {
        let data = Data(value.utf8)
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: key,
        ]
        // Update in place when the item already exists so its ACL (and any
        // "Always Allow" grant) survives - deleting and re-adding wipes the ACL,
        // which was forcing a fresh keychain prompt on every token refresh.
        let updateStatus = SecItemUpdate(query as CFDictionary, [kSecValueData as String: data] as CFDictionary)
        if updateStatus == errSecItemNotFound {
            var attributes = query
            attributes[kSecValueData as String] = data
            SecItemAdd(attributes as CFDictionary, nil)
        }
    }

    static func get(_ key: String) -> String? {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: key,
            kSecReturnData as String: true,
            kSecMatchLimit as String: kSecMatchLimitOne,
        ]
        var result: AnyObject?
        guard SecItemCopyMatching(query as CFDictionary, &result) == errSecSuccess,
              let data = result as? Data
        else { return nil }
        return String(data: data, encoding: .utf8)
    }

    static func remove(_ key: String) {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: key,
        ]
        SecItemDelete(query as CFDictionary)
    }
}
