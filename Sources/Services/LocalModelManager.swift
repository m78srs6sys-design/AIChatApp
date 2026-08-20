import Foundation
import Combine
import UserNotifications

/// 本地模型下载管理：后台下载、断点续传、删除、进度通知、Live Activity。
/// 支持分片 GGUF（如 -00001-of-00002.gguf）：每个分片独立下载到同一目录，
/// llama.cpp 加载时会自动合并分片；模型「已下载」状态 = 所有分片均存在。
final class LocalModelManager: NSObject, ObservableObject {
    static let modelsDir: URL = {
        let docs = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
        let dir = docs.appendingPathComponent("LocalModels", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
    }()

    @Published var downloads: [String: DownloadState] = [:]
    @Published var activeModelId: String?

    /// 任务表：key = "modelId||filename"（分片级粒度）
    private var tasks: [String: URLSessionDownloadTask] = [:]
    private var resumeData: [String: Data] = [:]
    /// 各分片已下载字节数缓存（用于聚合整体进度展示）
    private var partBytes: [String: Int64] = [:]

    /// 后台会话：切到后台 / 锁屏后下载仍会继续
    private lazy var session: URLSession = {
        let config = URLSessionConfiguration.background(withIdentifier: "com.aichat.app.model-download")
        config.sessionSendsLaunchEvents = true
        config.isDiscretionary = false
        config.allowsCellularAccess = true
        return URLSession(configuration: config, delegate: self, delegateQueue: nil)
    }()

    override init() {
        super.init()
        activeModelId = PersistenceManager.shared.loadActiveModelId()
        for model in LocalModelCatalog.models {
            if isDownloaded(model) {
                downloads[model.id] = DownloadState(downloaded: true, progress: 1.0, status: .completed)
            } else {
                downloads[model.id] = DownloadState(downloaded: false, progress: 0, status: .idle)
            }
        }
        loadResumeData()
        requestNotificationPermission()
        restoreBackgroundTasks()
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
                task = session.downloadTask(withResumeData: resume)
            } else {
                task = session.downloadTask(with: url)
            }
            task.taskDescription = fileKey
            tasks[fileKey] = task
            task.resume()
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
            guard let self, let model = LocalModelCatalog.find(id: modelId) else { return }
            var doneBytes: Int64 = 0
            var totalBytes: Int64 = 0
            for part in model.files {
                let fileKey = Self.taskKey(modelId: model.id, filename: part.filename)
                let p = self.partPath(for: part)
                if FileManager.default.fileExists(atPath: p.path) {
                    // 已完整落盘的分片：按实际大小计
                    let size = (try? FileManager.default.attributesOfItem(atPath: p.path)[.size] as? Int64) ?? 0
                    doneBytes += size
                    totalBytes += size
                } else if let w = self.partBytes[fileKey] {
                    // 正在下载的分片：按缓存字节计
                    doneBytes += w
                    totalBytes += w
                }
            }
            let progress = totalBytes > 0 ? Double(doneBytes) / Double(totalBytes) : 0
            self.downloads[modelId]?.progress = min(1.0, progress)
            if #available(iOS 16.1, *) {
                DownloadActivityManager.shared.update(modelId: modelId,
                                                       progress: self.downloads[modelId]?.progress ?? 0,
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
            guard let self, let model = LocalModelCatalog.find(id: modelId) else { return }
            self.resumeData[key] = nil
            self.saveResumeData()
            if self.isDownloaded(model) {
                self.downloads[modelId] = DownloadState(downloaded: true, progress: 1.0, status: .completed)
                if #available(iOS 16.1, *) {
                    DownloadActivityManager.shared.end(modelId: modelId)
                }
                self.notifyDownloadComplete(model: model)
            } else {
                // 还有分片未完成，保持下载中
                self.downloads[modelId]?.status = .downloading
                self.downloads[modelId]?.progress = min(0.99, self.downloads[modelId]?.progress ?? 0)
            }
        }
    }

    func urlSession(_ session: URLSession, task: URLSessionTask, didCompleteWithError error: Error?) {
        guard let downloadTask = task as? URLSessionDownloadTask,
              let key = downloadTask.taskDescription else { return }
        let parts = key.components(separatedBy: "||")
        guard parts.count == 2 else { return }
        let modelId = parts[0]

        guard let error = error else { return }

        let nsError = error as NSError
        if nsError.code == NSURLErrorCancelled {
            // 用户在 pause 中主动取消，已在 pauseDownload 里处理
            return
        }

        DispatchQueue.main.async { [weak self] in
            guard let self else { return }
            guard LocalModelCatalog.find(id: modelId) != nil else { return }
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
