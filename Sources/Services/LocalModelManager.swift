import Foundation
import Combine
import UserNotifications

/// 本地模型下载管理：后台下载、断点续传、删除、进度通知、Live Activity
final class LocalModelManager: NSObject, ObservableObject {
    static let modelsDir: URL = {
        let docs = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
        let dir = docs.appendingPathComponent("LocalModels", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
    }()

    @Published var downloads: [String: DownloadState] = [:]
    @Published var activeModelId: String?

    private var tasks: [String: URLSessionDownloadTask] = [:]
    private var resumeData: [String: Data] = [:]

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

    func isDownloaded(_ model: LocalModel) -> Bool {
        FileManager.default.fileExists(atPath: path(for: model).path)
    }

    func path(for model: LocalModel) -> URL {
        LocalModelManager.modelsDir.appendingPathComponent(model.filename)
    }

    // MARK: - Download Control
    func startDownload(_ model: LocalModel) {
        guard downloads[model.id]?.status != .downloading else { return }
        guard let url = URL(string: model.downloadURL) else { return }

        downloads[model.id]?.status = .downloading
        downloads[model.id]?.error = nil

        let task: URLSessionDownloadTask
        if let resume = resumeData[model.id] {
            task = session.downloadTask(withResumeData: resume)
        } else {
            task = session.downloadTask(with: url)
        }
        task.taskDescription = model.id
        tasks[model.id] = task
        task.resume()

        if #available(iOS 16.1, *) {
            DownloadActivityManager.shared.start(modelName: model.name, modelId: model.id)
        }
    }

    func pauseDownload(_ model: LocalModel) {
        guard let task = tasks[model.id] else { return }
        task.cancel { [weak self] data in
            if let data {
                self?.resumeData[model.id] = data
                self?.saveResumeData()
            }
            DispatchQueue.main.async {
                self?.downloads[model.id]?.status = .paused
            }
            if #available(iOS 16.1, *) {
                DownloadActivityManager.shared.end(modelId: model.id)
            }
        }
        tasks[model.id] = nil
    }

    func deleteModel(_ model: LocalModel) {
        pauseDownload(model)
        let p = path(for: model)
        try? FileManager.default.removeItem(at: p)
        resumeData[model.id] = nil
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
                guard let modelId = task.taskDescription else { continue }
                DispatchQueue.main.async {
                    self?.tasks[modelId] = task
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
        guard let modelId = downloadTask.taskDescription else { return }
        let progress = totalBytesExpectedToWrite > 0
            ? Double(totalBytesWritten) / Double(totalBytesExpectedToWrite)
            : 0
        DispatchQueue.main.async { [weak self] in
            self?.downloads[modelId]?.progress = progress
            if #available(iOS 16.1, *) {
                DownloadActivityManager.shared.update(modelId: modelId,
                                                       progress: progress,
                                                       downloadedBytes: totalBytesWritten,
                                                       totalBytes: totalBytesExpectedToWrite)
            }
        }
    }

    func urlSession(_ session: URLSession,
                    downloadTask: URLSessionDownloadTask,
                    didFinishDownloadingTo location: URL) {
        guard let modelId = downloadTask.taskDescription,
              let model = LocalModelCatalog.find(id: modelId) else { return }
        let dest = path(for: model)
        try? FileManager.default.removeItem(at: dest)
        do {
            try FileManager.default.moveItem(at: location, to: dest)
            DispatchQueue.main.async { [weak self] in
                self?.downloads[modelId] = DownloadState(downloaded: true, progress: 1.0, status: .completed)
                self?.resumeData[modelId] = nil
                self?.saveResumeData()
                if #available(iOS 16.1, *) {
                    DownloadActivityManager.shared.end(modelId: modelId)
                }
                self?.notifyDownloadComplete(model: model)
            }
        } catch {
            DispatchQueue.main.async { [weak self] in
                self?.downloads[modelId]?.status = .failed
                self?.downloads[modelId]?.error = error.localizedDescription
                if #available(iOS 16.1, *) {
                    DownloadActivityManager.shared.end(modelId: modelId)
                }
            }
        }
    }

    func urlSession(_ session: URLSession, task: URLSessionTask, didCompleteWithError error: Error?) {
        guard let downloadTask = task as? URLSessionDownloadTask,
              let modelId = downloadTask.taskDescription else { return }
        // 成功时 error 为 nil，无需处理（已在 didFinishDownloadingTo 完成）
        guard let error = error else { return }

        let nsError = error as NSError
        if nsError.code == NSURLErrorCancelled {
            // 用户在 pause 中主动取消，已在 pauseDownload 里处理
            return
        }

        DispatchQueue.main.async { [weak self] in
            // 尝试从错误中恢复断点数据
            if let data = nsError.userInfo[NSURLSessionDownloadTaskResumeData] as? Data {
                self?.resumeData[modelId] = data
                self?.saveResumeData()
                self?.downloads[modelId]?.status = .failed
                self?.downloads[modelId]?.error = "下载中断，可点击「继续」重试"
            } else {
                self?.downloads[modelId]?.status = .failed
                self?.downloads[modelId]?.error = error.localizedDescription
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
