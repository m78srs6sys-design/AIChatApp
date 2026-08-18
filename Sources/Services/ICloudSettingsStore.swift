import Foundation

/// 设置持久化：优先写入 iCloud Drive 文件夹（卸载重装后依然可读），
/// iCloud 不可用时回退到本机沙盒，保证 App 始终可用。
///
/// 说明：iCloud 是否真正生效取决于你侧载时使用的签名描述文件是否已开启 iCloud 能力
/// （开发者账号在 App ID 中启用 iCloud 并下载包含该能力的描述文件）。
/// 若未开启（例如免费 Apple ID 未包含 iCloud），会自动回退到本机存储。
enum ICloudSettingsStore {
    static let fileName = "aichat_settings.json"

    /// iCloud Drive 中的 Documents 目录（ubiquity container），缓存以避免重复阻塞调用
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

    /// 保存：同时写入 iCloud（若可用）与本机兜底
    static func save(_ settings: APISettings) {
        guard let data = try? JSONEncoder().encode(settings) else { return }
        if let url = iCloudBaseURL() {
            try? data.write(to: url, options: .atomic)
        }
        try? data.write(to: localURL(), options: .atomic)
    }

    /// 加载：优先 iCloud，回退本机
    static func load() -> APISettings? {
        if let url = iCloudBaseURL(),
           let data = try? Data(contentsOf: url),
           let s = try? JSONDecoder().decode(APISettings.self, from: data) {
            return s
        }
        if let data = try? Data(contentsOf: localURL()),
           let s = try? JSONDecoder().decode(APISettings.self, from: data) {
            return s
        }
        return nil
    }

    /// 当前是否正使用 iCloud 同步
    static var isUsingiCloud: Bool {
        iCloudBaseURL() != nil
    }
}
