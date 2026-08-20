import Foundation
import Darwin
import llama

/// 本地离线推理引擎：封装 llama.cpp C API
/// 所有推理在设备本地完成，无需联网
///
/// 深度性能优化点：
/// 1. Metal GPU 加速：优先把全部层 offload 到 GPU（Apple Silicon），失败自动回退纯 CPU；
/// 2. token 聚合：生成循环在后台线程跑，攒够 30ms / 64 字符才切回主线程批量刷新，避免每 token
///    一次跨线程切换 + SwiftUI 刷新，UI 打字机效果流畅不卡；
/// 3. 占用率上报：每 2 秒采样 CPU / 内存占用，驱动锁屏「实时活动」显示占用率；
/// 4. 采样链复用 + 随机 seed + byte-safe token 解码。
final class LocalInferenceEngine {
    static let shared = LocalInferenceEngine()

    private var model: OpaquePointer?
    private var context: OpaquePointer?
    private var vocab: OpaquePointer?
    private var currentModelPath: String?
    /// 本次运行是否成功启用了 GPU（Metal）加速
    private(set) var usingGPU = false
    /// 后台推理串行队列：加载/推理都在此执行，避免与 UI 线程竞争
    private let queue = DispatchQueue(label: "aichat.local.inference", qos: .userInitiated)

    private init() {}

    /// 是否已加载模型
    var isModelLoaded: Bool { model != nil && context != nil }

    // MARK: - Load / Unload

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

        // Metal GPU 后端初始化（llama.cpp b3xxx+ 需要显式调用）
        llama_backend_init()

        // 第一遍：尝试 GPU 全量 offload
        var modelParams = llama_model_default_params()
        modelParams.n_gpu_layers = 999  // 超出的层数会自动按剩余全部层处理

        var loadedModel = llama_model_load_from_file(path, modelParams)
        if loadedModel == nil {
            // GPU 不可用/显存不足 → 自动回退纯 CPU，保证一定能跑
            modelParams.n_gpu_layers = 0
            loadedModel = llama_model_load_from_file(path, modelParams)
        }
        guard let loadedModel else {
            throw ChatError.inferenceFailed("模型文件加载失败")
        }
        self.model = loadedModel
        self.usingGPU = modelParams.n_gpu_layers > 0

        var ctxParams = llama_context_default_params()
        ctxParams.n_ctx = UInt32(contextLength)
        // 线程数：GPU 卸载后 CPU 只做采样/剩余层，2~6 足够，避免线程风暴和 UI 抢核
        let cores = ProcessInfo.processInfo.activeProcessorCount
        ctxParams.n_threads = Int32(min(6, max(2, cores)))
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

    // MARK: - Stream Inference

    /// 本地流式推理。
    /// - Parameters:
    ///   - onToken: 文本块回调（**主线程**，聚合后批量回调，每块可能包含多个 token）
    ///   - onUsage: 占用率回调（**主线程**，约每 2 秒一次），参数为 (cpu%, mem%)
    func streamInfer(
        messages: [ChatMessage],
        onToken: @escaping (String) -> Void,
        onUsage: ((Double, Double) -> Void)? = nil
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

        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
            queue.async {
                do {
                    try self.runInferenceLoop(tokens: tokens, context: context, vocab: vocab,
                                              onToken: onToken, onUsage: onUsage)
                    continuation.resume()
                } catch {
                    continuation.resume(throwing: error)
                }
            }
        }
    }

    /// 后台推理主循环（整段都在本地推理队列执行，绝不触碰主线程）
    private func runInferenceLoop(tokens: [llama_token],
                                  context: OpaquePointer,
                                  vocab: OpaquePointer,
                                  onToken: @escaping (String) -> Void,
                                  onUsage: ((Double, Double) -> Void)?) throws {
        // 解码 prompt
        if decode(tokens: tokens, context: context) != 0 {
            throw ChatError.inferenceFailed("prompt 解码失败")
        }

        // 采样链：min_p + temperature + 随机分布采样（复用同一链条，创建一次）
        let sampler = llama_sampler_chain_init(llama_sampler_chain_default_params())
        llama_sampler_chain_add(sampler, llama_sampler_init_min_p(0.05, 1))
        llama_sampler_chain_add(sampler, llama_sampler_init_temp(0.7))
        llama_sampler_chain_add(sampler, llama_sampler_init_dist(UInt32.random(in: 1...UInt32.max)))
        defer { llama_sampler_free(sampler) }

        let maxTokens = 1024
        // token → 字节缓冲（llama 的 piece 是 UTF-8 字节，可能跨 token 分块）
        var buf = [CChar](repeating: 0, count: 128)
        // 单 token 解码复用数组，避免每 token 分配
        var singleToken = [llama_token](repeating: 0, count: 1)

        // ---- 聚合状态 ----
        var pending = ""                         // 攒在手里的文本（后台队列独占）
        var lastFlush = DispatchTime.now()       // 上次刷新主线程的时间
        var lastUsage = DispatchTime.now()       // 上次上报占用率的时间
        let flushInterval = 30_000_000           // 30ms：约 33 次/秒，打字机自然
        let flushCharThreshold = 64              // 或攒够 64 字符立即刷
        let usageInterval = 2_000_000_000        // 每 2 秒上报一次占用率

        for _ in 0..<maxTokens {
            let newId = llama_sampler_sample(sampler, context, -1)
            if newId == llama_vocab_eos(vocab) { break }

            // 转回文本（字节安全：用 UTF8 解码而非 cString，防止多字节边界截断乱码）
            let pieceLen = llama_token_to_piece(vocab, newId, &buf, Int32(buf.count), 0, true)
            if pieceLen > 0 {
                let bytes = buf[0..<Int(pieceLen)].map { UInt8(bitPattern: $0) }
                pending += String(decoding: bytes, as: UTF8.self)
            }

            // 继续解码
            singleToken[0] = newId
            if decode(token: &singleToken, context: context) != 0 { break }

            let now = DispatchTime.now()
            // 满足阈值 → 一次批量刷新到主线程
            if pending.count >= flushCharThreshold ||
                now.uptimeNanoseconds - lastFlush.uptimeNanoseconds > flushInterval {
                let chunk = pending
                pending = ""
                lastFlush = now
                if !chunk.isEmpty {
                    DispatchQueue.main.async { onToken(chunk) }
                }
            }
            // 每 2 秒上报一次 CPU/内存占用率
            if let onUsage,
               now.uptimeNanoseconds - lastUsage.uptimeNanoseconds > usageInterval {
                lastUsage = now
                let usage = SystemUsage.snapshot()
                DispatchQueue.main.async { onUsage(usage.cpu, usage.memory) }
            }
        }

        // 收尾：刷新剩余 token
        if !pending.isEmpty {
            let remainder = pending
            pending = ""
            DispatchQueue.main.async { onToken(remainder) }
        }
    }

    // MARK: - Internal

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
    private func decode(tokens: [llama_token], context: OpaquePointer) -> Int32 {
        var localTokens = tokens
        let count = localTokens.count
        var rc: Int32 = 0
        localTokens.withUnsafeMutableBufferPointer { buf in
            let batch = llama_batch_get_one(buf.baseAddress, Int32(count))
            rc = llama_decode(context, batch)
        }
        return rc
    }

    /// 解码单个（新）token
    private func decode(token: inout [llama_token], context: OpaquePointer) -> Int32 {
        var rc: Int32 = 0
        token.withUnsafeMutableBufferPointer { buf in
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

/// 系统资源占用采样（CPU 占用率 + 本 App 内存占用率）
enum SystemUsage {
    struct Snapshot {
        let cpu: Double     // 0~100
        let memory: Double  // 0~100
    }

    /// 采样一次（轻量，几微秒；thread-safe，可任意线程调用）
    static func snapshot() -> Snapshot {
        Snapshot(cpu: cpuPercent(), memory: memoryPercent())
    }

    /// 整机 CPU 占用率（0~100）
    private static func cpuPercent() -> Double {
        var ticks = host_cpu_load_info_data_t()
        var count = mach_msg_type_number_t(MemoryLayout<host_cpu_load_info_data_t>.size / MemoryLayout<integer_t>.size)
        let result = withUnsafeMutablePointer(to: &ticks) {
            $0.withMemoryRebound(to: integer_t.self, capacity: Int(count)) {
                host_statistics(mach_host_self(), HOST_CPU_LOAD_INFO, $0, &count)
            }
        }
        guard result == KERN_SUCCESS else { return 0 }
        // 顺序固定：USER, SYSTEM, IDLE, NICE
        let user = Double(ticks.cpu_ticks.0)
        let system = Double(ticks.cpu_ticks.1)
        let idle = Double(ticks.cpu_ticks.2)
        let nice = Double(ticks.cpu_ticks.3)
        let total = user + system + idle + nice
        guard total > 0 else { return 0 }
        return min(100, max(0, (user + system + nice) / total * 100))
    }

    /// 本 App 物理内存占用率（0~100）：LLM 推理期间最能反映「吃到多少内存」
    private static func memoryPercent() -> Double {
        var info = task_vm_info_data_t()
        var count = mach_msg_type_number_t(MemoryLayout<task_vm_info_data_t>.size / MemoryLayout<integer_t>.size)
        let result = withUnsafeMutablePointer(to: &info) {
            $0.withMemoryRebound(to: integer_t.self, capacity: Int(count)) {
                task_info(mach_task_self_, task_flavor_t(TASK_VM_INFO), $0, &count)
            }
        }
        let footprint = result == KERN_SUCCESS ? Int64(info.phys_footprint) : 0
        let total = Int64(ProcessInfo.processInfo.physicalMemory)
        guard total > 0, footprint > 0 else { return 0 }
        return min(100, Double(footprint) / Double(total) * 100)
    }
}