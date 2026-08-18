import Foundation
import Combine
import SwiftUI

@MainActor
final class ChatViewModel: ObservableObject {
    @Published var messages: [ChatMessage] = []
    @Published var mode: ChatMode = .online
    @Published var inputText: String = ""
    @Published var isGenerating: Bool = false
    @Published var errorMessage: String?
    @Published var statusMessage: String?
    @Published var currentAudioURL: String?
    @Published var isPlayingAudio: Bool = false

    private let onlineEngine = OnlineChatEngine()
    private let localEngine = LocalInferenceEngine.shared
    private let skillService = OnlineSkillService.shared
    private var cancellables = Set<AnyCancellable>()

    init() {
        messages = PersistenceManager.shared.loadMessages()
        mode = PersistenceManager.shared.loadMode()
    }

    // MARK: - Mode Switch
    func switchMode(to newMode: ChatMode) {
        guard newMode != mode else { return }
        mode = newMode
        PersistenceManager.shared.saveMode(mode)
    }

    // MARK: - Clear
    func clearMessages() {
        messages.removeAll()
        PersistenceManager.shared.clearMessages()
        errorMessage = nil
    }

    // MARK: - Delete
    func deleteMessage(_ message: ChatMessage) {
        messages.removeAll { $0.id == message.id }
        persist()
    }

    // MARK: - Send
    func send(settings: APISettings, activeModel: LocalModel?) {
        let text = inputText.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else { return }
        guard !isGenerating else { return }

        errorMessage = nil
        statusMessage = mode == .online ? "正在连接…" : "正在准备本地推理…"
        isGenerating = true
        let userMsg = ChatMessage(role: .user, content: text)
        messages.append(userMsg)
        inputText = ""
        persist()

        switch mode {
        case .online:
            Task { await runOnline(userText: text, settings: settings) }
        case .offline:
            Task { await runOffline(activeModel: activeModel) }
        }
    }

    // MARK: - Online Flow
    private func runOnline(userText: String, settings: APISettings) async {
        defer {
            isGenerating = false
            statusMessage = nil
        }
        guard settings.isConfigured else {
            errorMessage = ChatError.notConfigured.errorDescription
            return
        }

        // 检测技能触发（搜索 / 图片生成 / 定位）
        let lower = userText.lowercased()
        let wantsImage = containsImageIntent(userText)
        let wantsSearch = containsSearchIntent(userText)
        let wantsLocation = containsLocationIntent(userText)

        var attachments: [MessageAttachment] = []

        // 图片生成
        if wantsImage {
            do {
                let url = try await skillService.generateImage(prompt: userText)
                attachments.append(.image(url: url))
            } catch {
                // 静默降级，继续文本对话
            }
        }

        // 搜索
        if wantsSearch {
            do {
                let results = try await skillService.search(query: userText)
                if !results.isEmpty {
                    attachments.append(.searchResults(results))
                }
            } catch {}
        }

        // 定位
        if wantsLocation {
            LocationService.shared.requestLocation()
        }

        let aiMsg = ChatMessage(role: .assistant, content: "", isStreaming: true, attachments: attachments)
        messages.append(aiMsg)
        persist()
        statusMessage = "正在生成回复…"

        do {
            try await onlineEngine.streamChat(messages: messages.filter { !$0.isStreaming },
                                              settings: settings) { [weak self] token in
                guard let self else { return }
                if let idx = self.messages.lastIndex(where: { $0.id == aiMsg.id }) {
                    self.messages[idx].content += token
                }
            }
            // 完成流式
            if let idx = messages.lastIndex(where: { $0.id == aiMsg.id }) {
                messages[idx].isStreaming = false
            }
            persist()

            // 自动语音合成
            if settings.ttsEnabled, let last = messages.last(where: { $0.role == .assistant }) {
                await synthesizeAndPlay(text: last.content)
            }
        } catch {
            errorMessage = error.localizedDescription
            if let idx = messages.lastIndex(where: { $0.id == aiMsg.id }) {
                if messages[idx].content.isEmpty {
                    messages[idx].content = "（请求失败，请重试）"
                }
                messages[idx].isStreaming = false
            }
            persist()
        }
    }

    // MARK: - Offline Flow
    private func runOffline(activeModel: LocalModel?) async {
        defer {
            isGenerating = false
            statusMessage = nil
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

        let aiMsg = ChatMessage(role: .assistant, content: "", isStreaming: true)
        messages.append(aiMsg)
        persist()
        statusMessage = "正在生成回复…"

        do {
            try await localEngine.streamInfer(messages: messages.filter { $0.id != aiMsg.id }) { [weak self] token in
                guard let self else { return }
                if let idx = self.messages.lastIndex(where: { $0.id == aiMsg.id }) {
                    self.messages[idx].content += token
                }
            }
            if let idx = messages.lastIndex(where: { $0.id == aiMsg.id }) {
                messages[idx].isStreaming = false
            }
            persist()
        } catch {
            errorMessage = error.localizedDescription
            if let idx = messages.lastIndex(where: { $0.id == aiMsg.id }) {
                messages[idx].content = "（推理失败：\(error.localizedDescription)）"
                messages[idx].isStreaming = false
            }
            persist()
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
        guard !messages.isEmpty else { throw ChatError.notConfigured }
        return try PDFExporter.export(messages: messages)
    }

    // MARK: - Persistence
    private func persist() {
        PersistenceManager.shared.saveMessages(messages)
    }

    // MARK: - Intent Detection
    private func containsImageIntent(_ text: String) -> Bool {
        let keywords = ["画一张", "画一个", "生成图片", "生成一张图", "画图", "AI画", "生成插画", "设计一张"]
        return keywords.contains { text.contains($0) }
    }

    private func containsSearchIntent(_ text: String) -> Bool {
        let keywords = ["搜索", "查一下", "帮我查", "最新", "新闻", "今天", "实时", "搜一下", "百度"]
        return keywords.contains { text.contains($0) }
    }

    private func containsLocationIntent(_ text: String) -> Bool {
        let keywords = ["我的位置", "我在哪", "当前位置", "附近", "定位", "我在哪里"]
        return keywords.contains { text.contains($0) }
    }
}