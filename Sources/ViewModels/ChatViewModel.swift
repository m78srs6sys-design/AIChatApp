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

    let store = ConversationStore.shared
    private let onlineEngine = OnlineChatEngine()
    private let localEngine = LocalInferenceEngine.shared
    private let skillService = OnlineSkillService.shared

    // MARK: - Mode (per conversation)
    func setMode(_ newMode: ChatMode) {
        store.mutateCurrent { $0.mode = newMode }
    }

    // MARK: - Clear
    func clearMessages() {
        store.mutateCurrent { $0.messages.removeAll() }
        errorMessage = nil
    }

    // MARK: - Delete
    func deleteMessage(_ message: ChatMessage) {
        store.mutateCurrent { $0.messages.removeAll { $0.id == message.id } }
    }

    // MARK: - Send
    func send(settings: APISettings, activeModel: LocalModel?) {
        let text = inputText.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty, !isGenerating else { return }
        guard store.currentId != nil else { return }

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

        // 技能触发检测
        let wantsImage = containsImageIntent(userText)
        let wantsSearch = containsSearchIntent(userText)
        let wantsLocation = containsLocationIntent(userText)
        let wantsWeather = containsWeatherIntent(userText)
        let wantsWebpage = containsWebpageIntent(userText)
        let pageURL = extractURL(userText)

        var attachments: [MessageAttachment] = []
        var extraContexts: [String] = []

        // 图片生成（Pollinations，免密钥）
        if wantsImage {
            do {
                let url = try await skillService.generateImage(prompt: userText)
                attachments.append(.image(url: url))
            } catch {
                errorMessage = "图片生成失败：\(error.localizedDescription)"
            }
        }

        // 网络搜索（维基百科，免密钥）
        if wantsSearch {
            if let results = try? await skillService.search(query: userText), !results.isEmpty {
                attachments.append(.searchResults(results))
                let ctx = results.prefix(3).map { "【\($0.title)】\($0.snippet ?? "")" }.joined(separator: "\n")
                extraContexts.append("以下是网络搜索结果，请参考并尽量注明来源后再作答：\n\(ctx)")
            }
        }

        // 天气（open-meteo，免密钥）
        if wantsWeather {
            if let w = try? await skillService.weather(from: userText) {
                attachments.append(.weather(w))
                extraContexts.append("当前\(w.city)天气：\(w.condition)，气温\(String(format: "%.0f", w.temperature))\(w.units)。")
            }
        }

        // 网页抓取与摘要（直连，免密钥）
        if wantsWebpage, let url = pageURL {
            if let page = try? await skillService.fetchWebpage(url: url) {
                attachments.append(.webpage(page))
                extraContexts.append("以下是网页内容（标题：\(page.title)），请基于它作答：\n\(page.summary)")
            }
        }

        // 定位
        if wantsLocation {
            LocationService.shared.requestLocation()
        }

        let aiId = appendAssistant(with: attachments)
        statusMessage = "正在生成回复…"

        do {
            var history = store.current?.messages.filter { $0.id != aiId } ?? []
            for ctx in extraContexts {
                history.append(ChatMessage(role: .user, content: ctx))
            }
            try await onlineEngine.streamChat(messages: history, settings: settings) { [weak self] token in
                guard let self else { return }
                self.appendToken(to: aiId, token: token)
            }
            finishAssistant(aiId)
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
            $0.messages.append(ChatMessage(role: .assistant, content: "", isStreaming: true,
                                           attachments: attachments, id: id))
        }
        return id
    }

    private func appendToken(to id: UUID, token: String) {
        store.mutateCurrent { conv in
            if let i = conv.messages.firstIndex(where: { $0.id == id }) {
                conv.messages[i].content += token
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

    // MARK: - Intent Detection
    private func containsImageIntent(_ text: String) -> Bool {
        let keywords = ["画一张", "画一个", "生成图片", "生成一张图", "画图", "AI画", "生成插画", "设计一张", "画个图"]
        return keywords.contains { text.contains($0) }
    }

    private func containsSearchIntent(_ text: String) -> Bool {
        let keywords = ["搜索", "查一下", "帮我查", "最新", "新闻", "今天", "实时", "搜一下", "百度", "谷歌", "资料"]
        return keywords.contains { text.contains($0) }
    }

    private func containsLocationIntent(_ text: String) -> Bool {
        let keywords = ["我的位置", "我在哪", "当前位置", "附近", "定位", "我在哪里"]
        return keywords.contains { text.contains($0) }
    }

    private func containsWeatherIntent(_ text: String) -> Bool {
        let keywords = ["天气", "气温", "温度", "下雨", "降雨", "weather", "多少度", "冷不冷", "热不热"]
        return keywords.contains { text.lowercased().contains($0.lowercased()) }
    }

    private func containsWebpageIntent(_ text: String) -> Bool {
        guard let url = extractURL(text) else { return false }
        let keywords = ["总结", "摘要", "概括", "分析", "翻译", "读一下", "读这", "summarize", "提炼", "要点", "这篇", "这个网页"]
        let onlyURL = text.trimmingCharacters(in: .whitespacesAndNewlines) == url
        return onlyURL || keywords.contains { text.contains($0) }
    }

    private func extractURL(_ text: String) -> String? {
        guard let detector = try? NSDataDetector(types: NSTextCheckingResult.CheckingType.link.rawValue) else { return nil }
        let matches = detector.matches(in: text, range: NSRange(text.startIndex..., in: text))
        return matches.first.flatMap { Range($0.range, in: text).map { String(text[$0]) } }
    }
}
