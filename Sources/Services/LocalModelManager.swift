import Foundation
import Combine
import UserNotifications
import CryptoKit

/// 本地模型下载管理：后台下载、断点续传、删除、进度通知、Live Activity。
/// 支持分片 GGUF（如 -00001-of-00002.gguf）：每个分片独立下载到同一目录，
/// llama.cpp 加载时会自动合并分片；模型「已下载」状态 = 所有分片均存在。
///
/// 完整性校验：每个分片下载完成后计算 SHA256 存入本地；打开「模型管理」页时
/// 自动重算对比，发现损坏（半截文件/被篡改）立即删除并显示为「未下载」。
final class LocalModelManager: NSObject, ObservableObject {
    static let shared = LocalModelManager()

    static let modelsDir: URL = {
        let docs = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
        let dir = docs.appendingPathComponent("LocalModels", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
    }()

    @Published var downloads: [String: DownloadState] = [:]
    @Published var activeModelId: String?
    /// 云端拉取到的模型列表（在「本地模型管理」中可选择、可下载）
    @Published var remoteModels: [LocalModel] = []
    /// 云端列表拉取状态
    @Published var isRefreshingRemote = false
    @Published var remoteLoadError: String?
    /// 完整性校验状态
    @Published var isVerifying = false
    @Published var verificationMessage: String?

    /// 文件 SHA256 基准（key = 文件名，value = 下载完成时计算的哈希，用于完整性校验）
    private var fileHashes: [String: String] = [:]

    /// 由系统保存的后台下载完成回调（App 从后台唤醒时调用它，防止后台任务一直挂起）
    private var backgroundCompletion: (() -> Void)?
    /// 记录当前后台 session 标识，AppDelegate 透传
    private(set) var backgroundIdentifier = "com.aichat.app.model-download"

    /// 任务表：key = "modelId||filename"（分片级粒度）
    private var tasks: [String: URLSessionDownloadTask] = [:]
    private var resumeData: [String: Data] = [:]
    /// 各分片已下载字节数缓存（用于聚合整体进度展示）
    private var partBytes: [String: Int64] = [:]
    /// 各分片预估总字节数（从服务器 Content-Length 获取，用于完整进度计算）
    private var partExpected: [String: Int64] = [:]

    /// 后台会话：切到后台 / 锁屏后下载仍会继续
    private lazy var session: URLSession = {
        let config = URLSessionConfiguration.background(withIdentifier: backgroundIdentifier)
        config.sessionSendsLaunchEvents = true
        config.isDiscretionary = false
        config.allowsCellularAccess = true
        config.waitsForConnectivity = true
        config.timeoutIntervalForRequest = 600
        config.timeoutIntervalForResource = 86400
        return URLSession(configuration: config, delegate: self, delegateQueue: nil)
    }()

    override init() {
        super.init()
        activeModelId = PersistenceManager.shared.loadActiveModelId()
        loadFileHashes()
        rebuildDownloadStates()
        loadResumeData()
        requestNotificationPermission()
        restoreBackgroundTasks()
    }

    // MARK: - 文件哈希（完整性校验）

    private static let fileHashesKey = "local_model_file_hashes"

    private func loadFileHashes() {
        if let data = UserDefaults.standard.data(forKey: Self.fileHashesKey),
           let dict = try? JSONDecoder().decode([String: String].self, from: data) {
            fileHashes = dict
        }
    }

    private func saveFileHashes() {
        if let data = try? JSONEncoder().encode(fileHashes) {
            UserDefaults.standard.set(data, forKey: Self.fileHashesKey)
        }
    }

    /// 计算文件 SHA256（流式读取，内存占用恒定；耗时随文件大小，适合后台）
    static func sha256(of url: URL, chunkSize: Int = 1 << 20) -> String? {
        guard let handle = try? FileHandle(forReadingFrom: url) else { return nil }
        defer { try? handle.close() }
        var hasher = SHA256()
        while true {
            let data = handle.readData(ofLength: chunkSize)
            if data.isEmpty { break }
            hasher.update(data: data)
        }
        return hasher.finalize().map { String(format: "%02x", $0) }.joined()
    }

    /// 校验所有已下载模型的完整性；发现损坏文件立即删除并显示「未下载」。
    /// 旧版本下载的文件没有哈希基准 → 首次校验时建立基准（视为完好）。
    func verifyAllModels() async {
        guard !isVerifying else { return }
        isVerifying = true
        verificationMessage = nil
        defer { isVerifying = false }

        var all = LocalModelCatalog.models
        for m in remoteModels where !all.contains(where: { $0.id == m.id }) {
            all.append(m)
        }

        var removedCount = 0
        var firstRunCount = 0

        for model in all where isDownloaded(model) {
            for part in model.files {
                let url = partPath(for: part)
                guard FileManager.default.fileExists(atPath: url.path) else { continue }
                let computed = await Task.detached(priority: .utility) {
                    Self.sha256(of: url)
                }.value
                guard let computed else { continue }

                // 主队列里做删除/存哈希；结果用返回值带出，避免并发闭包捕获修改
                let r = await MainActor.run { () -> (removed: Bool, firstRun: Bool) in
                    if let stored = fileHashes[part.filename] {
                        if stored != computed {
                            // 文件损坏：删除该分片 + 清断点，模型将显示「未下载」
                            try? FileManager.default.removeItem(at: url)
                            downloadAuthoritativeState(for: model.id)
                            return (true, false)
                        }
                        return (false, false)
                    }
                    // 首次建立基准
                    fileHashes[part.filename] = computed
                    saveFileHashes()
                    return (false, true)
                }
                if r.removed { removedCount += 1 } else if r.firstRun { firstRunCount += 1 }
            }
        }

        // 统计：损坏文件影响到的模型数量（重新扫一遍状态）
        let firstRuns = firstRunCount
        let modelsToScan = all
        let msg = await MainActor.run { () -> String in
            var resetModels = 0
            for model in modelsToScan {
                if !isDownloaded(model) {
                    if let prev = downloads[model.id], prev.status == .completed {
                        resetModels += 1
                    }
                    downloads[model.id] = DownloadState(downloaded: false, progress: 0, status: .idle)
                }
            }
            if resetModels > 0 {
                return "⚠️ 发现 \(resetModels) 个模型文件损坏，已自动删除，请重新下载"
            } else if firstRuns > 0 {
                return "✅ 模型完整性检查完成（为新下载文件建立了校验基准）"
            }
            return "✅ 模型完整性检查通过"
        }
        verificationMessage = msg
    }

    /// 去掉该模型的所有已下载状态（清除哈希与缓存）
    private func downloadAuthoritativeState(for modelId: String) {
        downloads[modelId] = DownloadState(downloaded: false, progress: 0, status: .idle)
        for key in tasks.keys where key.hasPrefix(modelId + "||") {
            resumeData[key] = nil
            tasks[key]?.cancel()
            tasks[key] = nil
        }
    }

    // MARK: - 状态同步

    /// 让 downloads 字典与内置模型 + 已拉取的云端模型保持一致
    func rebuildDownloadStates() {
        var all = LocalModelCatalog.models
        for m in remoteModels where !all.contains(where: { $0.id == m.id }) {
            all.append(m)
        }
        for model in all {
            if downloads[model.id] == nil {
                if isDownloaded(model) {
                    downloads[model.id] = DownloadState(downloaded: true, progress: 1.0, status: .completed)
                } else {
                    downloads[model.id] = DownloadState(downloaded: false, progress: 0, status: .idle)
                }
            }
        }
    }

    private func ensureState(for model: LocalModel) {
        if downloads[model.id] == nil {
            downloads[model.id] = isDownloaded(model)
                ? DownloadState(downloaded: true, progress: 1.0, status: .completed)
                : DownloadState(downloaded: false, progress: 0, status: .idle)
        }
    }

    // MARK: - 后台事件回调（必须在 AppDelegate 中调用）

    /// 由 App 入口调用：系统后台下载完成/恢复事件
    func handleBackgroundEvents(identifier: String, completion: @escaping () -> Void) {
        let isOurSession = identifier.hasPrefix("com.aichat.app.model-download")
        if isOurSession {
            // 让 URLSession 继续回调。存住 completion 供完成后调用。
            backgroundCompletion = completion
            session.getTasksWithCompletionHandler { [weak self] _, _, downloadTasks in
                if downloadTasks.isEmpty {
                    // 无活动任务，直接放行
                    DispatchQueue.main.async {
                        self?.backgroundCompletion?()
                        self?.backgroundCompletion = nil
                    }
                } else {
                    // 有任务继续执行，任务全部结束后再调 completion
                    self?.restoreBackgroundTasks()
                }
            }
        } else {
            completion()
        }
    }

    /// 任务全部结束后调用，通知系统后台处理完成
    private func finishBackgroundIfIdle() {
        session.getTasksWithCompletionHandler { [weak self] _, _, downloadTasks in
            DispatchQueue.main.async {
                guard let self else { return }
                if downloadTasks.isEmpty {
                    self.backgroundCompletion?()
                    self.backgroundCompletion = nil
                }
            }
        }
    }

    // MARK: - Path Helpers

    /// 分片文件在本地磁盘的目标路径
    private func partPath(for part: LocalModelPart) -> URL {
        LocalModelManager.modelsDir.appendingPathComponent(part.filename)
    }

    /// 模型入口文件路径（分片模型返回第一个分片，llama.cpp 会自动合并加载）
    func path(for model: LocalModel) -> URL {
        if let first = model.files.first {
            return partPath(for: first)
        }
        return LocalModelManager.modelsDir.appendingPathComponent(model.filename)
    }

    func isDownloaded(_ model: LocalModel) -> Bool {
        model.files.allSatisfy { FileManager.default.fileExists(atPath: partPath(for: $0).path) }
    }

    // MARK: - Download Control
    func startDownload(_ model: LocalModel) {
        ensureState(for: model)
        guard downloads[model.id]?.status != .downloading else { return }

        let allReady = model.files.allSatisfy { FileManager.default.fileExists(atPath: partPath(for: $0).path) }
        if allReady {
            downloads[model.id] = DownloadState(downloaded: true, progress: 1.0, status: .completed)
            return
        }

        downloads[model.id]?.status = .downloading
        downloads[model.id]?.error = nil

        // 为每个分片启动独立下载任务
        for part in model.files {
            let fileKey = Self.taskKey(modelId: model.id, filename: part.filename)
            if FileManager.default.fileExists(atPath: partPath(for: part).path) {
                // 该分片已存在（如断点续传后），标记完成
                continue
            }
            // 预填已知大小（ModelScope API 精确返回），下载一开始就能显示大小和估算进度
            if let s = part.size, s > 0 {
                partExpected[fileKey] = s
            }
            guard let url = URL(string: part.downloadURL) else { continue }

            let task: URLSessionDownloadTask
            if let resume = resumeData[fileKey] {
                let attempt = session.downloadTask(withResumeData: resume)
                attempt.taskDescription = fileKey
                tasks[fileKey] = attempt
                attempt.resume()
            } else {
                task = session.downloadTask(with: url)
                task.taskDescription = fileKey
                tasks[fileKey] = task
                task.resume()
            }
        }

        if #available(iOS 16.1, *) {
            DownloadActivityManager.shared.start(modelName: model.name, modelId: model.id)
        }
    }

    func pauseDownload(_ model: LocalModel) {
        for part in model.files {
            let fileKey = Self.taskKey(modelId: model.id, filename: part.filename)
            guard let task = tasks[fileKey] else { continue }
            task.cancel { [weak self] data in
                if let data {
                    self?.resumeData[fileKey] = data
                    self?.saveResumeData()
                }
            }
            tasks[fileKey] = nil
        }
        downloads[model.id]?.status = .paused
        if #available(iOS 16.1, *) {
            DownloadActivityManager.shared.end(modelId: model.id)
        }
    }

    func deleteModel(_ model: LocalModel) {
        pauseDownload(model)
        for part in model.files {
            let fileKey = Self.taskKey(modelId: model.id, filename: part.filename)
            try? FileManager.default.removeItem(at: partPath(for: part))
            resumeData[fileKey] = nil
            fileHashes[part.filename] = nil
        }
        saveResumeData()
        saveFileHashes()
        downloads[model.id] = DownloadState(downloaded: false, progress: 0, status: .idle)
        if activeModelId == model.id {
            activeModelId = nil
            PersistenceManager.shared.saveActiveModelId(nil)
        }
        if #available(iOS 16.1, *) {
            DownloadActivityManager.shared.end(modelId: model.id)
        }
    }

    func setActive(_ model: LocalModel) {
        activeModelId = model.id
        PersistenceManager.shared.saveActiveModelId(model.id)
    }

    // MARK: - Task Key
    private static func taskKey(modelId: String, filename: String) -> String {
        "\(modelId)||\(filename)"
    }

    // MARK: - Resume Data Persistence
    private func saveResumeData() {
        let dict = resumeData.mapValues { $0.base64EncodedString() }
        if let data = try? JSONEncoder().encode(dict) {
            UserDefaults.standard.set(data, forKey: "modelDownloadResumeData")
        }
    }

    private func loadResumeData() {
        guard let data = UserDefaults.standard.data(forKey: "modelDownloadResumeData"),
              let dict = try? JSONDecoder().decode([String: String].self, from: data) else { return }
        resumeData = dict.compactMapValues { Data(base64Encoded: $0) }
    }

    private func restoreBackgroundTasks() {
        session.getTasksWithCompletionHandler { [weak self] _, _, downloadTasks in
            for task in downloadTasks {
                guard let key = task.taskDescription else { continue }
                let parts = key.components(separatedBy: "||")
                guard parts.count == 2 else { continue }
                let modelId = parts[0]
                DispatchQueue.main.async {
                    self?.tasks[key] = task
                    if self?.downloads[modelId]?.status != .completed {
                        self?.downloads[modelId]?.status = .downloading
                    }
                }
            }
        }
    }

    // MARK: - 远程模型列表拉取（hf-mirror API，供用户选择更多模型）

    func refreshRemoteCatalog() async {
        await MainActor.run { isRefreshingRemote = true; remoteLoadError = nil }
        do {
            let list = try await ModelRemoteFetcher.fetchModels()
            await MainActor.run {
                remoteModels = list
                rebuildDownloadStates()
                isRefreshingRemote = false
            }
        } catch {
            await MainActor.run {
                remoteLoadError = "拉取失败：\(error.localizedDescription)（可稍后重试，或继续使用内置模型）"
                isRefreshingRemote = false
            }
        }
    }

    // MARK: - Notifications
    private func requestNotificationPermission() {
        UNUserNotificationCenter.current().requestAuthorization(options: [.alert, .sound, .badge]) { _, _ in }
    }

    private func notifyDownloadComplete(model: LocalModel) {
        let content = UNMutableNotificationContent()
        content.title = "模型下载完成"
        content.body = "\(model.name) 已下载完成，可切换到离线模式使用"
        content.sound = .default
        let request = UNNotificationRequest(identifier: "model-\(model.id)", content: content, trigger: nil)
        UNUserNotificationCenter.current().add(request)
    }
}

// MARK: - URLSessionDownloadDelegate
extension LocalModelManager: URLSessionDownloadDelegate {
    func urlSession(_ session: URLSession,
                    downloadTask: URLSessionDownloadTask,
                    didWriteData bytesWritten: Int64,
                    totalBytesWritten: Int64,
                    totalBytesExpectedToWrite: Int64) {
        guard let key = downloadTask.taskDescription else { return }
        let parts = key.components(separatedBy: "||")
        guard parts.count == 2 else { return }
        let modelId = parts[0]

        // 缓存当前分片字节数，供整体进度聚合（统一在主队列读写，避免竞态）
        DispatchQueue.main.async { [weak self] in
            self?.partBytes[key] = totalBytesWritten
            // 服务器返回了真实总大小 → 覆盖；返回 0（chunked）→ 保留预填的 part.size
            if totalBytesExpectedToWrite > 0 {
                self?.partExpected[key] = totalBytesExpectedToWrite
            }
            guard let self, let model = LocalModelCatalog.find(id: modelId)
                ?? self.remoteModels.first(where: { $0.id == modelId }) else { return }
            var doneBytes: Int64 = 0
            var totalBytes: Int64 = 0
            for part in model.files {
                let fileKey = Self.taskKey(modelId: model.id, filename: part.filename)
                let p = self.partPath(for: part)
                let onDiskSize = (try? FileManager.default.attributesOfItem(atPath: p.path)[.size] as? Int64) ?? 0
                let written = self.partBytes[fileKey] ?? 0
                let expected = self.partExpected[fileKey] ?? 0
                if FileManager.default.fileExists(atPath: p.path) {
                    // 已完整落盘的分片：按实际大小计
                    doneBytes += max(onDiskSize, written)
                    totalBytes += max(onDiskSize, expected)
                } else if expected > 0 {
                    // 正在下载且已拿到总大小：按比例计
                    doneBytes += written
                    totalBytes += expected
                } else {
                    // 未拿到大小信息：仅按已写字节计（此时比例≈1，等大小信息到达后恢复准确）
                    doneBytes += written
                    totalBytes += written
                }
            }
            let progress = totalBytes > 0 ? Double(doneBytes) / Double(totalBytes) : 0
            let capped = min(0.999, max(0, progress))
            self.downloads[modelId]?.progress = capped
            if #available(iOS 16.1, *) {
                DownloadActivityManager.shared.update(modelId: modelId,
                                                       progress: capped,
                                                       downloadedBytes: doneBytes,
                                                       totalBytes: totalBytes)
            }
        }
    }

    func urlSession(_ session: URLSession,
                    downloadTask: URLSessionDownloadTask,
                    didFinishDownloadingTo location: URL) {
        guard let key = downloadTask.taskDescription else { return }
        let parts = key.components(separatedBy: "||")
        guard parts.count == 2 else { return }
        let modelId = parts[0]
        let filename = parts[1]

        let dest = LocalModelManager.modelsDir.appendingPathComponent(filename)
        try? FileManager.default.removeItem(at: dest)
        do {
            try FileManager.default.moveItem(at: location, to: dest)
        } catch {
            DispatchQueue.main.async { [weak self] in
                self?.downloads[modelId]?.status = .failed
                self?.downloads[modelId]?.error = error.localizedDescription
            }
            return
        }

        DispatchQueue.main.async { [weak self] in
            guard let self, let model = LocalModelCatalog.find(id: modelId)
                ?? self.remoteModels.first(where: { $0.id == modelId }) else { return }
            self.resumeData[key] = nil
            self.saveResumeData()
            self.partBytes[key] = nil
            self.partExpected[key] = nil
            self.tasks[key] = nil
            if self.isDownloaded(model) {
                self.downloads[modelId] = DownloadState(downloaded: true, progress: 1.0, status: .completed)
                if #available(iOS 16.1, *) {
                    DownloadActivityManager.shared.end(modelId: modelId)
                }
                self.notifyDownloadComplete(model: model)
                self.finishBackgroundIfIdle()
                // 后台计算该分片 SHA256 作为完整性基准（大文件需几秒，不阻塞 UI）
                Task.detached(priority: .utility) { [weak self] in
                    guard let self, let hash = Self.sha256(of: dest) else { return }
                    DispatchQueue.main.async {
                        self.fileHashes[filename] = hash
                        self.saveFileHashes()
                    }
                }
            } else {
                // 还有分片未完成，保持下载中
                self.downloads[modelId]?.status = .downloading
                self.downloads[modelId]?.progress = min(0.999, self.downloads[modelId]?.progress ?? 0)
            }
        }
    }

    func urlSession(_ session: URLSession, task: URLSessionTask, didCompleteWithError error: Error?) {
        guard let downloadTask = task as? URLSessionDownloadTask,
              let key = downloadTask.taskDescription else { return }
        let parts = key.components(separatedBy: "||")
        guard parts.count == 2 else { return }
        let modelId = parts[0]

        guard let error = error else {
            // 无错误：正常完成（didFinishDownloadingTo 已处理）
            DispatchQueue.main.async { [weak self] in
                self?.tasks[key] = nil
                self?.finishBackgroundIfIdle()
            }
            return
        }

        let nsError = error as NSError
        if nsError.code == NSURLErrorCancelled {
            // 用户在 pause 中主动取消，已在 pauseDownload 里处理
            return
        }

        DispatchQueue.main.async { [weak self] in
            guard let self else { return }
            self.tasks[key] = nil
            guard LocalModelCatalog.find(id: modelId) != nil
                || self.remoteModels.contains(where: { $0.id == modelId }) else {
                self.finishBackgroundIfIdle()
                return
            }
            // 尝试从错误中恢复断点数据
            if let data = nsError.userInfo[NSURLSessionDownloadTaskResumeData] as? Data {
                self.resumeData[key] = data
                self.saveResumeData()
                self.downloads[modelId]?.status = .failed
                self.downloads[modelId]?.error = "下载中断，可点击「继续」重试"
            } else {
                self.downloads[modelId]?.status = .failed
                self.downloads[modelId]?.error = error.localizedDescription
            }
            if #available(iOS 16.1, *) {
                DownloadActivityManager.shared.end(modelId: modelId)
            }
            self.finishBackgroundIfIdle()
        }
    }
}

struct DownloadState {
    var downloaded: Bool
    var progress: Double
    var status: DownloadStatus
    var error: String?

    enum DownloadStatus: String {
        case idle = "未下载"
        case downloading = "下载中"
        case paused = "已暂停"
        case completed = "已下载"
        case failed = "失败"
    }
}

// MARK: - 远程模型列表（从 hf-mirror 拉取 Qwen2.5 GGUF 全系，用户可自选）

/// 从 HuggingFace 镜像 API 拉取可用的中文 GGUF 模型清单。
/// 只保留「单文件一次性下载」的模型（如 0.5B/1.5B/3B 的 q4_k_m），
/// 分片模型（7B/14B 等）也会展示，但下载逻辑（分片自动合并）保持不变。
enum ModelRemoteFetcher {
    // 主源：魔搭 ModelScope（国内 CDN，速度快，API 返回文件精确大小）
    static let msApiBase = "https://modelscope.cn/api/v1/models"
    static let msFileBase = "https://modelscope.cn/models"
    // 备用源：HuggingFace 国内镜像（ModelScope 失败时兜底）
    static let hfApiBase = "https://hf-mirror.com/api/models"
    static let hfFileBase = "https://hf-mirror.com"

    /// 候选模型仓库（作者/仓库名 → 显示名前缀）
    private static let repos: [(repo: String, prefix: String)] = [
        ("Qwen/Qwen2.5-0.5B-Instruct-GGUF", "Qwen2.5-0.5B"),
        ("Qwen/Qwen2.5-1.5B-Instruct-GGUF", "Qwen2.5-1.5B"),
        ("Qwen/Qwen2.5-3B-Instruct-GGUF", "Qwen2.5-3B"),
        ("Qwen/Qwen2.5-7B-Instruct-GGUF", "Qwen2.5-7B"),
        ("Qwen/Qwen2.5-14B-Instruct-GGUF", "Qwen2.5-14B"),
    ]

    /// 每个仓库挑选的量化（优先 q4_k_m，其次 q4_0，再次 q5_0）
    private static let quantPrefs = ["q4_k_m", "q4_0", "q5_0", "q8_0"]

    enum FetchError: LocalizedError {
        case invalidURL(String)
        case badResponse
        case decodeFailed
        var errorDescription: String? {
            switch self {
            case .invalidURL(let u): return "列表地址无效：\(u)"
            case .badResponse: return "服务器响应异常"
            case .decodeFailed: return "模型列表解析失败"
            }
        }
    }

    /// 通用的「文件名 + 大小」条目
    private struct FileEntry {
        let name: String
        let size: Int64?
    }

    // MARK: - ModelScope 响应模型
    private struct MSFile: Decodable {
        let Name: String?
        let Path: String?
        let Size: Int64?
    }
    private struct MSData: Decodable { let Files: [MSFile]? }
    private struct MSResponse: Decodable { let Data: MSData? }

    // MARK: - HuggingFace 响应模型
    private struct HFSibling: Decodable {
        let rfilename: String
        let size: Int64?
    }
    private struct HFModel: Decodable {
        let siblings: [HFSibling]?
    }

    /// 使用哪个下载源（影响列表 API 和下载 URL）
    private struct SourceInfo {
        let listURL: String
        let fileURL: URL
        let isModelScope: Bool
    }

    /// 拉取并解析模型列表
    static func fetchModels() async throws -> [LocalModel] {
        var result: [LocalModel] = []
        for item in repos {
            // 1) 优先拉 ModelScope 文件列表（带精确大小）
            var entries: [FileEntry]? = nil
            var fromMS = true
            do {
                entries = try await fetchEntriesFromModelScope(repo: item.repo)
            } catch {
                // 2) ModelScope 失败 → 兜底 hf-mirror
                fromMS = false
                entries = try? await fetchEntriesFromHF(repo: item.repo)
            }
            guard let entries = entries, !entries.isEmpty else { continue }

            let ggufs = entries
            guard !ggufs.isEmpty else { continue }

            // 偏好量化：优先找 q4_k_m 的单文件；若 q4_k_m 是分片，选用分片方案
            let chosen = chooseFiles(entries: ggufs)
            guard let chosen else { continue }

            let model = makeModel(repo: item.repo, prefix: item.prefix,
                                  parts: chosen, fromModelScope: fromMS)
            result.append(model)
        }
        return result
    }

    /// ModelScope：GET /api/v1/models/{repo}/repo/files?Revision=master&Recursive=true
    private static func fetchEntriesFromModelScope(repo: String) async throws -> [FileEntry] {
        guard let url = URL(string: "\(msApiBase)/\(repo)/repo/files?Revision=master&Recursive=true") else {
            throw FetchError.invalidURL(repo)
        }
        var request = URLRequest(url: url)
        request.timeoutInterval = 20
        let (data, response) = try await URLSession.shared.data(for: request)
        guard let http = response as? HTTPURLResponse, (200..<300).contains(http.statusCode) else {
            throw FetchError.badResponse
        }
        let decoded = try JSONDecoder().decode(MSResponse.self, from: data)
        let files = decoded.Data?.Files ?? []
        return files.compactMap { f -> FileEntry? in
            let name = f.Name ?? f.Path ?? ""
            guard name.hasSuffix(".gguf") else { return nil }
            return FileEntry(name: name, size: f.Size)
        }
    }

    /// hf-mirror：GET /api/models/{repo}
    private static func fetchEntriesFromHF(repo: String) async throws -> [FileEntry] {
        guard let url = URL(string: "\(hfApiBase)/\(repo)") else {
            throw FetchError.invalidURL(repo)
        }
        var request = URLRequest(url: url)
        request.timeoutInterval = 20
        let (data, response) = try await URLSession.shared.data(for: request)
        guard let http = response as? HTTPURLResponse, (200..<300).contains(http.statusCode) else {
            throw FetchError.badResponse
        }
        let decoded = try JSONDecoder().decode(HFModel.self, from: data)
        return (decoded.siblings ?? [])
            .filter { $0.rfilename.hasSuffix(".gguf") }
            .map { FileEntry(name: $0.rfilename, size: $0.size) }
    }

    /// 从文件列表里挑出一组要下载的文件（单个 or 分片）
    private static func chooseFiles(entries: [FileEntry]) -> [FileEntry]? {
        let names = entries.map(\.name)
        // 非分片文件
        let single = entries.filter { !$0.name.contains("-of-") }
        for q in quantPrefs {
            // 1) 尝试该量化的单文件
            if let f = single.first(where: { $0.name.lowercased().contains(q) }) {
                return [f]
            }
            // 2) 尝试该量化的全部分片（-0000x-of-N）
            let parts = entries
                .filter { $0.name.lowercased().contains(q) && $0.name.contains("-of-") }
                .sorted { $0.name < $1.name }
            if !parts.isEmpty {
                return parts
            }
        }
        // 3) 兜底：任何一个单文件
        return single.first.map { [$0] }
    }

    private static func makeModel(repo: String, prefix: String,
                                  parts: [FileEntry], fromModelScope: Bool) -> LocalModel {
        guard let first = parts.first else { return LocalModel(
            id: "remote-\(repo)", name: prefix, detail: "云端拉取：\(repo)",
            sizeText: "未知", downloadURL: "", filename: "",
            contextLength: 8192, parts: []) }
        let quantText = first.name
            .replacingOccurrences(of: prefix.lowercased() + "-instruct-", with: "")
        let name = parts.count == 1 ? "\(prefix)（\(quantText)）" : "\(prefix)（\(quantText) · \(parts.count) 分片）"

        let totalBytes = parts.compactMap(\.size).reduce(0, +)
        let sizeText: String
        if totalBytes > 0 {
            sizeText = "约 \(Self.prettyGB(totalBytes))"
        } else {
            sizeText = parts.count == 1 ? "单文件" : "\(parts.count) 个分片"
        }

        let modelParts = parts.map { entry in
            LocalModelPart(filename: entry.name,
                           downloadURL: resolveURL(repo: repo, file: entry.name, fromModelScope: fromModelScope),
                           size: entry.size)
        }
        // 上下文长度按模型大小调整
        let ctx: Int
        if prefix.contains("0.5B") { ctx = 4096 }
        else if prefix.contains("1.5B") { ctx = 8192 }
        else if prefix.contains("3B") { ctx = 8192 }
        else { ctx = 8192 }
        let id = "remote-\(repo)-\(parts.map(\.name).joined(separator: "+"))"
        return LocalModel(
            id: id,
            name: name,
            detail: "云端拉取：\(repo)",
            sizeText: sizeText,
            downloadURL: modelParts[0].downloadURL,
            filename: modelParts[0].filename,
            contextLength: ctx,
            parts: modelParts
        )
    }

    /// 统一的下载地址：ModelScope 走 resolve（302 → 国内 CDN）；hf-mirror 直连
    private static func resolveURL(repo: String, file: String, fromModelScope: Bool) -> String {
        if fromModelScope {
            return "\(msFileBase)/\(repo)/resolve/master/\(file)"
        }
        return "\(hfFileBase)/\(repo)/resolve/main/\(file)"
    }

    /// 字节数 → 人类可读大小（GB，保留 2 位小数的"约"）
    static func prettyGB(_ bytes: Int64) -> String {
        let gb = Double(bytes) / 1024.0 / 1024.0 / 1024.0
        if gb >= 1 {
            return String(format: "%.2f GB", gb)
        }
        let mb = Double(bytes) / 1024.0 / 1024.0
        return String(format: "%.0f MB", mb)
    }
}
