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

    /// 当前正在执行的生成任务（用于强制终止）
    private var generationTask: Task<Void, Never>?

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
        store.persist()   // 立即落盘，防止生成过程中 App 被杀导致用户消息丢失
        inputText = ""
        store.autoTitleIfNeeded()

        switch store.currentMode {
        case .online:
            generationTask = Task { await runOnline(userText: text, settings: settings) }
        case .offline:
            generationTask = Task { await runOffline(activeModel: activeModel) }
        }
    }

    /// 强制终止所有网络请求和 AI 生成
    func stopGeneration() {
        generationTask?.cancel()
        generationTask = nil
        isGenerating = false
        statusMessage = nil
        errorMessage = nil
        store.persist()
    }

    /// 重新生成最后一条 AI 回复（删除该回复及其后内容，用上一条用户消息重新发送）
    func regenerateLast(settings: APISettings, activeModel: LocalModel?) {
        guard !isGenerating else { return }
        guard let msgs = store.current?.messages,
              let lastAI = msgs.last(where: { $0.role == .assistant }) else { return }
        store.mutateCurrent { conv in
            if let idx = conv.messages.firstIndex(where: { $0.id == lastAI.id }) {
                conv.messages.removeSubrange(idx...)
            }
        }
        store.persist()
        if let lastUser = store.current?.messages.last(where: { $0.role == .user }) {
            inputText = lastUser.content
            send(settings: settings, activeModel: activeModel)
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

        // 系统提示：所有附加功能仅当联网附加开启时可用
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
               - <image>英文画面描述</image> 生成 AI 创意图片（当用户想生成画作、插画、海报等创意内容时使用）
               - <imageSearch>查询词</imageSearch> 搜索真实照片（当用户问某物/某地长什么样、想看真实图片时使用，区别于 AI 生成图片）
               - <card>HTML 代码</card> 生成可视化卡片（仅当用户主动要求可视化，或纯文字无法表达清楚时使用；卡片内容需是完整 HTML）
               - <system>命令</system> 执行系统操作（如 brightness 0.5 调节亮度、低电量 打开电池设置、wifi、蓝牙、显示、声音）
            3) 可以连续调用多个工具来逐步完成任务，例如：先 <location/> 得到所在城市，再 <search>该城市 附近景点</search>，再 <weather>我的位置</weather>。
            4) 收集到足够信息后，用自然语言给出最终回答并解释；需要的数据会自动以卡片形式展示。
            规则：
            - 每次只输出一个工具标签；工具标签之外不要写多余文字。
            - 生成图片时只能使用 <image>描述</image> 标签，严禁输出 <img> 标签、Markdown 图片语法 ![...](...)、<picture> 或任何 HTML/XML 代码来替代。系统会自动把 <image> 标签渲染成真实图片。
            - 当你已经拿到所需信息、准备回答时，不要再输出工具标签，直接写回答。
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
        // 已调用过的工具缓存（防止无限循环，同一工具+同内容只执行一次）
        var calledTools = Set<String>()

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
                        // 始终过滤标签，确保用户看不到任何标签内容
                        self.setDisplay(to: aiId, cleaned: Self.stripCallTags(raw))
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
                    // 防重复调用：同一工具+同内容只执行一次
                    let callKey = "\(kind):\(content)"
                    if calledTools.contains(callKey) {
                        toolTurns.append(ChatMessage(role: .user,
                            content: "[工具结果：\(Self.toolLabel(kind))] 已执行过，无需重复调用。"))
                        continue
                    }
                    calledTools.insert(callKey)
                    let label = Self.toolLabel(kind)
                    statusMessage = "正在调用工具：\(label)…"
                    let (att, resultText) = await executeCallWithResult(kind: kind, content: content, settings: settings)
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
                synthesizeAndPlay(text: finalText)
            }
        } catch {
            guard !Task.isCancelled else { return } // 用户主动终止，不报错
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
            guard !Task.isCancelled else { return } // 用户主动终止，不报错
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
    private func executeCallWithResult(kind: String, content: String, settings: APISettings) async -> ([MessageAttachment], String) {
        switch kind {
        case "search":
            var q = content
            if let loc = lastLocation,
               ["附近", "周边", "这里", "我的位置", "当前位置"].contains(where: { q.contains($0) }) {
                q = "\(q)（\(loc.city)）"
            }
            if let results = try? await skillService.search(query: q, apiKey: settings.apiKey, baseURL: settings.apiURL), !results.isEmpty {
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
                return ([.webpage(page)], "网页「\(page.title)」内容：\n\(page.summary.prefix(2000))")
            }
            return ([], "网页抓取「\(content)」失败。")

        case "image":
            // 图片生成：优先走独立图片 API（用户对话 API 通常不支持 /v1/images），
            // 服务层内部会做多端点轮询 + 失败兜底
            do {
                let url = try await skillService.generateImage(
                    prompt: content,
                    apiKey: settings.apiKey,
                    baseURL: settings.apiURL
                )
                return ([.image(url: url)], "已生成图片：\(content)")
            } catch {
                return ([], "图片生成失败：\(Self.friendlyImageError(error))。请检查对话 API 是否支持图片生成，或稍后再试。")
            }

        case "imagesearch":
            if let url = try? await skillService.searchImage(query: content) {
                return ([.image(url: url)], "已找到「\(content)」的真实图片")
            }
            return ([], "未找到「\(content)」的真实图片，已尝试多个图片搜索源。")

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

        case "card":
            // HTML 卡片：清洗 markdown 代码块标记后直接作为附件渲染
            var cardHTML = content
            cardHTML = cardHTML.replacingOccurrences(of: "```[a-zA-Z]*", with: "", options: .regularExpression)
                .trimmingCharacters(in: .whitespacesAndNewlines)
            let card = MessageAttachment.htmlCard(html: cardHTML)
            return ([card], "[HTML 卡片已生成]")

        case "system":
            let (desc, _) = await skillService.executeSystemAction(command: content)
            let att = MessageAttachment.systemAction(action: content, description: desc)
            return ([att], "系统操作「\(content)」：\(desc)")

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
        case "imagesearch": return "真实图片"
        case "location": return "定位"
        case "card": return "可视化卡片"
        case "system": return "系统操作"
        default: return kind
        }
    }

    /// 把底层图片生成错误翻译成用户可理解的提示
    private static func friendlyImageError(_ error: Error) -> String {
        let ns = error as NSError
        switch ns.code {
        case NSURLErrorTimedOut, NSURLErrorCannotConnectToHost, NSURLErrorNetworkConnectionLost,
             NSURLErrorNotConnectedToInternet:
            return "网络连接异常"
        case 400: return "请求参数被拒绝"
        case 401, 403: return "API 密钥无效或无权限"
        case 404: return "当前 API 不支持图片生成（缺少 /v1/images 接口）"
        case 429: return "请求过于频繁，请稍后再试"
        default: return "服务暂不可用"
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
            case .htmlCard: return "可视化卡片"
            case .systemAction: return "系统操作"
            }
        }
        return labels.isEmpty ? "（已完成）" : "🛠 已调用：\(labels.joined(separator: "、"))"
    }

    // MARK: - TTS（系统本地朗读，无需网络/密钥）
    private func synthesizeAndPlay(text: String) {
        SpeechService.shared.speak(text)
        isPlayingAudio = true
    }

    func stopAudio() {
        SpeechService.shared.stop()
        currentAudioURL = nil
        isPlayingAudio = false
    }

    // MARK: - PDF Export
    func exportPDF() async throws -> URL {
        guard let msgs = store.current?.messages, !msgs.isEmpty else { throw ChatError.notConfigured }
        return try await PDFExporter.export(messages: msgs)
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
        
        // 1. 尝试解析 JSON 格式的工具调用（优先）
        // 找到所有可能的 JSON 对象（从 { 开始，到匹配的 } 结束）
        var depth = 0
        var startIdx: String.Index?
        for (idx, char) in text.enumerated() {
            let index = text.index(text.startIndex, offsetBy: idx)
            if char == "{" {
                if depth == 0 { startIdx = index }
                depth += 1
            } else if char == "}" {
                depth -= 1
                if depth == 0, let start = startIdx {
                    let jsonStr = String(text[start...index])
                    // 尝试解析 JSON
                    if let jsonData = jsonStr.data(using: .utf8),
                       let json = try? JSONSerialization.jsonObject(with: jsonData) as? [String: Any],
                       let name = json["name"] as? String {
                        let kind = name.lowercased()
                        var content = ""
                        // 提取 arguments 中的 query 或 prompt
                        if let args = json["arguments"] as? [String: Any] {
                            if let q = args["query"] as? String {
                                content = q
                            } else if let p = args["prompt"] as? String {
                                content = p
                            }
                        }
                        results.append((kind, content))
                    }
                    startIdx = nil
                }
            }
        }
        
        // 2. 如果没有找到 JSON 格式，尝试解析 XML 标签格式
        if results.isEmpty {
            // 带内容的工具标签（注意 imageSearch 优先匹配，放在 image 前面）
            guard let regex = try? NSRegularExpression(
                pattern: #"<(imageSearch|search|image|weather|web|card|system)>(.*?)</\1>"#,
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
        }

        // 3. 兜底识别：模型不遵循工具标签、直接输出 HTML/XML/Markdown 图片语法时，
        //    识别其中的图片意图并转为「图片生成」工具调用（用户要求：识别 HTML/XML 以生成图片）。
        if results.isEmpty {
            // 3a. <img> HTML 标签：提取 alt / title / src 中的自然语言描述
            if let imgRegex = try? NSRegularExpression(
                pattern: #"<img\b[^>]*?(?:alt|title|src)\s*=\s*["']([^"']+)["'][^>]*>"#,
                options: [.caseInsensitive]) {
                let ns = text as NSString
                let matches = imgRegex.matches(in: text, range: NSRange(text.startIndex..., in: text))
                for m in matches {
                    let desc = ns.substring(with: m.range(at: 1))
                        .trimmingCharacters(in: .whitespacesAndNewlines)
                    if Self.isImageLikeDescription(desc) {
                        results.append(("image", desc))
                    }
                }
            }
            // 3b. Markdown 图片语法 ![描述](目标)：描述优先；目标非 URL 时也视为描述
            if results.isEmpty,
               let mdRegex = try? NSRegularExpression(
                pattern: #"!\[([^\]]*)\]\(([^)]*)\)"#,
                options: [.caseInsensitive]) {
                let ns = text as NSString
                let matches = mdRegex.matches(in: text, range: NSRange(text.startIndex..., in: text))
                for m in matches {
                    let alt = ns.substring(with: m.range(at: 1))
                        .trimmingCharacters(in: .whitespacesAndNewlines)
                    let dest = ns.substring(with: m.range(at: 2))
                        .trimmingCharacters(in: .whitespacesAndNewlines)
                    if !alt.isEmpty, Self.isImageLikeDescription(alt) {
                        results.append(("image", alt))
                    } else if !dest.isEmpty, !dest.lowercased().hasPrefix("http"),
                              Self.isImageLikeDescription(dest) {
                        results.append(("image", dest))
                    }
                }
            }
            // 3c. 其他 XML 变体（<Image>、<picture>、<image-generate> 等，含内容）
            if results.isEmpty,
               let xmlRegex = try? NSRegularExpression(
                pattern: #"<(?:image|picture|img|photo|generate-image|image-generate)[^>]*>([^<]{2,})</(?:image|picture|img|photo|generate-image|image-generate)>"#,
                options: [.dotMatchesLineSeparators, .caseInsensitive]) {
                let ns = text as NSString
                let matches = xmlRegex.matches(in: text, range: NSRange(text.startIndex..., in: text))
                for m in matches {
                    let desc = ns.substring(with: m.range(at: 1))
                        .trimmingCharacters(in: .whitespacesAndNewlines)
                    if Self.isImageLikeDescription(desc) {
                        results.append(("image", desc))
                    }
                }
            }
        }

        return results
    }

    /// 判断一段文本是否适合作为「图片生成」的描述（排除 URL / 空占位 / 纯代码片段）
    private static func isImageLikeDescription(_ text: String) -> Bool {
        let t = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !t.isEmpty, t.count >= 2, t.count <= 500 else { return false }
        let lower = t.lowercased()
        // 排除 URL、data URI、纯文件名
        if lower.hasPrefix("http") || lower.hasPrefix("data:") || lower.hasPrefix("//") { return false }
        if t.contains("/") && !t.contains(" ") && !t.contains("，") && !t.contains(",") { return false }
        // 排除占位符
        let placeholder = ["image", "img", "图片", "图", "photo", "picture", "image url",
                           "image_url", "src", "url", "image here", "example"]
        if placeholder.contains(lower) { return false }
        return true
    }

    /// 移除模型回复中的调用标签（仅展示干净文本）
    /// 覆盖所有工具标签：<imageSearch>、<search>、<image>、<weather>、<web>、<card>、<system>、<location/>
    /// 同时支持 JSON 格式：{"name": "xxx"} 或 {"name": "xxx", "arguments": {...}}
    static func stripCallTags(_ text: String) -> String {
        var result = text
        
        // 1. 移除 JSON 格式的工具调用（使用与 extractCalls 相同的逻辑）
        var depth = 0
        var startIdx: String.Index?
        var rangesToRemove: [Range<String.Index>] = []
        for (idx, char) in text.enumerated() {
            let index = text.index(text.startIndex, offsetBy: idx)
            if char == "{" {
                if depth == 0 { startIdx = index }
                depth += 1
            } else if char == "}" {
                depth -= 1
                if depth == 0, let start = startIdx {
                    let jsonStr = String(text[start...index])
                    // 检查是否是工具调用 JSON
                    if let jsonData = jsonStr.data(using: .utf8),
                       let json = try? JSONSerialization.jsonObject(with: jsonData) as? [String: Any],
                       json["name"] != nil {
                        rangesToRemove.append(start..<text.index(after: index))
                    }
                    startIdx = nil
                }
            }
        }
        // 从后往前移除，避免索引变化
        for range in rangesToRemove.reversed() {
            result.removeSubrange(range)
        }
        
        // 2. 移除 XML 格式的带内容标签：<xxx>...</xxx>
        if let regex = try? NSRegularExpression(
            pattern: #"<(imageSearch|search|image|weather|web|card|system)>(.*?)</\1>"#,
            options: [.dotMatchesLineSeparators, .caseInsensitive]) {
            result = regex.stringByReplacingMatches(
                in: result, range: NSRange(result.startIndex..., in: result), withTemplate: "")
        }
        // 移除自闭合标签：<location/>、<location></location>
        if let locRegex = try? NSRegularExpression(
            pattern: #"<location\s*/?>(\s*</location>)?"#,
            options: [.caseInsensitive]) {
            result = locRegex.stringByReplacingMatches(
                in: result, range: NSRange(result.startIndex..., in: result), withTemplate: "")
        }

        // 3. 移除 HTML/Markdown 图片语法残留（模型不遵循标签约定时的兜底清理）：
        //    <img ...>、![描述](目标)
        if let imgRegex = try? NSRegularExpression(
            pattern: #"<img\b[^>]*>"#,
            options: [.caseInsensitive]) {
            result = imgRegex.stringByReplacingMatches(
                in: result, range: NSRange(result.startIndex..., in: result), withTemplate: "")
        }
        if let mdImgRegex = try? NSRegularExpression(
            pattern: #"!\[([^\]]*)\]\(([^)]*)\)"#,
            options: [.caseInsensitive]) {
            result = mdImgRegex.stringByReplacingMatches(
                in: result, range: NSRange(result.startIndex..., in: result), withTemplate: "$1")
        }
        // 移除 <Image> / <picture> 等其它 XML 图片变体的成对标签
        if let xmlImgRegex = try? NSRegularExpression(
            pattern: #"</?(?:image|picture|img|photo|generate-image|image-generate)[^>]*>"#,
            options: [.caseInsensitive]) {
            result = xmlImgRegex.stringByReplacingMatches(
                in: result, range: NSRange(result.startIndex..., in: result), withTemplate: "")
        }
        return result.trimmingCharacters(in: .whitespacesAndNewlines)
    }
}
