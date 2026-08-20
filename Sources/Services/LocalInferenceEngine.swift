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

    /// 加载模型文件（异步，在后台线程执行，不阻塞主线程/UI）
    func loadModel(at path: String, contextLength: Int) async throws {
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
            queue.async {
                do {
                    try self.loadModelSync(at: path, contextLength: contextLength)
                    continuation.resume()
                } catch {
                    continuation.resume(throwing: error)
                }
            }
        }
    }

    private func loadModelSync(at path: String, contextLength: Int) throws {
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
        ctxParams.n_threads = Int32(max(1, ProcessInfo.processInfo.activeProcessorCount - 1))
        ctxParams.n_threads_batch = ctxParams.n_threads

        guard let ctx = llama_init_from_model(loadedModel, ctxParams) else {
            throw ChatError.inferenceFailed("推理上下文初始化失败")
        }
        self.context = ctx
        self.vocab = llama_model_get_vocab(loadedModel)
        self.currentModelPath = path
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

    /// 本地流式推理，逐 token 回调（onToken 保证在主线程回调）
    func streamInfer(
        messages: [ChatMessage],
        onToken: @escaping (String) -> Void
    ) async throws {
        guard let context, let vocab, model != nil else {
            throw ChatError.noActiveModel
        }

        let prompt = buildPrompt(messages: messages)
        var tokens = try tokenize(prompt: prompt, vocab: vocab)

        // 防止历史过长导致解码失败：将 prompt 截断到上下文窗口内（保留最近内容）
        let nCtx = Int(llama_n_ctx(context))
        if tokens.count > nCtx - 64 {
            tokens = Array(tokens.suffix(nCtx - 64))
        }

        // 解码 prompt
        if decodePrompt(tokens: tokens, context: context) != 0 {
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
                await MainActor.run { onToken(piece) }
            }

            // 继续解码
            if decodeSingleToken(newId, context: context) != 0 { break }
        }
    }

    /// 分词：一次分配足够缓冲（token 数不会超过字节数），避免多次原地访问
    private func tokenize(prompt: String, vocab: OpaquePointer) throws -> [llama_token] {
        let promptBytes = Array(prompt.utf8).map { CChar(bitPattern: $0) }
        let capacity = promptBytes.count + 64
        var tokens = [llama_token](repeating: 0, count: capacity)
        let n = tokens.withUnsafeMutableBufferPointer { buf in
            llama_tokenize(vocab, promptBytes, Int32(promptBytes.count), buf.baseAddress, Int32(capacity), true, true)
        }
        guard n > 0 else { throw ChatError.inferenceFailed("分词失败") }
        return Array(tokens.prefix(Int(n)))
    }

    /// 解码整段 prompt tokens
    private func decodePrompt(tokens: [llama_token], context: OpaquePointer) -> Int32 {
        var localTokens = tokens
        let count = localTokens.count
        var rc: Int32 = 0
        localTokens.withUnsafeMutableBufferPointer { buf in
            let batch = llama_batch_get_one(buf.baseAddress, Int32(count))
            rc = llama_decode(context, batch)
        }
        return rc
    }

    /// 解码单个 token
    private func decodeSingleToken(_ token: llama_token, context: OpaquePointer) -> Int32 {
        var single = [token]
        var rc: Int32 = 0
        single.withUnsafeMutableBufferPointer { buf in
            let batch = llama_batch_get_one(buf.baseAddress, 1)
            rc = llama_decode(context, batch)
        }
        return rc
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
