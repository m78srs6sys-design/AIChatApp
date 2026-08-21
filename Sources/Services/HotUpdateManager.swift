import Foundation
import Combine
import SwiftUI
import os

// MARK: - 热更新管理器
/// 从 GitHub 仓库（raw 地址）拉取 aichat-update/latest.json，按灰度比例决定是否启用，
/// 成功后持久化到本机；失败/离线时回退到「上次已生效配置」，再没有则用出厂默认。
/// 所有被热更新的 UI/功能/权限/提示词只读本类暴露的 AppConfig，因此更新即时生效。
final class HotUpdateManager: ObservableObject {

    static let shared = HotUpdateManager()

    /// 出厂时内置的配置版本（随 App 构建）
    let builtinVersion: Int = 1

    /// 官方默认更新源（GitHub 公开仓库 raw 地址，无需鉴权）
    static let defaultSourceURL = "https://raw.githubusercontent.com/m78srs6sys-design/AIChatApp/main/aichat-update/latest.json"

    /// 用户自定义更新源（UserDefaults，默认空 = 使用官方源）
    @Published var customSourceURL: String {
        didSet { UserDefaults.standard.set(customSourceURL, forKey: Keys.customSource) }
    }

    // 状态（设置页展示）
    @Published private(set) var lastCheckResult: String = "尚未检查"
    @Published private(set) var isChecking = false
    @Published private(set) var appliedRemoteVersion: Int = 1
    @Published private(set) var remoteVersion: Int = 0
    @Published private(set) var remoteRollout: Int = 100
    @Published private(set) var remoteNotes: String = ""

    /// 当前生效的远程配置（从未成功拉取过则为 nil，此时 AppConfig 走出厂默认）
    @Published private(set) var activeRemote: RemoteConfig?

    /// 设备稳定标识（灰度分桶用；独立于 iCloud/卸载保留）
    private let deviceID: String

    private enum Keys {
        static let customSource = "hot_update_custom_source_url"
        static let cachedJSON = "hot_update_cached_config_json"
        static let deviceID = "hot_update_device_id"
        static let lastCheckTime = "hot_update_last_check_time"
    }

    private init() {
        let d = UserDefaults.standard
        customSourceURL = d.string(forKey: Keys.customSource) ?? ""
        if let savedID = d.string(forKey: Keys.deviceID), !savedID.isEmpty {
            deviceID = savedID
        } else {
            let newID = UUID().uuidString
            d.set(newID, forKey: Keys.deviceID)
            deviceID = newID
        }
        // 启动时读上次已生效缓存（无网也能用上次的配置）
        if let json = d.string(forKey: Keys.cachedJSON),
           let cfg = Self.decode(json) {
            activeRemote = cfg
            if let v = cfg.version { appliedRemoteVersion = v; remoteVersion = v }
            remoteRollout = cfg.rollout ?? 100
            remoteNotes = cfg.notes ?? ""
        }
    }

    // MARK: - 有效更新源

    var effectiveSourceURL: String {
        let u = customSourceURL.trimmingCharacters(in: .whitespacesAndNewlines)
        return u.isEmpty ? Self.defaultSourceURL : u
    }

    // MARK: - 检查并应用更新

    /// 检查更新（长期运行环境调用；force=true 为设置页手动检查，忽略缓存时间窗口）
    func checkForUpdate(force: Bool = false) async {
        guard !isChecking else { return }
        // 非强制时限制频率：距上次成功检查 < 10 分钟直接跳过（启动时快速返回）
        if !force {
            let last = UserDefaults.standard.double(forKey: Keys.lastCheckTime)
            if last > 0, Date().timeIntervalSince1970 - last < 600 { return }
        }
        isChecking = true
        defer { isChecking = false }

        guard let url = URL(string: effectiveSourceURL) else {
            lastCheckResult = "更新源地址无效"
            return
        }

        do {
            var req = URLRequest(url: url)
            req.timeoutInterval = 20
            req.cachePolicy = .reloadIgnoringLocalCacheData
            let (data, resp) = try await URLSession.shared.data(for: req)
            guard let http = resp as? HTTPURLResponse, http.statusCode == 200 else {
                lastCheckResult = "更新源不可达（可能当前离线，沿用上次配置）"
                return
            }
            guard let cfg = Self.decode(String(data: data, encoding: .utf8) ?? "") else {
                lastCheckResult = "更新文件解析失败（格式不兼容，沿用上次配置）"
                return
            }
            let version = cfg.version ?? builtinVersion

            // 1) 版本未更新：无动作
            if version <= appliedRemoteVersion {
                lastCheckResult = "已是最新配置（v\(appliedRemoteVersion)）"
                UserDefaults.standard.set(Date().timeIntervalSince1970, forKey: Keys.lastCheckTime)
                return
            }

            // 2) App 最低版本门槛：低于则忽略并提示
            if cfg.minAppVersion != nil, cfg.minAppVersion! > builtinVersion {
                lastCheckResult = "此配置需要更新版 App（请等待新版本安装）"
                return
            }

            // 3) 灰度：设备稳定分桶，未命中灰度 → 保持旧配置（并记住这次检查）
            remoteVersion = version
            remoteRollout = cfg.rollout ?? 100
            remoteNotes = cfg.notes ?? ""
            let bucket = Self.rolloutBucket(deviceID)
            if bucket >= remoteRollout {
                lastCheckResult = "新配置 v\(version) 正在灰度中（\(remoteRollout)%），本设备暂未命中，稍后再试"
                UserDefaults.standard.set(Date().timeIntervalSince1970, forKey: Keys.lastCheckTime)
                return
            }

            // 4) 命中灰度或全员：持久化 + 生效
            let encoder = JSONEncoder()
            encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
            if let json = String(data: try encoder.encode(cfg), encoding: .utf8) {
                UserDefaults.standard.set(json, forKey: Keys.cachedJSON)
            }
            activeRemote = cfg
            appliedRemoteVersion = version
            remoteRollout = cfg.rollout ?? 100
            remoteNotes = cfg.notes ?? ""
            UserDefaults.standard.set(Date().timeIntervalSince1970, forKey: Keys.lastCheckTime)
            lastCheckResult = "已更新到配置 v\(version)（\(remoteRollout)% 灰度）"
            AppConfig.shared.reload()
            NotificationCenter.default.post(name: .hotConfigApplied, object: nil)
        } catch {
            lastCheckResult = "检查失败（\(Self.shortError(error))），沿用上次配置"
        }
    }

    /// 回滚到出厂默认（清掉远程配置缓存）
    func resetToFactory() {
        UserDefaults.standard.removeObject(forKey: Keys.cachedJSON)
        activeRemote = nil
        appliedRemoteVersion = builtinVersion
        remoteVersion = 0
        remoteRollout = 100
        remoteNotes = ""
        lastCheckResult = "已恢复出厂默认配置"
        AppConfig.shared.reload()
        NotificationCenter.default.post(name: .hotConfigApplied, object: nil)
    }

    // MARK: - 工具

    /// 设备稳定分桶：0-99，同一设备每次结果一致（用于灰度稳定分配）
    static func rolloutBucket(_ id: String) -> Int {
        var h = 0
        for b in id.utf8 {
            h = (h &* 31 &+ Int(b)) & 0x7fffffff
        }
        return h % 100
    }

    static func decode(_ json: String) -> RemoteConfig? {
        guard let data = json.data(using: .utf8) else { return nil }
        return try? JSONDecoder().decode(RemoteConfig.self, from: data)
    }

    /// 抹掉更新源里的隐私串（API key 等），只记录 host，避免日志泄露
    private static func shortError(_ e: Error) -> String {
        let s = e.localizedDescription
        return s.count > 60 ? String(s.prefix(60)) + "…" : s
    }
}

extension Notification.Name {
    static let hotConfigApplied = Notification.Name("hotConfigApplied")
}

/// AppConfig：运行时门面。所有 UI / 功能 / 权限读取都走这里，
/// 优先读远程配置（HotUpdateManager.activeRemote），缺字段回退出厂默认。
final class AppConfig: ObservableObject {
    static let shared = AppConfig()

    /// 当前配置是否来自远程（用于设置页展示来源）
    @Published var isRemote = false

    private let logger = Logger(subsystem: "com.aidiary.AIDiary", category: "AppConfig")

    private init() {
        // 订阅热更新生效事件，刷新 UI
        NotificationCenter.default.addObserver(forName: .hotConfigApplied, object: nil, queue: .main) { [weak self] _ in
            self?.objectWillChange.send()
        }
        reload()
    }

    func reload() {
        isRemote = HotUpdateManager.shared.activeRemote != nil
        objectWillChange.send()
        logger.info("AppConfig reloaded, isRemote=\(self.isRemote)")
    }

    // MARK: - 底层取当前配置

    private var remote: RemoteConfig? { HotUpdateManager.shared.activeRemote }

    // MARK: - 功能开关

    /// 某功能是否可用（缺省 true，远程显式 false 才关闭）
    func feature(_ key: String) -> Bool {
        remote?.features?[key] ?? true
    }

    /// 当前可用的工具标签白名单（用于 system prompt 与执行过滤）
    func toolWhitelist() -> [String]? {
        guard let tools = remote?.tools, !tools.isEmpty else { return nil }
        return tools
    }

    func toolEnabled(_ kind: String) -> Bool {
        if let tools = remote?.tools, !tools.isEmpty {
            return tools.contains(kind)
        }
        // 无白名单时按 features 判断
        switch kind {
        case "search": return feature(FeatureKey.search)
        case "weather": return feature(FeatureKey.weather)
        case "web": return feature(FeatureKey.web)
        case "image": return feature(FeatureKey.imageGen)
        case "imagesearch": return feature(FeatureKey.imageSearch)
        case "location": return feature(FeatureKey.location)
        case "system": return feature(FeatureKey.systemOps)
        default: return true
        }
    }

    /// systemPrompt：远程有非空值则覆盖内置；否则返回内置
    func systemPrompt(remoteOverride: String?) -> String? {
        if let p = remote?.systemPrompt, !p.isEmpty { return p }
        return remoteOverride
    }

    /// 追加在 system prompt 尾部的远程说明（如「打开 App 必须写全名」等约束）
    func systemPromptSuffix() -> String? {
        guard let s = remote?.systemPromptSuffix, !s.isEmpty else { return nil }
        return s
    }

    /// 远程「打开 App」别名表（优先于内置表匹配；nil = 使用内置表）
    func appSchemes() -> [AppSchemeConfig]? {
        guard let list = remote?.appSchemes, !list.isEmpty else { return nil }
        return list
    }

    // MARK: - 主题（AppTheme 读取）

    func themeColor(_ key: String) -> Color? {
        guard let hex = remote?.theme?.valueForKey(key), !hex.isEmpty else { return nil }
        return Color(hex: hex)
    }

    func cornerRadius(_ key: String, fallback: CGFloat) -> CGFloat {
        switch key {
        case "cornerRadius":
            return CGFloat(remote?.theme?.cornerRadius ?? Double(fallback))
        case "bubbleRadius":
            return CGFloat(remote?.theme?.bubbleRadius ?? Double(fallback))
        default:
            return fallback
        }
    }

    // MARK: - UI 文案 / 显隐

    func uiString(_ key: String) -> String? {
        guard let ui = remote?.ui else { return nil }
        switch key {
        case "appDisplayName": return ui.appDisplayName
        case "emptyTitle": return ui.emptyTitle
        case "emptySubtitle": return ui.emptySubtitle
        default: return nil
        }
    }

    func uiFlag(_ key: String, fallback: Bool) -> Bool {
        guard let ui = remote?.ui else { return fallback }
        switch key {
        case "showPDFExport": return ui.showPDFExport ?? fallback
        case "showClearButton": return ui.showClearButton ?? fallback
        case "showWorkflows": return ui.showWorkflows ?? fallback
        case "showCrashLogs": return ui.showCrashLogs ?? fallback
        case "showHapticToggle": return ui.showHapticToggle ?? fallback
        case "showTTS": return ui.showTTS ?? fallback
        default: return fallback
        }
    }

    // MARK: - 系统权限行

    func permissionRows() -> [PermissionRowConfig] {
        guard let rows = remote?.permissions?.rows, !rows.isEmpty else {
            return RemoteConfig.factoryPermissionRows
        }
        return rows
    }
}

// MARK: - 十六进制颜色助手
extension Color {
    /// 从 "#RRGGBB" 或 "RRGGBB" 创建颜色；非法时返回 nil
    init?(hex: String) {
        var s = hex.trimmingCharacters(in: .whitespacesAndNewlines)
        if s.hasPrefix("#") { s.removeFirst() }
        guard s.count == 6, let v = UInt64(s, radix: 16) else { return nil }
        self.init(
            red: Double((v >> 16) & 0xFF) / 255.0,
            green: Double((v >> 8) & 0xFF) / 255.0,
            blue: Double(v & 0xFF) / 255.0
        )
    }
}

// MARK: - ThemeConfig 助手（按 key 取 hex）
extension ThemeConfig {
    func valueForKey(_ key: String) -> String? {
        switch key {
        case "background": return background
        case "surface": return surface
        case "surfaceElevated": return surfaceElevated
        case "userBubble": return userBubble
        case "userBubbleText": return userBubbleText
        case "aiBubble": return aiBubble
        case "aiBubbleText": return aiBubbleText
        case "accent": return accent
        case "accentSoft": return accentSoft
        case "primaryText": return primaryText
        case "secondaryText": return secondaryText
        case "tertiaryText": return tertiaryText
        case "border": return border
        case "divider": return divider
        case "success": return success
        case "warning": return warning
        case "error": return error
        default: return nil
        }
    }
}