import Foundation
import Security
import MeeABridgeCore

/// One app-process credential shared by foreground UI and AppIntent. Never synchronizes to iCloud.
enum Credentials {
    private static let service = "MeeABridge.connection"
    private static var query: [String: Any] {
        [kSecClass as String: kSecClassGenericPassword, kSecAttrService as String: service,
         kSecAttrAccount as String: "primary", kSecAttrSynchronizable as String: false]
    }
    private struct Stored: Codable { let url: String; let token: String }
    static func load() throws -> BackendConfiguration {
        var q = query; q[kSecReturnData as String] = true; q[kSecMatchLimit as String] = kSecMatchLimitOne
        var result: CFTypeRef?
        guard SecItemCopyMatching(q as CFDictionary, &result) == errSecSuccess,
              let data = result as? Data, let value = try? JSONDecoder().decode(Stored.self, from: data)
        else { throw BridgeError.credentials }
        return try BackendConfiguration(url: value.url, token: value.token)
    }
    static func save(url: String, token: String) throws {
        let config = try BackendConfiguration(url: url, token: token)
        let data = try JSONEncoder().encode(Stored(url: config.baseURL.absoluteString, token: token))
        let attrs: [String: Any] = [kSecValueData as String: data,
                                   kSecAttrAccessible as String: kSecAttrAccessibleWhenUnlockedThisDeviceOnly]
        let status = SecItemUpdate(query as CFDictionary, attrs as CFDictionary)
        if status == errSecItemNotFound {
            var q = query; attrs.forEach { q[$0.key] = $0.value }
            guard SecItemAdd(q as CFDictionary, nil) == errSecSuccess else { throw BridgeError.credentials }
        } else if status != errSecSuccess { throw BridgeError.credentials }
    }
    static func clear() throws {
        let status = SecItemDelete(query as CFDictionary)
        guard status == errSecSuccess || status == errSecItemNotFound else { throw BridgeError.credentials }
    }
}
