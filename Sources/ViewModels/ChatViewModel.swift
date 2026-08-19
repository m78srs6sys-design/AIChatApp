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
        store.persist()
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

    // MARK: - Online Flow（内置联网技能，Agent 式多步工具调用）
    /// 最近一次定位结果，供「我的位置 / 附近」类工具调用复用
    private var lastLocation: (lat: Double, lon: Double, city: String)?

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

        // 系统提示：联网功能全部由大模型主动调用；可链式调用多个工具，最后给出带解释的最终回答
        var systemPrompt: String? = nil
        if settings.onlineFeaturesEnabled {
            var sp = """
            你是一个会主动使用工具的智能助手。工作流程：
            1) 先在脑中深度思考用户真正需要什么信息。
            2) 需要时调用工具获取信息：
               - <location/> 获取用户当前定位（城市 / 坐标）
               - <search>查询词</search> 联网搜索
               - <weather>城市名 或 "我的位置"</weather> 查询天气
               - <web>网页URL</web> 网页摘要
               - <image>英文画面描述</image> 生成图片
            3) 可以连续调用多个工具来逐步完成任务，例如：先 <location/> 得到所在城市，再 <search>该城市 附近景点</search>，再 <weather>我的位置</weather>。
            4) 收集到足够信息后，用自然语言给出最终回答并解释；需要的数据会自动以卡片形式展示。
            规则：每次只输出一个工具标签；工具标签之外不要写多余文字。当你已经拿到所需信息、准备回答时，不要再输出工具标签，直接写回答。
            """
            let wf = Self.workflowPrompt(settings.workflows)
            if !wf.isEmpty { sp += "\n\n" + wf }
            systemPrompt = sp
        }

        let aiId = appendAssistant()
        statusMessage = "正在思考…"

        var attachments: [MessageAttachment] = []
        var toolTurns: [ChatMessage] = []
        var finalText = ""
        var iteration = 0
        let maxIter = 6

        do {
            while iteration < maxIter {
                iteration += 1
                var history = store.current?.messages.filter { $0.id != aiId } ?? []
                if let sp = systemPrompt { history.insert(ChatMessage(role: .system, content: sp), at: 0) }
                history.append(contentsOf: toolTurns)
                if iteration > 1 {
                    history.append(ChatMessage(role: .user,
                        content: "[继续] 根据已获得的工具结果继续。若信息已足够，请直接给出最终回答（不要再调用工具）；若仍不足，可继续调用其它工具，但不要重复调用已成功执行过的同一工具。"))
                }

                var raw = ""
                try await onlineEngine.streamChat(messages: history, settings: settings,
                    onToken: { [weak self] token in
                        guard let self else { return }
                        raw += token
                        // 出现工具标签即视为中间步骤，冻结气泡；最终回答（无标签）才实时流式
                        if Self.extractCalls(raw).isEmpty {
                            self.setDisplay(to: aiId, cleaned: Self.stripCallTags(raw))
                        }
                    },
                    onReasoning: { [weak self] token in
                        self?.appendReasoning(to: aiId, token: token)
                    }
                )

                let calls = Self.extractCalls(raw)
                if calls.isEmpty || !settings.onlineFeaturesEnabled {
                    finalText = Self.stripCallTags(raw)
                    break
                }

                // 执行本轮工具调用，把结果作为后续上下文喂回模型
                for (kind, content) in calls {
                    let label = Self.toolLabel(kind)
                    statusMessage = "正在调用工具：\(label)…"
                    let (att, resultText) = await executeCallWithResult(kind: kind, content: content)
                    attachments.append(contentsOf: att)
                    toolTurns.append(ChatMessage(role: .user,
                        content: "[工具结果：\(label)]\n\(resultText)"))
                }
            }

            // 达到上限仍未产出最终文本：强制收尾，要求模型基于已有结果作答
            if finalText.isEmpty {
                var history = store.current?.messages.filter { $0.id != aiId } ?? []
                if let sp = systemPrompt { history.insert(ChatMessage(role: .system, content: sp), at: 0) }
                history.append(contentsOf: toolTurns)
                history.append(ChatMessage(role: .user,
                    content: "[请基于已有工具结果，直接给出你的最终回答，不要调用工具。]"))
                var raw = ""
                try await onlineEngine.streamChat(messages: history, settings: settings,
                    onToken: { [weak self] token in
                        guard let self else { return }
                        raw += token
                        self.setDisplay(to: aiId, cleaned: Self.stripCallTags(raw))
                    },
                    onReasoning: { _ in }
                )
                finalText = Self.stripCallTags(raw)
            }

            if finalText.isEmpty { finalText = Self.callNoteFromAttachments(attachments) }
            setDisplay(to: aiId, cleaned: finalText)
            if !attachments.isEmpty { appendAttachments(aiId, attachments) }
            finishAssistant(aiId)

            if settings.ttsEnabled, !finalText.isEmpty {
                await synthesizeAndPlay(text: finalText)
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

        if #available(iOS 16.1, *) {
            DownloadActivityManager.shared.startInference(modelName: model.name)
        }

        do {
            let history = store.current?.messages.filter { $0.id != aiId } ?? []
            var tokenCount = 0
            try await localEngine.streamInfer(messages: history) { [weak self] token in
                guard let self else { return }
                self.appendToken(to: aiId, token: token)
                tokenCount += 1
                if tokenCount % 4 == 0 {
                    let p = min(0.95, Double(tokenCount) / 600.0)
                    if #available(iOS 16.1, *) {
                        DownloadActivityManager.shared.updateInference(tokens: tokenCount, progress: p)
                    }
                }
            }
            finishAssistant(aiId)
        } catch {
            errorMessage = error.localizedDescription
            failAssistant(aiId, fallback: "（推理失败：\(error.localizedDescription)）")
        }

        if #available(iOS 16.1, *) {
            DownloadActivityManager.shared.endInference()
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

    // MARK: - AI 主动调用的联网功能执行（返回附件 + 工具结果文本）
    private func executeCallWithResult(kind: String, content: String) async -> ([MessageAttachment], String) {
        switch kind {
        case "search":
            var q = content
            if let loc = lastLocation,
               ["附近", "周边", "这里", "我的位置", "当前位置"].contains(where: { q.contains($0) }) {
                q = "\(q)（\(loc.city)）"
            }
            if let results = try? await skillService.search(query: q), !results.isEmpty {
                let text = results.prefix(3).map { "· \($0.title)：\($0.snippet ?? "")" }.joined(separator: "\n")
                return ([.searchResults(results)], "搜索「\(content)」结果：\n\(text)")
            }
            return ([], "搜索「\(content)」未找到结果。")

        case "weather":
            let locWords = ["我的位置", "附近", "当前位置", "这里", "周边", "定位"]
            if locWords.contains(where: { content.contains($0) }), let loc = lastLocation {
                if let w = try? await skillService.weather(lat: loc.lat, lon: loc.lon, cityName: loc.city) {
                    return ([.weather(w)], Self.weatherResultText(w))
                }
            } else if let w = try? await skillService.weather(from: content) {
                return ([.weather(w)], Self.weatherResultText(w))
            }
            return ([], "天气查询「\(content)」失败。")

        case "web":
            if let page = try? await skillService.fetchWebpage(url: content) {
                return ([.webpage(page)], "网页「\(page.title)」内容：\n\(page.summary.prefix(500))")
            }
            return ([], "网页抓取「\(content)」失败。")

        case "image":
            if let url = try? await skillService.generateImage(prompt: content) {
                return ([.image(url: url)], "已生成图片：\(content)")
            }
            return ([], "图片生成失败。")

        case "location":
            if let loc = await LocationService.shared.awaitLocation() {
                // 街道级地址（用于非天气场景）
                let streetAddress = (await skillService.reverseGeocodeStreet(lat: loc.coordinate.latitude,
                                                                             lon: loc.coordinate.longitude))
                // 城市级地址（用于天气等城市级场景）
                let city = (await skillService.reverseGeocode(lat: loc.coordinate.latitude,
                                                              lon: loc.coordinate.longitude)) ?? "未知地点"
                lastLocation = (lat: loc.coordinate.latitude, lon: loc.coordinate.longitude, city: city)
                let displayName = streetAddress ?? city
                let att: [MessageAttachment] = [.location(latitude: loc.coordinate.latitude,
                                                         longitude: loc.coordinate.longitude,
                                                         name: displayName)]
                return (att, "已获取定位：\(displayName)，纬度 \(String(format: "%.4f", loc.coordinate.latitude))，经度 \(String(format: "%.4f", loc.coordinate.longitude))")
            }
            return ([], "无法获取定位（未授权或定位失败）。如需天气 / 周边信息，请直接告诉我城市名。")

        default:
            return ([], "")
        }
    }

    private static func toolLabel(_ kind: String) -> String {
        switch kind {
        case "search": return "搜索"
        case "weather": return "天气"
        case "web": return "网页摘要"
        case "image": return "图片生成"
        case "location": return "定位"
        default: return kind
        }
    }

    private static func weatherResultText(_ w: WeatherInfo) -> String {
        var s = "\(w.city)天气：\(w.condition)，气温 \(String(format: "%.0f", w.temperature))\(w.units)"
        if let h = w.humidity { s += "，湿度 \(h)%" }
        if let wind = w.windSpeed { s += "，风速 \(String(format: "%.0f", wind)) km/h" }
        return s
    }

    /// 工具调用后的极简动作说明（兜底，非模型发言）
    static func callNoteFromAttachments(_ att: [MessageAttachment]) -> String {
        let labels = att.compactMap { a -> String? in
            switch a {
            case .searchResults: return "搜索结果"
            case .weather: return "天气"
            case .webpage: return "网页摘要"
            case .image: return "图片"
            case .location: return "定位"
            }
        }
        return labels.isEmpty ? "（已完成）" : "🛠 已调用：\(labels.joined(separator: "、"))"
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

    // MARK: - 模型主动调用标签解析

    /// 把用户自定义的「场景 → 工具流程」方案，渲染成注入系统提示的指令文本
    private static func workflowPrompt(_ presets: [WorkflowPreset]) -> String {
        let enabled = presets.filter { $0.enabled && !$0.steps.isEmpty }
        guard !enabled.isEmpty else { return "" }
        var lines = ["## 常用任务的标准处理流程（遇到对应类型的问题，请优先按下列顺序逐个调用工具）："]
        for p in enabled {
            let stepTexts = p.steps.enumerated().map { (i, s) in "\(i + 1). \(s.tool.tag(param: s.param))" }
            lines.append("- 【\(p.name)】\(p.trigger)： \(stepTexts.joined(separator: " "))")
        }
        return lines.joined(separator: "\n")
    }

    static func extractCalls(_ text: String) -> [(kind: String, content: String)] {
        var results: [(String, String)] = []
        guard let regex = try? NSRegularExpression(
            pattern: #"<(search|image|weather|web)>(.*?)</\1>"#,
            options: [.dotMatchesLineSeparators, .caseInsensitive]) else { return results }
        let ns = text as NSString
        let matches = regex.matches(in: text, range: NSRange(text.startIndex..., in: text))
        for m in matches {
            let kind = ns.substring(with: m.range(at: 1)).lowercased()
            let content = ns.substring(with: m.range(at: 2)).trimmingCharacters(in: .whitespacesAndNewlines)
            if !content.isEmpty { results.append((kind, content)) }
        }
        // <location/> 或 <location></location>：定位工具，无参数
        if let locRegex = try? NSRegularExpression(pattern: #"<location\s*/?>"#,
                                                   options: [.caseInsensitive]),
           locRegex.firstMatch(in: text, range: NSRange(text.startIndex..., in: text)) != nil {
            results.append(("location", ""))
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
