import Foundation
import llama

/// 本地离线推理引擎：封装 llama.cpp C API
/// 所有推理在设备本地完成，无需联网
final class LocalInferenceEngine {
    static let shared = LocalInferenceEngine()

    private var model: OpaquePointer?
    private var context: OpaquePointer?
    private var vocab: OpaquePointer?
    private var currentModelPath: String?
    private let queue = DispatchQueue(label: "aichat.local.inference")

    private init() {}

    /// 是否已加载模型
    var isModelLoaded: Bool { model != nil && context != nil }

    /// 加载模型文件
    func loadModel(at path: String, contextLength: Int) throws {
        try queue.sync {
            // 已加载相同模型则跳过
            if currentModelPath == path, model != nil { return }
            unload()

            var modelParams = llama_model_default_params()
            modelParams.n_gpu_layers = 0  // 纯 CPU 推理，保证兼容性

            guard let loadedModel = llama_model_load_from_file(path, modelParams) else {
                throw ChatError.inferenceFailed("模型文件加载失败")
            }
            self.model = loadedModel

            var ctxParams = llama_context_default_params()
            ctxParams.n_ctx = UInt32(contextLength)
            ctxParams.n_threads = UInt32(max(1, ProcessInfo.processInfo.activeProcessorCount - 1))
            ctxParams.n_threads_batch = ctxParams.n_threads

            guard let ctx = llama_init_from_model(loadedModel, ctxParams) else {
                throw ChatError.inferenceFailed("推理上下文初始化失败")
            }
            self.context = ctx
            self.vocab = llama_model_get_vocab(loadedModel)
            self.currentModelPath = path
        }
    }

    /// 卸载模型，释放内存
    func unload() {
        if let context { llama_free(context) }
        if let model { llama_model_free(model) }
        context = nil
        model = nil
        vocab = nil
        currentModelPath = nil
    }

    /// 本地流式推理，逐 token 回调
    func streamInfer(
        messages: [ChatMessage],
        onToken: @escaping (String) -> Void
    ) async throws {
        guard let context, let vocab, model != nil else {
            throw ChatError.noActiveModel
        }

        let prompt = buildPrompt(messages: messages)
        let promptBytes = Array(prompt.utf8)

        // 分词（两遍：先取所需长度，再填充）
        var tokenCapacity = max(64, promptBytes.count + 32)
        var tokens = [llama_token](repeating: 0, count: tokenCapacity)
        var n = llama_tokenize(vocab, promptBytes, Int32(promptBytes.count), &tokens, Int32(tokenCapacity), true, true)
        if n < 0 {
            tokenCapacity = Int(-n)
            tokens = [llama_token](repeating: 0, count: tokenCapacity)
            n = llama_tokenize(vocab, promptBytes, Int32(promptBytes.count), &tokens, Int32(tokenCapacity), true, true)
        }
        guard n > 0 else { throw ChatError.inferenceFailed("分词失败") }
        tokens = Array(tokens.prefix(Int(n)))

        // 解码 prompt
        var batch = llama_batch_get_one(tokens, Int32(tokens.count))
        if llama_decode(context, batch) != 0 {
            throw ChatError.inferenceFailed("prompt 解码失败")
        }

        // 采样链：min_p + temperature + 分布采样
        var sampler = llama_sampler_chain_init(llama_sampler_chain_default_params())
        llama_sampler_chain_add(sampler, llama_sampler_init_min_p(0.05, 1))
        llama_sampler_chain_add(sampler, llama_sampler_init_temp(0.7))
        llama_sampler_chain_add(sampler, llama_sampler_init_dist(1))
        defer { llama_sampler_free(sampler) }

        let maxTokens = 1024
        for _ in 0..<maxTokens {
            let newId = llama_sampler_sample(sampler, context, -1)
            if newId == llama_vocab_eos(vocab) { break }

            // 转回文本
            var buf = [CChar](repeating: 0, count: 64)
            let pieceLen = llama_token_to_piece(vocab, newId, &buf, Int32(buf.count), 0, true)
            if pieceLen > 0 {
                let piece = String(cString: buf)
                onToken(piece)
            }

            // 继续解码
            let single = [newId]
            batch = llama_batch_get_one(single, 1)
            if llama_decode(context, batch) != 0 { break }
        }
    }

    private func buildPrompt(messages: [ChatMessage]) -> String {
        var prompt = ""
        for msg in messages {
            switch msg.role {
            case .system:
                prompt += "<|im_start|>system\n\(msg.content)<|im_end|>\n"
            case .user:
                prompt += "<|im_start|>user\n\(msg.content)<|im_end|>\n"
            case .assistant:
                prompt += "<|im_start|>assistant\n\(msg.content)<|im_end|>\n"
            }
        }
        prompt += "<|im_start|>assistant\n"
        return prompt
    }
}
