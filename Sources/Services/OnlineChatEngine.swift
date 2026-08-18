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

        let bytes: URLSession.AsyncBytes
        let response: URLResponse
        do {
            (bytes, response) = try await session.bytes(for: request)
        } catch let urlError as URLError {
            throw ChatError.network(urlError.localizedDescription)
        }

        guard let http = response as? HTTPURLResponse else {
            throw ChatError.network("无法解析服务器响应")
        }
        guard (200..<300).contains(http.statusCode) else {
            // 读取错误响应体，给用户更明确的提示
            var errorData = Data()
            for try await byte in bytes {
                errorData.append(byte)
                if errorData.count > 2000 { break }
            }
            let errorBody = String(data: errorData, encoding: .utf8) ?? ""
            throw ChatError.http(status: http.statusCode, body: errorBody)
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
            "model": settings.modelName.trimmingCharacters(in: .whitespacesAndNewlines),
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
    case network(String)
    case http(status: Int, body: String)

    var errorDescription: String? {
        switch self {
        case .notConfigured: return "请先在设置中配置接口地址与密钥"
        case .invalidURL: return "接口地址格式不正确"
        case .requestFailed: return "请求失败，请检查网络或接口配置"
        case .noActiveModel: return "请先下载并选择本地模型"
        case .inferenceFailed(let msg): return "本地推理失败：\(msg)"
        case .network(let msg): return "网络错误：\(msg)"
        case .http(let status, let body):
            // 先尝试从服务器返回的 JSON 中识别具体错误码（百炼/OpenAI 通常用 code 字段）
            let lower = body.lowercased()
            let serverCode: String
            if let r = lower.range(of: "\"code\"\\s*:\\s*\"") {
                let after = lower[r.upperBound...]
                if let end = after.firstIndex(of: "\"") {
                    serverCode = String(after[after.startIndex..<end])
                } else {
                    serverCode = ""
                }
            } else {
                serverCode = ""
            }

            // 优先根据服务器错误码给具体提示
            let codeHint: String?
            switch serverCode {
            case "model_not_found": codeHint = "模型不存在：请到百炼控制台确认「模型名称」，应填部署对应的模型名（如 qwen-plus），而不是部署实例 ID（UUID）"
            case "invalid_api_key": codeHint = "API 密钥无效：在设置里检查「API 密钥」"
            case "insufficient_quota": codeHint = "账号额度不足"
            case "context_length_exceeded": codeHint = "上下文超出模型最大长度"
            case "rate_limit_exceeded": codeHint = "请求过于频繁"
            default: codeHint = nil
            }

            let hint: String
            if let ch = codeHint {
                hint = ch
            } else {
                switch status {
                case 400: hint = "参数错误（可能是模型名或深度思考字段不匹配）"
                case 401: hint = "API 密钥无效或未授权"
                case 403: hint = "无访问权限（检查 Key 是否有该接口权限）"
                case 404: hint = "接口路径或资源不存在（检查接口地址 / 模型名）"
                case 429: hint = "请求过于频繁或额度不足"
                default: hint = "服务器返回错误"
                }
            }
            let detail = body.isEmpty ? "" : " · \(body.prefix(300))"
            return "请求失败（HTTP \(status)）：\(hint)\(detail)"
        }
    }
}