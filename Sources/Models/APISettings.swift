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

/// 联网引擎类型（仅保留 OpenAI 兼容接口）
enum APIEngine: String, Codable, CaseIterable {
    case openAICompatible = "OpenAI 兼容接口"

    var endpoint: String {
        "/v1/chat/completions"
    }
}

/// 常见 API 预设，方便一键填入（均为 OpenAI 兼容接口）
enum APIPreset: String, CaseIterable, Identifiable {
    case openAI
    case deepSeek
    case qwen
    case glm
    case kimi

    var id: String { rawValue }

    var name: String {
        switch self {
        case .openAI: return "OpenAI"
        case .deepSeek: return "DeepSeek"
        case .qwen: return "通义千问"
        case .glm: return "智谱 GLM"
        case .kimi: return "Kimi (Moonshot)"
        }
    }

    var url: String {
        switch self {
        case .openAI: return "https://api.openai.com/v1"
        case .deepSeek: return "https://api.deepseek.com/v1"
        case .qwen: return "https://dashscope.aliyuncs.com/compatible-mode/v1"
        case .glm: return "https://open.bigmodel.cn/api/paas/v4"
        case .kimi: return "https://api.moonshot.cn/v1"
        }
    }

    var model: String {
        switch self {
        case .openAI: return "gpt-4o-mini"
        case .deepSeek: return "deepseek-chat"
        case .qwen: return "qwen-plus"
        case .glm: return "glm-4-flash"
        case .kimi: return "moonshot-v1-8k"
        }
    }
}

/// 本地模型清单（下载源使用国内可访问的 HuggingFace 镜像 hf-mirror.com）
enum LocalModelCatalog {
    static let models: [LocalModel] = [
        LocalModel(
            id: "qwen2.5-1.5b-instruct",
            name: "Qwen2.5-1.5B-Instruct",
            detail: "通义千问 2.5 指令微调 · 轻量快速",
            sizeText: "约 1.1 GB",
            downloadURL: "https://hf-mirror.com/Qwen/Qwen2.5-1.5B-Instruct-GGUF/resolve/main/qwen2.5-1.5b-instruct-q4_k_m.gguf",
            filename: "qwen2.5-1.5b-instruct-q4_k_m.gguf",
            contextLength: 4096
        ),
        LocalModel(
            id: "qwen3-2b",
            name: "Qwen3-2B",
            detail: "通义千问 3 · 更强推理能力",
            sizeText: "约 1.5 GB",
            downloadURL: "https://hf-mirror.com/Qwen/Qwen3-2B-GGUF/resolve/main/qwen3-2b-q4_k_m.gguf",
            filename: "qwen3-2b-q4_k_m.gguf",
            contextLength: 8192
        )
    ]

    static func find(id: String) -> LocalModel? {
        models.first { $0.id == id }
    }
}