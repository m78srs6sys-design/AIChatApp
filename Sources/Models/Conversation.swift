import Foundation

/// 单个对话：拥有独立的消息上下文，并记住自己的模式（在线 / 离线）。
/// 在线与离线共享同一个对话列表与记录，每条对话互不影响。
struct Conversation: Identifiable, Codable {
    var id: UUID
    var title: String
    var mode: ChatMode
    var messages: [ChatMessage]
    var createdAt: Date
    var updatedAt: Date

    init(id: UUID = UUID(),
         title: String = "新对话",
         mode: ChatMode = .online,
         messages: [ChatMessage] = [],
         createdAt: Date = Date(),
         updatedAt: Date = Date()) {
        self.id = id
        self.title = title
        self.mode = mode
        self.messages = messages
        self.createdAt = createdAt
        self.updatedAt = updatedAt
    }

    /// 列表展示用的最后一条消息预览
    var preview: String {
        messages.last?.content.trimmingCharacters(in: .whitespacesAndNewlines) ?? "暂无消息"
    }
}

/// 对话仓库：管理多条对话的增删改查、当前选中与持久化。
/// 作为单例供 ChatViewModel 与各个视图共享。
@MainActor
final class ConversationStore: ObservableObject {
    static let shared = ConversationStore()

    @Published var conversations: [Conversation] = []
    @Published var currentId: UUID?

    private init() {
        load()
        if conversations.isEmpty {
            conversations.append(Conversation(mode: .online))
        }
        if currentId == nil || !conversations.contains(where: { $0.id == currentId }) {
            currentId = conversations.first?.id
        }
    }

    var current: Conversation? {
        conversations.first { $0.id == currentId }
    }

    var currentMode: ChatMode {
        current?.mode ?? .online
    }

    // MARK: - CRUD

    /// 新建对话并切换为当前，返回其 id
    @discardableResult
    func createConversation(mode: ChatMode, title: String? = nil) -> UUID {
        let conv = Conversation(title: title ?? "新对话", mode: mode)
        conversations.insert(conv, at: 0)
        currentId = conv.id
        persist()
        return conv.id
    }

    func select(_ id: UUID) {
        currentId = id
        persist()
    }

    func delete(_ id: UUID) {
        conversations.removeAll { $0.id == id }
        if conversations.isEmpty {
            conversations.append(Conversation(mode: .online))
        }
        if currentId == id {
            currentId = conversations.first?.id
        }
        persist()
    }

    func rename(_ id: UUID, _ title: String) {
        guard let idx = conversations.firstIndex(where: { $0.id == id }) else { return }
        conversations[idx].title = title
        persist()
    }

    /// 修改当前对话（追加消息、切换模式等），并刷新时间戳
    func mutateCurrent(_ mutate: (inout Conversation) -> Void) {
        guard let idx = conversations.firstIndex(where: { $0.id == currentId }) else { return }
        var c = conversations[idx]
        mutate(&c)
        c.updatedAt = Date()
        conversations[idx] = c
    }

    /// 首条用户消息作为对话标题（仅当还是默认标题时）
    func autoTitleIfNeeded() {
        guard let idx = conversations.firstIndex(where: { $0.id == currentId }) else { return }
        let c = conversations[idx]
        if c.title == "新对话" {
            if let firstUser = c.messages.first(where: { $0.role == .user }) {
                let t = firstUser.content.trimmingCharacters(in: .whitespacesAndNewlines)
                if !t.isEmpty {
                    conversations[idx].title = String(t.prefix(18))
                    persist()
                }
            }
        }
    }

    // MARK: - Persistence

    func persist() {
        PersistenceManager.shared.saveConversations(conversations)
        PersistenceManager.shared.saveCurrentId(currentId)
    }

    func load() {
        conversations = PersistenceManager.shared.loadConversations()
        currentId = PersistenceManager.shared.loadCurrentId()
        // 清理历史消息中残留的工具标签（如 <search>...</search>、<location/> 等）
        for i in conversations.indices {
            for j in conversations[i].messages.indices {
                conversations[i].messages[j].content = Self.stripAllTags(conversations[i].messages[j].content)
            }
        }
    }

    /// 移除所有工具标签（用于清理历史消息中的残留标签）
    static func stripAllTags(_ text: String) -> String {
        var result = text
        if let regex = try? NSRegularExpression(
            pattern: #"<(search|image|weather|web)>(.*?)</\1>"#,
            options: [.dotMatchesLineSeparators, .caseInsensitive]) {
            result = regex.stringByReplacingMatches(
                in: result, range: NSRange(result.startIndex..., in: result), withTemplate: "")
        }
        if let locRegex = try? NSRegularExpression(
            pattern: #"<location\s*/?>(\s*</location>)?"#,
            options: [.caseInsensitive]) {
            result = locRegex.stringByReplacingMatches(
                in: result, range: NSRange(result.startIndex..., in: result), withTemplate: "")
        }
        return result.trimmingCharacters(in: .whitespacesAndNewlines)
    }
}
