import Foundation

/// 设置持久化（复合策略）：
/// 1. iCloud Drive 文件夹 —— 跨设备同步（取决于侧载签名是否含 iCloud 能力）。
/// 2. 钥匙串 —— 重装后可恢复，不依赖任何签名能力（最可靠，默认一定可用）。
/// 3. 本机沙盒文件 —— 兜底。
///
/// 说明：未签名的 IPA（CODE_SIGNING_ALLOWED=NO）不会嵌入 iCloud 授权，
/// 此时 url(forUbiquityContainerIdentifier:) 恒为 nil，iCloud 不可用。
/// 因此「重装后自动恢复」改用钥匙串实现，iCloud 仅作为额外跨设备同步。
enum ICloudSettingsStore {
    static let fileName = "aichat_settings.json"

    /// iCloud Drive 中的 Documents 目录（ubiquity container）
    private static var _iCloudBase: URL?

    static func iCloudBaseURL() -> URL? {
        if let cached = _iCloudBase {
            return cached.appendingPathComponent(fileName)
        }
        let base = FileManager.default
            .url(forUbiquityContainerIdentifier: nil)?
            .appendingPathComponent("Documents", isDirectory: true)
        _iCloudBase = base
        if let b = base {
            try? FileManager.default.createDirectory(at: b, withIntermediateDirectories: true)
        }
        return base?.appendingPathComponent(fileName)
    }

    static func localURL() -> URL {
        FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
            .appendingPathComponent(fileName)
    }

    /// 保存：iCloud（若可用）+ 钥匙串（一定可用）+ 本机兜底
    static func save(_ settings: APISettings) {
        if let url = iCloudBaseURL(),
           let data = try? JSONEncoder().encode(settings) {
            try? data.write(to: url, options: .atomic)
        }
        KeychainSettingsStore.save(settings)
        if let data = try? JSONEncoder().encode(settings) {
            try? data.write(to: localURL(), options: .atomic)
        }
    }

    /// 加载优先级：iCloud → 钥匙串 → 本机
    static func load() -> APISettings? {
        if let s = loadFromiCloud() { return s }
        if let s = KeychainSettingsStore.load() { return s }
        if let data = try? Data(contentsOf: localURL()),
           let s = try? JSONDecoder().decode(APISettings.self, from: data) {
            return s
        }
        return nil
    }

    private static func loadFromiCloud() -> APISettings? {
        guard let url = iCloudBaseURL(),
              let data = try? Data(contentsOf: url),
              let s = try? JSONDecoder().decode(APISettings.self, from: data) else {
            return nil
        }
        return s
    }

    /// iCloud Drive 容器是否可用（取决于签名描述文件是否含 iCloud 能力）
    static var iCloudAvailable: Bool {
        iCloudBaseURL() != nil
    }

    /// 钥匙串始终可用（重装可恢复）
    static var keychainAvailable: Bool { true }
}
