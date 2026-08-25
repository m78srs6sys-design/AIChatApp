import Foundation

/// 联网 API 设置（OpenAI 兼容）
struct APISettings: Codable {
    var apiURL: String
    var apiKey: String
    var modelName: String
    var engine: APIEngine            // 引擎选择
    var deepThinking: Bool           // 深度思考开关
    var deepThinkingField: DeepThinkingField  // 深度思考字段类型（兼容不同服务商）
    var onlineFeaturesEnabled: Bool  // 是否允许 AI 主动调用联网附加功能
    var modelWebSearch: Bool         // 模型自带联网搜索（enable_search，由服务端检索，不再本地拉取搜索 API）
    var ttsEnabled: Bool             // 语音合成自动播放
    var hapticPerChar: Bool          // 生成每个字震动一次
    var liquidGlassEnabled: Bool     // 液态玻璃界面（毛玻璃质感，默认关闭）
    var githubProxy: String          // GitHub release 下载代理前缀（留空直连），如 https://ghproxy.com/
    var workflows: [WorkflowPreset]  // 智能工具流程方案（可自定义）

    init(apiURL: String = "",
         apiKey: String = "",
         modelName: String = "gpt-4o-mini",
         engine: APIEngine = .openAICompatible,
         deepThinking: Bool = false,
         deepThinkingField: DeepThinkingField = .thinkingEnabled,
        onlineFeaturesEnabled: Bool = true,
        modelWebSearch: Bool = true,
        ttsEnabled: Bool = false,
        hapticPerChar: Bool = false,
        liquidGlassEnabled: Bool = false,
        githubProxy: String = "",
        workflows: [WorkflowPreset] = WorkflowPreset.builtins) {
        self.apiURL = apiURL
        self.apiKey = apiKey
        self.modelName = modelName
        self.engine = engine
        self.deepThinking = deepThinking
        self.deepThinkingField = deepThinkingField
        self.onlineFeaturesEnabled = onlineFeaturesEnabled
        self.modelWebSearch = modelWebSearch
        self.ttsEnabled = ttsEnabled
        self.hapticPerChar = hapticPerChar
        self.liquidGlassEnabled = liquidGlassEnabled
        self.githubProxy = githubProxy
        self.workflows = workflows
    }

    // 手写 Codable，保证旧版钥匙串数据（不含 workflows 字段）也能兼容解析、不会整体失败
    private enum CodingKeys: String, CodingKey {
        case apiURL, apiKey, modelName, engine, deepThinking, deepThinkingField
        case onlineFeaturesEnabled, modelWebSearch, ttsEnabled, hapticPerChar, liquidGlassEnabled, githubProxy, workflows
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        apiURL = try c.decodeIfPresent(String.self, forKey: .apiURL) ?? ""
        apiKey = try c.decodeIfPresent(String.self, forKey: .apiKey) ?? ""
        modelName = try c.decodeIfPresent(String.self, forKey: .modelName) ?? "gpt-4o-mini"
        engine = try c.decodeIfPresent(APIEngine.self, forKey: .engine) ?? .openAICompatible
        deepThinking = try c.decodeIfPresent(Bool.self, forKey: .deepThinking) ?? false
        deepThinkingField = try c.decodeIfPresent(DeepThinkingField.self, forKey: .deepThinkingField) ?? .thinkingEnabled
        onlineFeaturesEnabled = try c.decodeIfPresent(Bool.self, forKey: .onlineFeaturesEnabled) ?? true
        modelWebSearch = try c.decodeIfPresent(Bool.self, forKey: .modelWebSearch) ?? true
        ttsEnabled = try c.decodeIfPresent(Bool.self, forKey: .ttsEnabled) ?? false
        hapticPerChar = try c.decodeIfPresent(Bool.self, forKey: .hapticPerChar) ?? false
        liquidGlassEnabled = try c.decodeIfPresent(Bool.self, forKey: .liquidGlassEnabled) ?? false
        githubProxy = try c.decodeIfPresent(String.self, forKey: .githubProxy) ?? ""
        workflows = try c.decodeIfPresent([WorkflowPreset].self, forKey: .workflows) ?? WorkflowPreset.builtins
    }

    func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encode(apiURL, forKey: .apiURL)
        try c.encode(apiKey, forKey: .apiKey)
        try c.encode(modelName, forKey: .modelName)
        try c.encode(engine, forKey: .engine)
        try c.encode(deepThinking, forKey: .deepThinking)
        try c.encode(deepThinkingField, forKey: .deepThinkingField)
        try c.encode(onlineFeaturesEnabled, forKey: .onlineFeaturesEnabled)
        try c.encode(modelWebSearch, forKey: .modelWebSearch)
        try c.encode(ttsEnabled, forKey: .ttsEnabled)
        try c.encode(hapticPerChar, forKey: .hapticPerChar)
        try c.encode(liquidGlassEnabled, forKey: .liquidGlassEnabled)
        try c.encode(githubProxy, forKey: .githubProxy)
        try c.encode(workflows, forKey: .workflows)
    }

    var isConfigured: Bool {
        !apiURL.trimmingCharacters(in: .whitespaces).isEmpty &&
        !apiKey.trimmingCharacters(in: .whitespaces).isEmpty
    }
}

/// 深度思考字段类型（不同服务商字段名不同，避免硬写死导致 400）
enum DeepThinkingField: String, Codable, CaseIterable {
    case thinkingEnabled
    case reasoningEffort

    var displayName: String {
        switch self {
        case .thinkingEnabled: return "thinking_enabled（国产兼容）"
        case .reasoningEffort: return "reasoning_effort（OpenAI）"
        }
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
    case qwen3
    case glm
    case kimi

    var id: String { rawValue }

    var name: String {
        switch self {
        case .openAI: return "OpenAI"
        case .deepSeek: return "DeepSeek"
        case .qwen: return "通义千问 Qwen-Plus"
        case .qwen3: return "通义千问 Qwen3-8B"
        case .glm: return "智谱 GLM"
        case .kimi: return "Kimi (Moonshot)"
        }
    }

    var url: String {
        switch self {
        case .openAI: return "https://api.openai.com/v1"
        case .deepSeek: return "https://api.deepseek.com/v1"
        case .qwen: return "https://dashscope.aliyuncs.com/compatible-mode/v1"
        case .qwen3: return "https://dashscope.aliyuncs.com/compatible-mode/v1"
        case .glm: return "https://open.bigmodel.cn/api/paas/v4"
        case .kimi: return "https://api.moonshot.cn/v1"
        }
    }

    var model: String {
        switch self {
        case .openAI: return "gpt-4o-mini"
        case .deepSeek: return "deepseek-chat"
        case .qwen: return "qwen-plus"
        case .qwen3: return "qwen3-8b"
        case .glm: return "glm-4-flash"
        case .kimi: return "moonshot-v1-8k"
        }
    }
}

/// 本地模型清单（下载源：魔搭 ModelScope 国内 CDN，速度快；分片自动合并加载）
enum LocalModelCatalog {
    static let models: [LocalModel] = [
        LocalModel(
            id: "qwen2.5-1.5b-instruct",
            name: "Qwen2.5-1.5B-Instruct",
            detail: "通义千问 2.5 指令微调 · 轻量快速",
            sizeText: "约 1.04 GB",
            downloadURL: "https://modelscope.cn/models/Qwen/Qwen2.5-1.5B-Instruct-GGUF/resolve/master/qwen2.5-1.5b-instruct-q4_k_m.gguf",
            filename: "qwen2.5-1.5b-instruct-q4_k_m.gguf",
            contextLength: 4096,
            parts: [
                LocalModelPart(filename: "qwen2.5-1.5b-instruct-q4_k_m.gguf",
                               downloadURL: "https://modelscope.cn/models/Qwen/Qwen2.5-1.5B-Instruct-GGUF/resolve/master/qwen2.5-1.5b-instruct-q4_k_m.gguf",
                               size: 1117320736)
            ]
        ),
        LocalModel(
            id: "qwen2.5-7b-instruct",
            name: "Qwen2.5-7B-Instruct",
            detail: "通义千问 2.5 · 7B 更大更强（分片模型，自动合并）",
            sizeText: "约 4.36 GB",
            // 官方 GGUF 仓库中 q4_k_m 拆分为两个分片，须逐个下载后由 llama.cpp 自动合并
            downloadURL: "https://modelscope.cn/models/Qwen/Qwen2.5-7B-Instruct-GGUF/resolve/master/qwen2.5-7b-instruct-q4_k_m-00001-of-00002.gguf",
            filename: "qwen2.5-7b-instruct-q4_k_m-00001-of-00002.gguf",
            contextLength: 8192,
            parts: [
                LocalModelPart(
                    filename: "qwen2.5-7b-instruct-q4_k_m-00001-of-00002.gguf",
                    downloadURL: "https://modelscope.cn/models/Qwen/Qwen2.5-7B-Instruct-GGUF/resolve/master/qwen2.5-7b-instruct-q4_k_m-00001-of-00002.gguf",
                    size: 3993201344
                ),
                LocalModelPart(
                    filename: "qwen2.5-7b-instruct-q4_k_m-00002-of-00002.gguf",
                    downloadURL: "https://modelscope.cn/models/Qwen/Qwen2.5-7B-Instruct-GGUF/resolve/master/qwen2.5-7b-instruct-q4_k_m-00002-of-00002.gguf",
                    size: 689872288
                )
            ]
        )
    ]

    static func find(id: String) -> LocalModel? {
        models.first { $0.id == id }
    }
}

/// 工具种类（可在「智能工具流程」里像积木一样组合）
enum ToolKind: String, Codable, CaseIterable, Identifiable {
    case location
    case search
    case weather
    case web
    case image
    case system

    var id: String { rawValue }

    var displayName: String {
        switch self {
        case .location: return "定位"
        case .search:   return "搜索"
        case .weather:  return "天气"
        case .web:      return "网页"
        case .image:    return "图片"
        case .system:   return "系统"
        }
    }

    /// 该工具是否需要在标签内填写参数
    var needsParam: Bool {
        switch self {
        case .location: return false
        default:        return true
        }
    }

    /// 渲染成 AI 能识别的调用标签
    func tag(param: String) -> String {
        switch self {
        case .location: return "<location/>"
        case .search:   return "<search>\(param)</search>"
        case .weather:  return "<weather>\(param)</weather>"
        case .web:      return "<web>\(param)</web>"
        case .image:    return "<image>\(param)</image>"
        case .system:   return "<system>\(param)</system>"
        }
    }
}

/// 流程里的一个步骤
struct ToolStep: Codable, Identifiable, Hashable {
    var id: UUID
    var tool: ToolKind
    var param: String

    init(id: UUID = UUID(), tool: ToolKind, param: String = "") {
        self.id = id
        self.tool = tool
        self.param = param
    }
}

/// 一个「场景 → 工具处理流程」方案（可自定义、可内置）
struct WorkflowPreset: Codable, Identifiable, Hashable {
    var id: UUID
    var name: String
    var trigger: String
    var enabled: Bool
    var steps: [ToolStep]

    init(id: UUID = UUID(), name: String, trigger: String, enabled: Bool = true, steps: [ToolStep]) {
        self.id = id
        self.name = name
        self.trigger = trigger
        self.enabled = enabled
        self.steps = steps
    }

    static var empty: WorkflowPreset {
        WorkflowPreset(name: "新方案", trigger: "", steps: [ToolStep(tool: .search, param: "")])
    }

    /// 内置默认方案（用户可改、可删、可在此基础上新增）
    static var builtins: [WorkflowPreset] {
        [
            WorkflowPreset(
                name: "推荐景点",
                trigger: "用户想找当地 / 附近好玩的地方、旅游景点、周末去哪玩",
                steps: [ToolStep(tool: .location)]
            ),
            WorkflowPreset(
                name: "天气咨询",
                trigger: "询问天气、气温、是否下雨、穿衣 / 出行建议",
                steps: [ToolStep(tool: .location), ToolStep(tool: .weather, param: "我的位置")]
            ),
            WorkflowPreset(
                name: "周边美食",
                trigger: "想找附近 / 当地好吃的、餐厅推荐",
                steps: [ToolStep(tool: .location)]
            ),
            WorkflowPreset(
                name: "实时资讯",
                trigger: "询问最新新闻、时事、实时 / 最新信息（由模型内置联网搜索回答）",
                steps: []
            ),
            WorkflowPreset(
                name: "网页速览",
                trigger: "发来一个网址，想了解其内容",
                steps: [ToolStep(tool: .web, param: "用户消息中的网址")]
            ),
            WorkflowPreset(
                name: "画一张图",
                trigger: "想生成 / 画一张图片、插画、海报",
                steps: [ToolStep(tool: .image, param: "画面描述（建议英文）")]
            ),
            WorkflowPreset(
                name: "系统优化",
                trigger: "想调节设备、省电、优化体验",
                steps: [ToolStep(tool: .system, param: "brightness 0.7")]
            )
        ]
    }
}