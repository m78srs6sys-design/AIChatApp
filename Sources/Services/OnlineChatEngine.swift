import Foundation

/// OpenAI 兼容流式对话引擎
/// 通过标准 chat/completions 协议进行流式输出
final class OnlineChatEngine {
    private let session: URLSession

    init(session: URLSession = .shared) {
        self.session = session
    }

    /// 发起流式对话请求，逐 token 回调
    func streamChat(
        messages: [ChatMessage],
        settings: APISettings,
        onToken: @escaping (String) -> Void
    ) async throws {
        guard settings.isConfigured else {
            throw ChatError.notConfigured
        }

        let urlString = buildURL(settings: settings)
        guard let url = URL(string: urlString) else {
            throw ChatError.invalidURL
        }

        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.setValue("Bearer \(settings.apiKey)", forHTTPHeaderField: "Authorization")
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue("text/event-stream", forHTTPHeaderField: "Accept")

        let body = buildBody(messages: messages, settings: settings)
        request.httpBody = try JSONSerialization.data(withJSONObject: body)

        let (bytes, response) = try await session.bytes(for: request)
        guard let http = response as? HTTPURLResponse, (200..<300).contains(http.statusCode) else {
            throw ChatError.requestFailed
        }

        // 解析 SSE 流
        for try await line in bytes.lines {
            guard line.hasPrefix("data:") else { continue }
            let payload = line.dropFirst(5).trimmingCharacters(in: .whitespaces)
            if payload == "[DONE]" { break }
            guard let data = payload.data(using: .utf8),
                  let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                  let choices = json["choices"] as? [[String: Any]],
                  let delta = choices.first?["delta"] as? [String: Any],
                  let content = delta["content"] as? String else {
                continue
            }
            if !content.isEmpty {
                onToken(content)
            }
        }
    }

    // MARK: - Helpers
    private func buildURL(settings: APISettings) -> String {
        var base = settings.apiURL.trimmingCharacters(in: .whitespaces)
        if base.hasSuffix("/") { base.removeLast() }

        // 兼容用户填写的不同地址格式，避免路径重复拼接
        if base.hasSuffix("/chat/completions") {
            return base
        }
        if base.hasSuffix("/v1") {
            return base + "/chat/completions"
        }
        return base + "/v1/chat/completions"
    }

    private func buildBody(messages: [ChatMessage], settings: APISettings) -> [String: Any] {
        let history = messages.map { msg -> [String: String] in
            ["role": msg.role.rawValue, "content": msg.content]
        }

        var body: [String: Any] = [
            "model": settings.modelName,
            "messages": history,
            "stream": true,
            "temperature": 0.7,
            "max_tokens": 1024
        ]

        // 深度思考：开关打开时按用户选择的字段类型插入，关闭时不发送任何字段（避免多余字段导致 400）
        if settings.deepThinking {
            switch settings.deepThinkingField {
            case .thinkingEnabled:
                body["thinking_enabled"] = true
            case .reasoningEffort:
                body["reasoning_effort"] = "high"
            }
        }

        return body
    }
}

enum ChatError: LocalizedError {
    case notConfigured
    case invalidURL
    case requestFailed
    case noActiveModel
    case inferenceFailed(String)

    var errorDescription: String? {
        switch self {
        case .notConfigured: return "请先在设置中配置接口地址与密钥"
        case .invalidURL: return "接口地址格式不正确"
        case .requestFailed: return "请求失败，请检查网络或接口配置"
        case .noActiveModel: return "请先下载并选择本地模型"
        case .inferenceFailed(let msg): return "本地推理失败：\(msg)"
        }
    }
}