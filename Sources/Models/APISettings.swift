import Foundation

/// 联网 API 设置（OpenAI 兼容）
struct APISettings: Codable {
    var apiURL: String
    var apiKey: String
    var modelName: String
    var engine: APIEngine       // 引擎选择
    var deepThinking: Bool      // 深度思考开关
    var ttsEnabled: Bool        // 语音合成自动播放

    init(apiURL: String = "",
         apiKey: String = "",
         modelName: String = "gpt-4o-mini",
         engine: APIEngine = .openAICompatible,
         deepThinking: Bool = false,
         ttsEnabled: Bool = false) {
        self.apiURL = apiURL
        self.apiKey = apiKey
        self.modelName = modelName
        self.engine = engine
        self.deepThinking = deepThinking
        self.ttsEnabled = ttsEnabled
    }

    var isConfigured: Bool {
        !apiURL.trimmingCharacters(in: .whitespaces).isEmpty &&
        !apiKey.trimmingCharacters(in: .whitespaces).isEmpty
    }
}

/// 联网引擎类型
enum APIEngine: String, Codable, CaseIterable {
    case openAICompatible = "OpenAI 兼容接口"
    case minimax = "MiniMax 文本生成"

    var endpoint: String {
        switch self {
        case .openAICompatible:
            return "/v1/chat/completions"
        case .minimax:
            // MiniMax Chat Completions 端点
            return "/v1/text/chatcompletion_v2"
        }
    }
}

/// 本地模型清单
enum LocalModelCatalog {
    static let models: [LocalModel] = [
        LocalModel(
            id: "qwen2.5-1.5b-instruct",
            name: "Qwen2.5-1.5B-Instruct",
            detail: "通义千问 2.5 指令微调 · 轻量快速",
            sizeText: "约 1.1 GB",
            downloadURL: "https://huggingface.co/Qwen/Qwen2.5-1.5B-Instruct-GGUF/resolve/main/qwen2.5-1.5b-instruct-q4_k_m.gguf",
            filename: "qwen2.5-1.5b-instruct-q4_k_m.gguf",
            contextLength: 4096
        ),
        LocalModel(
            id: "qwen3-2b",
            name: "Qwen3-2B",
            detail: "通义千问 3 · 更强推理能力",
            sizeText: "约 1.5 GB",
            downloadURL: "https://huggingface.co/Qwen/Qwen3-2B-GGUF/resolve/main/qwen3-2b-q4_k_m.gguf",
            filename: "qwen3-2b-q4_k_m.gguf",
            contextLength: 8192
        )
    ]

    static func find(id: String) -> LocalModel? {
        models.first { $0.id == id }
    }
}