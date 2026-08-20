import Foundation

/// OpenAI 兼容流式对话引擎
/// 通过标准 chat/completions 协议进行流式输出
final class OnlineChatEngine {
    /// 使用带超时的独立会话，避免 SSE 长连接挂起导致调用永久卡死
    private let session: URLSession = {
        let cfg = URLSessionConfiguration.default
        cfg.timeoutIntervalForRequest = 40
        cfg.timeoutIntervalForResource = 90
        cfg.httpAdditionalHeaders = ["Accept": "text/event-stream"]
        return URLSession(configuration: cfg)
    }()

    init() {}

    /// 发起流式对话请求，逐 token 回调
    /// - onToken: 正文内容增量
    /// - onReasoning: 深度思考过程（reasoning_content）增量，可能为空
    func streamChat(
        messages: [ChatMessage],
        settings: APISettings,
        onToken: @escaping (String) -> Void,
        onReasoning: ((String) -> Void)? = nil
    ) async throws {
        let apiURL = settings.apiURL.trimmingCharacters(in: .whitespacesAndNewlines)
        let apiKey = settings.apiKey.trimmingCharacters(in: .whitespacesAndNewlines)
        let model = settings.modelName.trimmingCharacters(in: .whitespacesAndNewlines)

        guard !apiURL.isEmpty && !apiKey.isEmpty else {
            throw ChatError.notConfigured
        }

        let urlString = Self.buildURL(from: apiURL)
        guard let url = URL(string: urlString) else {
            throw ChatError.invalidURL
        }

        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.setValue("Bearer \(apiKey)", forHTTPHeaderField: "Authorization")
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue("text/event-stream", forHTTPHeaderField: "Accept")

        let body = Self.buildBody(messages: messages, model: model, settings: settings)
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
            var errorData = Data()
            for try await byte in bytes {
                errorData.append(byte)
                if errorData.count > 3000 { break }
            }
            let errorBody = String(data: errorData, encoding: .utf8) ?? ""
            throw ChatError.http(status: http.statusCode, body: errorBody, url: urlString, model: model)
        }

        // 解析 SSE 流
        for try await line in bytes.lines {
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            guard trimmed.hasPrefix("data:") else { continue }
            let payload = trimmed.dropFirst(5).trimmingCharacters(in: .whitespaces)
            if payload == "[DONE]" { break }
            guard let data = payload.data(using: .utf8),
                  let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                  let choices = json["choices"] as? [[String: Any]],
                  let delta = choices.first?["delta"] as? [String: Any] else {
                continue
            }
            // 深度思考过程（兼容 DeepSeek 的 reasoning_content 与部分服务商的 reasoning）
            if let reasoning = (delta["reasoning_content"] as? String) ?? (delta["reasoning"] as? String),
               !reasoning.isEmpty {
                await MainActor.run { onReasoning?(reasoning) }
            }
            guard let content = delta["content"] as? String else { continue }
            if !content.isEmpty {
                await MainActor.run { onToken(content) }
            }
        }
    }

    // MARK: - URL 拼接（健壮版）

    /// 把用户填写的接口地址拼成完整的 chat/completions 地址。
    /// 兼容：域名、域名/v1、域名/compatible-mode/v1、完整 chat/completions 地址。
    static func buildURL(from raw: String) -> String {
        var base = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        while base.hasSuffix("/") { base.removeLast() }

        if base.hasSuffix("/chat/completions") {
            return base
        }
        if base.hasSuffix("/v1") {
            return base + "/chat/completions"
        }
        return base + "/v1/chat/completions"
    }

    // MARK: - 请求体

    static func buildBody(messages: [ChatMessage], model: String, settings: APISettings) -> [String: Any] {
        let history = messages.map { msg -> [String: String] in
            ["role": msg.role.rawValue, "content": msg.content]
        }

        var body: [String: Any] = [
            "model": model,
            "messages": history,
            "stream": true,
            "temperature": 0.7,
            "max_tokens": 2048
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
    case http(status: Int, body: String, url: String, model: String)

    var errorDescription: String? {
        switch self {
        case .notConfigured: return "请先在设置中配置接口地址与密钥"
        case .invalidURL: return "接口地址格式不正确"
        case .requestFailed: return "请求失败，请检查网络或接口配置"
        case .noActiveModel: return "请先下载并选择本地模型"
        case .inferenceFailed(let msg): return "本地推理失败：\(msg)"
        case .network(let msg): return "网络错误：\(msg)"
        case .http(let status, let body, let url, let model):
            let serverCode = Self.extractServerCode(from: body)
            let hint = Self.hint(status: status, code: serverCode, url: url)

            let detail = body.isEmpty ? "" : " · \(body.prefix(300))"
            return "请求失败（HTTP \(status)）：\(hint)\(detail)\n请求地址：\(url)\n模型名：\(model)"
        }
    }

    private static func extractServerCode(from body: String) -> String {
        let lower = body.lowercased()
        guard let r = lower.range(of: "\"code\"\\s*:\\s*\"") else { return "" }
        let after = lower[r.upperBound...]
        guard let end = after.firstIndex(of: "\"") else { return "" }
        return String(after[after.startIndex..<end])
    }

    private static func hint(status: Int, code: String, url: String) -> String {
        let isDedicated = url.contains("maas.aliyuncs.com")

        switch code {
        case "model_not_found":
            if isDedicated {
                return "模型不存在：这是百炼「专属部署」端点，model 应填该部署的模型 ID（去百炼控制台「模型部署」列表复制，通常形如 qwen3-8b-ft-xxx，不是 qwen-plus）"
            }
            return "模型不存在：请检查设置中的「模型名称」是否正确、是否带多余空格"
        case "invalid_api_key":
            return "API 密钥无效：请检查设置中的「API 密钥」"
        case "insufficient_quota":
            return "账号额度不足"
        case "context_length_exceeded":
            return "上下文超出模型最大长度"
        case "rate_limit_exceeded":
            return "请求过于频繁"
        default:
            break
        }

        switch status {
        case 400: return "参数错误（可能是模型名或深度思考字段不匹配）"
        case 401: return "API 密钥无效或未授权"
        case 403: return "无访问权限（检查 Key 是否有该接口权限）"
        case 404: return "接口路径或资源不存在（检查接口地址 / 模型名）"
        case 429: return "请求过于频繁或额度不足"
        default: return "服务器返回错误"
        }
    }
}
