import Foundation
import Combine
import SwiftUI

@MainActor
final class ChatViewModel: ObservableObject {
    @Published var inputText: String = ""
    @Published var isGenerating: Bool = false
    @Published var errorMessage: String?
    @Published var statusMessage: String?
    @Published var currentAudioURL: String?
    @Published var isPlayingAudio: Bool = false
    /// 逐字震动开关（来自设置）
    var enableCharHaptic = false

    let store = ConversationStore.shared
    private let onlineEngine = OnlineChatEngine()
    private let localEngine = LocalInferenceEngine.shared
    private let skillService = OnlineSkillService.shared

    init() {
        Haptics.prepare()
    }

    // MARK: - Mode (per conversation)
    func setMode(_ newMode: ChatMode) {
        store.mutateCurrent { $0.mode = newMode }
    }

    // MARK: - Clear
    func clearMessages() {
        store.mutateCurrent { $0.messages.removeAll() }
        errorMessage = nil
    }

    // MARK: - Delete (single)
    func deleteMessage(_ message: ChatMessage) {
        withAnimation(.spring(response: 0.35, dampingFraction: 0.8)) {
            store.mutateCurrent { $0.messages.removeAll { $0.id == message.id } }
        }
    }

    // MARK: - Multi-select delete
    func deleteMessages(ids: Set<UUID>) {
        guard !ids.isEmpty else { return }
        withAnimation(.spring(response: 0.35, dampingFraction: 0.8)) {
            store.mutateCurrent { $0.messages.removeAll { ids.contains($0.id) } }
        }
    }

    // MARK: - Send
    func send(settings: APISettings, activeModel: LocalModel?) {
        let text = inputText.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty, !isGenerating else { return }
        guard store.currentId != nil else { return }

        enableCharHaptic = settings.hapticPerChar
        if enableCharHaptic { Haptics.prepare() }

        errorMessage = nil
        statusMessage = store.currentMode == .online ? "正在连接…" : "正在准备本地推理…"
        isGenerating = true
        let userMsg = ChatMessage(role: .user, content: text)
        store.mutateCurrent { $0.messages.append(userMsg) }
        inputText = ""
        store.autoTitleIfNeeded()

        switch store.currentMode {
        case .online:
            Task { await runOnline(userText: text, settings: settings) }
        case .offline:
            Task { await runOffline(activeModel: activeModel) }
        }
    }

    // MARK: - Online Flow（内置联网技能，无需后端）
    private func runOnline(userText: String, settings: APISettings) async {
        defer {
            isGenerating = false
            statusMessage = nil
            store.persist()
        }
        guard settings.isConfigured else {
            errorMessage = ChatError.notConfigured.errorDescription
            return
        }

        // 原生定位（设备能力，按需触发，不依赖大模型主动调用）
        if containsLocationIntent(userText) {
            LocationService.shared.requestLocation()
        }

        // 系统提示：联网功能全部由大模型主动调用；需要时在思考后只输出调用标签并停止
        var systemPrompt: String? = nil
        if settings.onlineFeaturesEnabled {
            systemPrompt = "你是一个智能助手。当你需要实时或最新的外部信息时，请在内部完成深度思考后，仅输出一个调用标签来获取数据，并立即结束回复，不要输出任何额外文字：<search>查询词</search>（网络搜索）、<weather>城市名</weather>（天气查询）、<web>网页URL</web>（网页摘要）、<image>画面描述</image>（生成图片）。只输出标签本身，不要复述、不要解释、不要在标签前后添加任何文字；输出标签后立刻停止。若用户的问题不需要任何外部信息，则像平常一样正常回答即可。"
        }

        let aiId = appendAssistant()
        statusMessage = "正在生成回复…"

        var raw = ""
        var calledTool = false
        do {
            var history = store.current?.messages.filter { $0.id != aiId } ?? []
            if let sp = systemPrompt { history.insert(ChatMessage(role: .system, content: sp), at: 0) }

            try await onlineEngine.streamChat(messages: history, settings: settings,
                onToken: { [weak self] token in
                    guard let self else { return }
                    raw += token
                    self.setDisplay(to: aiId, cleaned: Self.stripCallTags(raw))
                },
                onReasoning: { [weak self] token in
                    self?.appendReasoning(to: aiId, token: token)
                }
            )
            finishAssistant(aiId)

            // 大模型主动调用联网功能：执行标签并展示结果，模型即「自行结束」（不再二次整合）
            if settings.onlineFeaturesEnabled {
                let calls = Self.extractCalls(raw)
                if !calls.isEmpty {
                    var att: [MessageAttachment] = []
                    for (kind, content) in calls {
                        att.append(contentsOf: await executeCall(kind: kind, content: content))
                    }
                    if !att.isEmpty { appendAttachments(aiId, att) }
                    // 深度思考过程保留；正文仅保留一句极简动作说明（非模型发言）
                    setDisplay(to: aiId, cleaned: Self.callNote(calls))
                    calledTool = true
                }
            }

            if settings.ttsEnabled, !calledTool,
               let last = store.current?.messages.last(where: { $0.role == .assistant }) {
                await synthesizeAndPlay(text: last.content)
            }
        } catch {
            errorMessage = error.localizedDescription
            failAssistant(aiId, fallback: "（请求失败，请重试）")
        }
    }

    // MARK: - Offline Flow
    private func runOffline(activeModel: LocalModel?) async {
        defer {
            isGenerating = false
            statusMessage = nil
            store.persist()
        }
        guard let model = activeModel else {
            errorMessage = ChatError.noActiveModel.errorDescription
            return
        }
        let dir = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("LocalModels", isDirectory: true)
        let path = dir.appendingPathComponent(model.filename)
        guard FileManager.default.fileExists(atPath: path.path) else {
            errorMessage = "模型文件不存在，请先在「本地模型管理」中下载"
            return
        }

        do {
            statusMessage = "正在加载本地模型，请稍候…"
            try await localEngine.loadModel(at: path.path, contextLength: model.contextLength)
        } catch {
            errorMessage = error.localizedDescription
            return
        }

        let aiId = appendAssistant()
        statusMessage = "正在生成回复…"

        do {
            let history = store.current?.messages.filter { $0.id != aiId } ?? []
            try await localEngine.streamInfer(messages: history) { [weak self] token in
                guard let self else { return }
                self.appendToken(to: aiId, token: token)
            }
            finishAssistant(aiId)
        } catch {
            errorMessage = error.localizedDescription
            failAssistant(aiId, fallback: "（推理失败：\(error.localizedDescription)）")
        }
    }

    // MARK: - Assistant message helpers
    private func appendAssistant(with attachments: [MessageAttachment] = []) -> UUID {
        let id = UUID()
        store.mutateCurrent {
            $0.messages.append(ChatMessage(id: id, role: .assistant, content: "",
                                           isStreaming: true, attachments: attachments))
        }
        return id
    }

    private func appendToken(to id: UUID, token: String) {
        store.mutateCurrent { conv in
            if let i = conv.messages.firstIndex(where: { $0.id == id }) {
                conv.messages[i].content += token
            }
        }
        if enableCharHaptic { Haptics.tick() }
    }

    private func setDisplay(to id: UUID, cleaned: String) {
        store.mutateCurrent { conv in
            if let i = conv.messages.firstIndex(where: { $0.id == id }) {
                conv.messages[i].content = cleaned
            }
        }
        if enableCharHaptic { Haptics.tick() }
    }

    private func appendReasoning(to id: UUID, token: String) {
        store.mutateCurrent { conv in
            if let i = conv.messages.firstIndex(where: { $0.id == id }) {
                conv.messages[i].reasoning += token
            }
        }
    }

    private func appendAttachments(_ id: UUID, _ att: [MessageAttachment]) {
        store.mutateCurrent { conv in
            if let i = conv.messages.firstIndex(where: { $0.id == id }) {
                conv.messages[i].attachments.append(contentsOf: att)
            }
        }
    }

    private func finishAssistant(_ id: UUID) {
        store.mutateCurrent { conv in
            if let i = conv.messages.firstIndex(where: { $0.id == id }) {
                conv.messages[i].isStreaming = false
            }
        }
    }

    private func failAssistant(_ id: UUID, fallback: String) {
        store.mutateCurrent { conv in
            if let i = conv.messages.firstIndex(where: { $0.id == id }) {
                if conv.messages[i].content.isEmpty {
                    conv.messages[i].content = fallback
                }
                conv.messages[i].isStreaming = false
            }
        }
    }

    // MARK: - AI 主动调用的联网功能执行
    private func executeCall(kind: String, content: String) async -> [MessageAttachment] {
        switch kind {
        case "search":
            if let results = try? await skillService.search(query: content), !results.isEmpty {
                return [.searchResults(results)]
            }
        case "weather":
            if let w = try? await skillService.weather(from: content) {
                return [.weather(w)]
            }
        case "web":
            if let page = try? await skillService.fetchWebpage(url: content) {
                return [.webpage(page)]
            }
        case "image":
            if let url = try? await skillService.generateImage(prompt: content) {
                return [.image(url: url)]
            }
        default:
            break
        }
        return []
    }

    /// 工具调用后的极简动作说明（由 App 生成，非模型发言）
    static func callNote(_ calls: [(kind: String, content: String)]) -> String {
        let labelMap = ["search": "搜索", "weather": "天气", "web": "网页摘要", "image": "图片生成"]
        let parts = calls.compactMap { (kind, content) -> String? in
            guard let label = labelMap[kind] else { return nil }
            return "\(label)「\(content)」"
        }
        return "🛠 已调用：" + parts.joined(separator: "、")
    }

    // MARK: - TTS
    private func synthesizeAndPlay(text: String) async {
        do {
            let url = try await skillService.synthesizeSpeech(text: text)
            currentAudioURL = url
        } catch {
            // 语音合成失败不影响文本展示
        }
    }

    func stopAudio() {
        currentAudioURL = nil
        isPlayingAudio = false
    }

    // MARK: - PDF Export
    func exportPDF() throws -> URL {
        guard let msgs = store.current?.messages, !msgs.isEmpty else { throw ChatError.notConfigured }
        return try PDFExporter.export(messages: msgs)
    }

    // MARK: - Intent Detection（仅保留原生定位；联网功能改由大模型主动调用）
    private func containsLocationIntent(_ text: String) -> Bool {
        let keywords = ["我的位置", "我在哪", "当前位置", "附近", "定位", "我在哪里", "周边"]
        return keywords.contains { text.contains($0) }
    }

    // MARK: - 模型主动调用标签解析

    /// 从模型回复中提取 <search>/<weather>/<web>/<image> 调用标签
    static func extractCalls(_ text: String) -> [(kind: String, content: String)] {
        var results: [(String, String)] = []
        guard let regex = try? NSRegularExpression(
            pattern: #"<(search|image|weather|web)>(.*?)</\1>"#,
            options: [.dotMatchesLineSeparators, .caseInsensitive]) else { return results }
        let ns = text as NSString
        let matches = regex.matches(in: text, range: NSRange(text.startIndex..., in: text))
        for m in matches {
            let r = m.range
            guard r.location != NSNotFound else { continue }
            let kind = ns.substring(with: m.range(at: 1)).lowercased()
            let content = ns.substring(with: m.range(at: 2)).trimmingCharacters(in: .whitespacesAndNewlines)
            if !content.isEmpty { results.append((kind, content)) }
        }
        return results
    }

    /// 移除模型回复中的调用标签（仅展示干净文本）
    static func stripCallTags(_ text: String) -> String {
        guard let regex = try? NSRegularExpression(
            pattern: #"<(search|image|weather|web)>(.*?)</\1>"#,
            options: [.dotMatchesLineSeparators, .caseInsensitive]) else { return text }
        let cleaned = regex.stringByReplacingMatches(
            in: text, range: NSRange(text.startIndex..., in: text), withTemplate: "")
        return cleaned.trimmingCharacters(in: .whitespacesAndNewlines)
    }
}
