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

        // 显式关键词触发（用户主动意图）
        let wantsImage = containsImageIntent(userText)
        let wantsSearch = containsSearchIntent(userText)
        let wantsLocation = containsLocationIntent(userText)
        let wantsWeather = containsWeatherIntent(userText)
        let wantsWebpage = containsWebpageIntent(userText)
        let pageURL = extractURL(userText)

        // 图片生成：只发图片，不调用大模型
        if wantsImage {
            do {
                let url = try await skillService.generateImage(prompt: userText)
                store.mutateCurrent {
                    $0.messages.append(ChatMessage(role: .user, content: userText,
                                                   attachments: [.image(url: url)]))
                }
            } catch {
                errorMessage = "图片生成失败：\(error.localizedDescription)"
            }
            return
        }

        var attachments: [MessageAttachment] = []
        var extraContexts: [String] = []
        // 本轮已通过关键词执行过的技能类型（避免与模型主动调用重复）
        var executedKinds = Set<String>()

        // 网络搜索（维基百科，免密钥）
        if wantsSearch {
            if let results = try? await skillService.search(query: userText), !results.isEmpty {
                attachments.append(.searchResults(results))
                let ctx = results.prefix(3).map { "【\($0.title)】\($0.snippet ?? "")" }.joined(separator: "\n")
                extraContexts.append("以下是网络搜索结果，请参考并尽量注明来源后再作答：\n\(ctx)")
                executedKinds.insert("search")
            }
        }

        // 天气（open-meteo，免密钥）
        if wantsWeather {
            if let w = try? await skillService.weather(from: userText) {
                attachments.append(.weather(w))
                extraContexts.append("当前\(w.city)天气：\(w.condition)，气温\(String(format: "%.0f", w.temperature))\(w.units)。")
                executedKinds.insert("weather")
            }
        }

        // 网页抓取与摘要（直连，免密钥）
        if wantsWebpage, let url = pageURL {
            if let page = try? await skillService.fetchWebpage(url: url) {
                attachments.append(.webpage(page))
                extraContexts.append("以下是网页内容（标题：\(page.title)），请基于它作答：\n\(page.summary)")
                executedKinds.insert("web")
            }
        }

        // 定位
        if wantsLocation {
            LocationService.shared.requestLocation()
        }

        // 系统提示：允许模型主动调用联网功能（仅当开关打开）
        var systemPrompt: String? = nil
        if settings.onlineFeaturesEnabled {
            systemPrompt = "你是一个智能助手。当你需要实时/最新信息时，可以在回复中插入调用标签来获取数据：<search>查询词</search>（网络搜索）、<weather>城市名</weather>（天气）、<web>网页URL</web>（网页摘要）、<image>画面描述</image>（生成图片）。仅在确实需要时调用，并基于返回结果作答，不要复述标签本身。"
        }

        let aiId = appendAssistant(with: attachments)
        statusMessage = "正在生成回复…"

        var raw = ""
        do {
            var history = store.current?.messages.filter { $0.id != aiId } ?? []
            if let sp = systemPrompt { history.insert(ChatMessage(role: .system, content: sp), at: 0) }
            for ctx in extraContexts { history.append(ChatMessage(role: .user, content: ctx)) }

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

            // AI 主动调用联网功能：执行标签并二次整合
            if settings.onlineFeaturesEnabled {
                let calls = Self.extractCalls(raw)
                if !calls.isEmpty {
                    var ctx2: [String] = []
                    var att2: [MessageAttachment] = []
                    for (kind, content) in calls where !executedKinds.contains(kind) {
                        await executeCall(kind: kind, content: content, ctx: &ctx2, att: &att2)
                    }
                    if !ctx2.isEmpty || !att2.isEmpty {
                        clearContent(aiId)
                        if !att2.isEmpty { appendAttachments(aiId, att2) }
                        statusMessage = "正在整合联网结果…"
                        var history2 = store.current?.messages.filter { $0.id != aiId } ?? []
                        if let sp = systemPrompt { history2.insert(ChatMessage(role: .system, content: sp), at: 0) }
                        for c in ctx2 { history2.append(ChatMessage(role: .user, content: c)) }
                        var raw2 = ""
                        try await onlineEngine.streamChat(messages: history2, settings: settings,
                            onToken: { [weak self] token in
                                guard let self else { return }
                                raw2 += token
                                self.setDisplay(to: aiId, cleaned: Self.stripCallTags(raw2))
                            },
                            onReasoning: { [weak self] token in
                                self?.appendReasoning(to: aiId, token: token)
                            }
                        )
                        finishAssistant(aiId)
                    }
                }
            }

            if settings.ttsEnabled,
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

    private func clearContent(_ id: UUID) {
        store.mutateCurrent { conv in
            if let i = conv.messages.firstIndex(where: { $0.id == id }) {
                conv.messages[i].content = ""
                conv.messages[i].reasoning = ""
                conv.messages[i].isStreaming = true
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
    private func executeCall(kind: String, content: String,
                             ctx: inout [String], att: inout [MessageAttachment]) async {
        switch kind {
        case "search":
            if let results = try? await skillService.search(query: content), !results.isEmpty {
                att.append(.searchResults(results))
                let c = results.prefix(3).map { "【\($0.title)】\($0.snippet ?? "")" }.joined(separator: "\n")
                ctx.append("网络搜索「\(content)」结果：\n\(c)")
            }
        case "weather":
            if let w = try? await skillService.weather(from: content) {
                att.append(.weather(w))
                ctx.append("\(w.city)天气：\(w.condition)，气温\(String(format: "%.0f", w.temperature))\(w.units)。")
            }
        case "web":
            if let page = try? await skillService.fetchWebpage(url: content) {
                att.append(.webpage(page))
                ctx.append("网页（\(page.title)）内容：\n\(page.summary)")
            }
        case "image":
            if let url = try? await skillService.generateImage(prompt: content) {
                att.append(.image(url: url))
            }
        default:
            break
        }
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

    // MARK: - Intent Detection（触发词，已扩充）
    private func containsImageIntent(_ text: String) -> Bool {
        let keywords = ["画一张", "画一个", "生成图片", "生成一张图", "生成插画", "生成海报", "画图", "画张图",
                        "AI画", "AI生成", "设计一张", "画个图", "画幅", "画个", "帮我画", "给我画", "画出来", "出张图", "配图"]
        return keywords.contains { text.contains($0) }
    }

    private func containsSearchIntent(_ text: String) -> Bool {
        let keywords = ["搜索", "搜一下", "查一下", "帮我查", "查查", "最新", "新闻", "今天", "实时", "搜一搜",
                        "百度", "谷歌", "资料", "百科", "是什么", "介绍一下", "近况", "发生了什么", "怎么回事", "为什么", "对比一下", "谁"]
        return keywords.contains { text.contains($0) }
    }

    private func containsLocationIntent(_ text: String) -> Bool {
        let keywords = ["我的位置", "我在哪", "当前位置", "附近", "定位", "我在哪里", "周边"]
        return keywords.contains { text.contains($0) }
    }

    private func containsWeatherIntent(_ text: String) -> Bool {
        let keywords = ["天气", "气温", "温度", "下雨", "降雨", "weather", "多少度", "冷不冷", "热不冷",
                        "湿度", "穿衣", "气象", "会下雨吗", "适合出门吗", "紫外线", "台风"]
        return keywords.contains { text.lowercased().contains($0.lowercased()) }
    }

    private func containsWebpageIntent(_ text: String) -> Bool {
        guard let url = extractURL(text) else { return false }
        let keywords = ["总结", "摘要", "概括", "分析", "翻译", "读一下", "读这", "summarize", "提炼", "要点", "这篇", "这个网页", "解读", "说说这个"]
        let onlyURL = text.trimmingCharacters(in: .whitespacesAndNewlines) == url
        return onlyURL || keywords.contains { text.contains($0) }
    }

    private func extractURL(_ text: String) -> String? {
        guard let detector = try? NSDataDetector(types: NSTextCheckingResult.CheckingType.link.rawValue) else { return nil }
        let matches = detector.matches(in: text, range: NSRange(text.startIndex..., in: text))
        return matches.first.flatMap { Range($0.range, in: text).map { String(text[$0]) } }
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
