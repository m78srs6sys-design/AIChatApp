import Foundation
import SwiftUI

// MARK: - 远程热更新配置模型（来自 GitHub 仓库 aichat-update/latest.json）

/// 主题色配置（十六进制字符串，如 "#FFA06B"）
struct ThemeConfig: Codable {
    var background: String?
    var surface: String?
    var surfaceElevated: String?
    var userBubble: String?
    var userBubbleText: String?
    var aiBubble: String?
    var aiBubbleText: String?
    var accent: String?
    var accentSoft: String?
    var primaryText: String?
    var secondaryText: String?
    var tertiaryText: String?
    var border: String?
    var divider: String?
    var success: String?
    var warning: String?
    var error: String?
    var cornerRadius: Double?
    var bubbleRadius: Double?
}

/// UI 文案与元素显隐配置
struct UIConfig: Codable {
    var appDisplayName: String?
    var emptyTitle: String?
    var emptySubtitle: String?
    var showPDFExport: Bool?
    var showClearButton: Bool?
    var showWorkflows: Bool?
    var showCrashLogs: Bool?
    var showHapticToggle: Bool?
    var showTTS: Bool?
}

/// 设置页「系统权限」展示行（可远程增删改文案与图标）
struct PermissionRowConfig: Codable {
    var key: String        // location / motion / mic / notification / photos / contacts ...
    var icon: String       // SF Symbol
    var title: String
    var subtitle: String?
}

/// 权限区配置
struct PermissionConfig: Codable {
    var rows: [PermissionRowConfig]?
}

/// 远程本地模型目录条目（可选，用于热更新模型列表）
struct RemoteModelEntry: Codable {
    var id: String
    var name: String
    var detail: String
    var sizeText: String
    var downloadURL: String
    var filename: String
    var contextLength: Int
    var parts: [RemoteModelPart]
}

struct RemoteModelPart: Codable {
    var filename: String
    var downloadURL: String
    var size: Int
}

/// latest.json 完整结构。所有字段可选：缺失的字段沿用内置出厂默认值，
/// 保证「旧配置新 App / 新配置旧 App」都能平滑解析，不会整体失败。
struct RemoteConfig: Codable {
    var version: Int?               // 热更新配置版本号（整数递增）
    var minAppVersion: Int?         // 需要的最低 App 构建版本；低于它忽略本次更新（提示升级 App）
    var rollout: Int?               // 灰度比例 0-100（缺省 100 = 全员）
    var channel: String?            // 渠道：stable / beta（缺省 stable）
    var notes: String?              // 更新说明（设置页展示）
    var ui: UIConfig?
    var theme: ThemeConfig?
    var features: [String: Bool]?   // 功能开关：key 见 FeatureKey
    var permissions: PermissionConfig?
    var systemPrompt: String?       // 覆盖内置 system prompt（nil 或空串 = 用内置）
    var tools: [String]?            // 可用工具白名单（缺省 = 全部内置工具）
    var models: [RemoteModelEntry]? // 远程模型目录（可选）
}

/// 远程配置功能开关的键（与 latest.json features 对应）
enum FeatureKey {
    static let htmlCard = "htmlCard"          // <card> 可视化卡片
    static let imageGen = "imageGen"          // <image> 图片生成
    static let imageSearch = "imageSearch"    // <imageSearch> 图片搜索
    static let search = "search"              // <search> 联网搜索
    static let weather = "weather"            // <weather> 天气
    static let web = "web"                    // <web> 网页摘要
    static let location = "location"          // <location> 定位
    static let systemOps = "systemOps"        // <system> 系统操作 / 传感器
    static let sensorAll = "sensorAll"        // 「所有传感器」总览
    static let cardOnAll = "cardOnAll"        // search/weather 等结果自动生成 HTML 卡
}

/// 系统权限行 key（与 PermissionRowConfig.key 对应）
enum PermissionKey {
    static let location = "location"
    static let motion = "motion"
    static let mic = "mic"
    static let notification = "notification"
}

// MARK: - 出厂默认值（内置兜底）

extension RemoteConfig {
    /// 出厂内置默认配置：与 App 内置行为完全一致，仅在远程配置缺失字段时使用。
    static var factory: RemoteConfig {
        RemoteConfig(
            version: 1,
            minAppVersion: 26,
            rollout: 100,
            channel: "stable",
            notes: "出厂默认配置",
            ui: nil,
            theme: nil,
            features: nil,
            permissions: nil,
            systemPrompt: nil,
            tools: nil,
            models: nil
        )
    }

    /// 内置「系统权限」展示行默认值
    static var factoryPermissionRows: [PermissionRowConfig] {
        [
            PermissionRowConfig(key: PermissionKey.location, icon: "location.fill",
                                title: "位置（海拔 / 指南针）", subtitle: nil),
            PermissionRowConfig(key: PermissionKey.motion, icon: "figure.walk",
                                title: "运动与健身（步数 / 气压）", subtitle: nil),
            PermissionRowConfig(key: PermissionKey.mic, icon: "mic.fill",
                                title: "麦克风（语音输入）", subtitle: nil),
            PermissionRowConfig(key: PermissionKey.notification, icon: "bell.badge.fill",
                                title: "通知（下载完成提醒）", subtitle: nil)
        ]
    }

    /// 内置功能开关默认值（全部可用）
    static var factoryFeatures: [String: Bool] {
        [
            FeatureKey.htmlCard: true,
            FeatureKey.imageGen: true,
            FeatureKey.imageSearch: true,
            FeatureKey.search: true,
            FeatureKey.weather: true,
            FeatureKey.web: true,
            FeatureKey.location: true,
            FeatureKey.systemOps: true,
            FeatureKey.sensorAll: true,
            FeatureKey.cardOnAll: true
        ]
    }
}