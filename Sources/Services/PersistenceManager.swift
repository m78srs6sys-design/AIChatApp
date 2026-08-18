import Foundation

/// 本地持久化：会话记录 + 设置，基于 UserDefaults（JSON 编码）
final class PersistenceManager {
    static let shared = PersistenceManager()
    private let defaults = UserDefaults.standard

    private enum Keys {
        static let messages = "aichat.messages"
        static let settings = "aichat.settings"
        static let mode = "aichat.mode"
        static let activeModelId = "aichat.activeModelId"
        static let conversations = "aichat.conversations"
        static let currentId = "aichat.currentId"
    }

    private init() {}

    // MARK: - Messages
    func loadMessages() -> [ChatMessage] {
        guard let data = defaults.data(forKey: Keys.messages),
              let messages = try? JSONDecoder().decode([ChatMessage].self, from: data) else {
            return []
        }
        return messages
    }

    func saveMessages(_ messages: [ChatMessage]) {
        if let data = try? JSONEncoder().encode(messages) {
            defaults.set(data, forKey: Keys.messages)
        }
    }

    func clearMessages() {
        defaults.removeObject(forKey: Keys.messages)
    }

    // MARK: - Settings
    func loadSettings() -> APISettings {
        guard let data = defaults.data(forKey: Keys.settings),
              let settings = try? JSONDecoder().decode(APISettings.self, from: data) else {
            return APISettings()
        }
        return settings
    }

    func saveSettings(_ settings: APISettings) {
        if let data = try? JSONEncoder().encode(settings) {
            defaults.set(data, forKey: Keys.settings)
        }
    }

    // MARK: - Mode & Active Model
    func loadMode() -> ChatMode {
        guard let raw = defaults.string(forKey: Keys.mode),
              let mode = ChatMode(rawValue: raw) else { return .online }
        return mode
    }

    func saveMode(_ mode: ChatMode) {
        defaults.set(mode.rawValue, forKey: Keys.mode)
    }

    func loadActiveModelId() -> String? {
        defaults.string(forKey: Keys.activeModelId)
    }

    func saveActiveModelId(_ id: String?) {
        if let id { defaults.set(id, forKey: Keys.activeModelId) }
        else { defaults.removeObject(forKey: Keys.activeModelId) }
    }

    // MARK: - Conversations（多对话独立上下文）
    func loadConversations() -> [Conversation] {
        guard let data = defaults.data(forKey: Keys.conversations),
              let arr = try? JSONDecoder().decode([Conversation].self, from: data) else {
            return []
        }
        return arr
    }

    func saveConversations(_ conversations: [Conversation]) {
        if let data = try? JSONEncoder().encode(conversations) {
            defaults.set(data, forKey: Keys.conversations)
        }
    }

    func loadCurrentId() -> UUID? {
        guard let s = defaults.string(forKey: Keys.currentId),
              let id = UUID(uuidString: s) else { return nil }
        return id
    }

    func saveCurrentId(_ id: UUID?) {
        if let id { defaults.set(id.uuidString, forKey: Keys.currentId) }
        else { defaults.removeObject(forKey: Keys.currentId) }
    }
}