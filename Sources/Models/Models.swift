import Foundation

/// 对话模式
enum ChatMode: String, Codable, CaseIterable {
    case online   // 联网 API 模式
    case offline  // 本地离线模式

    var title: String {
        switch self {
        case .online: return "联网模式"
        case .offline: return "离线模式"
        }
    }

    var subtitle: String {
        switch self {
        case .online: return "OpenAI 兼容 · 云端推理"
        case .offline: return "本地端侧 · 隐私优先"
        }
    }
}

/// 消息角色
enum MessageRole: String, Codable {
    case user
    case assistant
    case system
}

/// 消息附件类型（联网技能产物）
enum MessageAttachment: Codable, Hashable {
    case image(url: String)
    case location(latitude: Double, longitude: Double, name: String)
    case searchResults([SearchResultItem])
    case weather(WeatherInfo)
    case webpage(WebpageSummary)
    /// HTML 可视化卡片（圆角，WebView 渲染）
    case htmlCard(html: String)
    /// 系统操作结果
    case systemAction(action: String, description: String)
}

struct SearchResultItem: Codable, Hashable {
    let title: String
    let url: String
    let snippet: String?
}

/// 天气信息（open-meteo 免密钥接口）
struct WeatherInfo: Codable, Hashable {
    let city: String
    let temperature: Double
    let condition: String
    let humidity: Int?
    let windSpeed: Double?
    let units: String
}

/// 网页摘要（直连抓取后裁剪的正文）
struct WebpageSummary: Codable, Hashable {
    let url: String
    let title: String
    let summary: String
}

/// 单条对话消息
struct ChatMessage: Identifiable, Codable, Hashable {
    let id: UUID
    let role: MessageRole
    var content: String
    var isStreaming: Bool
    var attachments: [MessageAttachment]
    /// 深度思考过程（reasoning_content），可展开/收起的小字
    var reasoning: String
    let timestamp: Date

    init(id: UUID = UUID(), role: MessageRole, content: String,
         isStreaming: Bool = false, attachments: [MessageAttachment] = [],
         reasoning: String = "", timestamp: Date = Date()) {
        self.id = id
        self.role = role
        self.content = content
        self.isStreaming = isStreaming
        self.attachments = attachments
        self.reasoning = reasoning
        self.timestamp = timestamp
    }
}

/// 本地模型定义
struct LocalModel: Identifiable, Codable, Hashable {
    let id: String
    let name: String
    let detail: String
    let sizeText: String
    let downloadURL: String
    let filename: String
    let contextLength: Int
}