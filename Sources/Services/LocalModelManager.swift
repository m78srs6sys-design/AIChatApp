import Foundation
import Combine
import UserNotifications

/// 本地模型下载管理：后台下载、断点续传、删除、进度通知、Live Activity。
/// 支持分片 GGUF（如 -00001-of-00002.gguf）：每个分片独立下载到同一目录，
/// llama.cpp 加载时会自动合并分片；模型「已下载」状态 = 所有分片均存在。
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
        rebuildDownloadStates()
        loadResumeData()
        requestNotificationPermission()
        restoreBackgroundTasks()
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
        }
        saveResumeData()
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
            self?.partExpected[key] = totalBytesExpectedToWrite > 0 ? totalBytesExpectedToWrite : totalBytesWritten
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
    static let apiBase = "https://hf-mirror.com/api/models"

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

    private struct HFSibling: Decodable {
        let rfilename: String
        let size: Int64?
    }

    private struct HFModel: Decodable {
        let siblings: [HFSibling]?
    }

    /// 拉取并解析模型列表
    static func fetchModels() async throws -> [LocalModel] {
        var result: [LocalModel] = []
        for item in repos {
            guard let url = URL(string: "\(apiBase)/\(item.repo)") else { continue }
            var request = URLRequest(url: url)
            request.timeoutInterval = 20
            let (data, response) = try await URLSession.shared.data(from: url)
            guard let http = response as? HTTPURLResponse, (200..<300).contains(http.statusCode) else {
                continue
            }
            guard let decoded = try? JSONDecoder().decode(HFModel.self, from: data),
                  let siblings = decoded.siblings else { continue }

            let ggufs = siblings.map(\.rfilename).filter { $0.hasSuffix(".gguf") }
            guard !ggufs.isEmpty else { continue }

            // 偏好量化：优先找 q4_k_m 的单文件；若 q4_k_m 是分片，选用分片方案
            let chosen = chooseFiles(ggufs: ggufs)
            guard let chosen else { continue }

            let model = makeModel(repo: item.repo, prefix: item.prefix, partNames: chosen)
            result.append(model)
        }
        return result
    }

    /// 从文件列表里挑出一组要下载的文件（单个 or 分片）
    private static func chooseFiles(ggufs: [String]) -> [String]? {
        // 非分片文件
        let single = ggufs.filter { !$0.contains("-of-") }
        for q in quantPrefs {
            // 1) 尝试该量化的单文件
            if let f = single.first(where: { $0.lowercased().contains(q) }) {
                return [f]
            }
            // 2) 尝试该量化的全部分片（-0000x-of-N）
            let parts = ggufs.filter { $0.lowercased().contains(q) && $0.contains("-of-") }
                .sorted()
            if !parts.isEmpty {
                return parts
            }
        }
        // 3) 兜底：任何一个单文件
        return single.first.map { [$0] }
    }

    private static func makeModel(repo: String, prefix: String, partNames: [String]) -> LocalModel {
        let quantText = (partNames.first ?? "").replacingOccurrences(of: prefix.lowercased() + "-instruct-", with: "")
        let name = partNames.count == 1 ? "\(prefix)（\(quantText)）" : "\(prefix)（\(quantText) · \(partNames.count) 分片）"
        let parts = partNames.map { fn in
            LocalModelPart(filename: fn, downloadURL: resolveURL(repo: repo, file: fn))
        }
        // 上下文长度按模型大小调整
        let ctx: Int
        if prefix.contains("0.5B") { ctx = 4096 }
        else if prefix.contains("1.5B") { ctx = 8192 }
        else { ctx = 8192 }
        let id = "remote-\(repo)-\(partNames.joined(separator: "+"))"
        return LocalModel(
            id: id,
            name: name,
            detail: "云端拉取：\(repo)",
            sizeText: "约 \(formatSize(partNames.count))",
            downloadURL: resolveURL(repo: repo, file: partNames[0]),
            filename: partNames[0],
            contextLength: ctx,
            parts: parts
        )
    }

    private static func resolveURL(repo: String, file: String) -> String {
        "https://hf-mirror.com/\(repo)/resolve/main/\(file)"
    }

    private static func formatSize(_ partCount: Int) -> String {
        switch partCount {
        case 1: return "单文件"
        case 2: return "2 个分片"
        case 3: return "3 个分片"
        case 4: return "4 个分片"
        default: return "\(partCount) 个分片"
        }
    }
}
