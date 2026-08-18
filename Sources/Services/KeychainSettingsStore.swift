import Foundation

/// 钥匙串存储：用于「卸载重装后自动恢复」设置。
///
/// 与 iCloud 不同，钥匙串项在 App 被删除后默认仍保留在设备钥匙串中，
/// 重新安装后可以被读取。因此它是「重装可恢复」最可靠的机制，
/// 不依赖任何签名能力（免费 Apple ID / 未签名 IPA 也能用）。
enum KeychainSettingsStore {
    static let service = "com.aichat.app.settings"

    static func save(_ settings: APISettings) {
        guard let data = try? JSONEncoder().encode(settings) else { return }
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service
        ]
        SecItemDelete(query as CFDictionary)
        let add: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecValueData as String: data,
            kSecAttrAccessible as String: kSecAttrAccessibleAfterFirstUnlock
        ]
        SecItemAdd(add as CFDictionary, nil)
    }

    static func load() -> APISettings? {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecReturnData as String: true,
            kSecMatchLimit as String: kSecMatchLimitOne
        ]
        var item: CFTypeRef?
        let status = SecItemCopyMatching(query as CFDictionary, &item)
        guard status == errSecSuccess,
              let data = item as? Data,
              let s = try? JSONDecoder().decode(APISettings.self, from: data) else {
            return nil
        }
        return s
    }
}
