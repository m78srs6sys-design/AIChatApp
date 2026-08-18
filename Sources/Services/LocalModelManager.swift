import Foundation
import Combine

/// 本地模型下载管理：支持开始/暂停/续传/删除
final class LocalModelManager: ObservableObject {
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
    private lazy var session: URLSession = {
        let config = URLSessionConfiguration.default
        config.isDiscretionary = false
        return URLSession(configuration: config, delegate: nil, delegateQueue: nil)
    }()

    init() {
        activeModelId = PersistenceManager.shared.loadActiveModelId()
        for model in LocalModelCatalog.models {
            if isDownloaded(model) {
                downloads[model.id] = DownloadState(downloaded: true, progress: 1.0, status: .completed)
            } else {
                downloads[model.id] = DownloadState(downloaded: false, progress: 0, status: .idle)
            }
        }
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
            task = session.downloadTask(withResumeData: resume) { [weak self] tempURL, _, err in
                self?.handleCompletion(model: model, tempURL: tempURL, error: err)
            }
        } else {
            task = session.downloadTask(with: url) { [weak self] tempURL, _, err in
                self?.handleCompletion(model: model, tempURL: tempURL, error: err)
            }
        }

        let observer = task.progress.observe(\.fractionCompleted, options: [.new]) { [weak self] progress, _ in
            DispatchQueue.main.async {
                self?.downloads[model.id]?.progress = progress.fractionCompleted
            }
        }
        objc_setAssociatedObject(task, "progressObserver", observer, .OBJC_ASSOCIATION_RETAIN_NONATOMIC)

        tasks[model.id] = task
        task.resume()
    }

    func pauseDownload(_ model: LocalModel) {
        guard let task = tasks[model.id] else { return }
        task.cancel { [weak self] data in
            if let data {
                self?.resumeData[model.id] = data
            }
            DispatchQueue.main.async {
                self?.downloads[model.id]?.status = .paused
            }
        }
        tasks[model.id] = nil
    }

    func deleteModel(_ model: LocalModel) {
        pauseDownload(model)
        let p = path(for: model)
        try? FileManager.default.removeItem(at: p)
        resumeData[model.id] = nil
        downloads[model.id] = DownloadState(downloaded: false, progress: 0, status: .idle)
        if activeModelId == model.id {
            activeModelId = nil
            PersistenceManager.shared.saveActiveModelId(nil)
        }
    }

    func setActive(_ model: LocalModel) {
        activeModelId = model.id
        PersistenceManager.shared.saveActiveModelId(model.id)
    }

    // MARK: - Completion
    private func handleCompletion(model: LocalModel, tempURL: URL?, error: Error?) {
        DispatchQueue.main.async {
            if let error = error {
                let nsError = error as NSError
                if nsError.code == NSURLErrorCancelled {
                    // 已在 pause 中处理
                    return
                }
                self.downloads[model.id]?.status = .failed
                self.downloads[model.id]?.error = error.localizedDescription
                return
            }
            guard let tempURL else { return }
            let dest = self.path(for: model)
            try? FileManager.default.removeItem(at: dest)
            do {
                try FileManager.default.moveItem(at: tempURL, to: dest)
                self.downloads[model.id] = DownloadState(downloaded: true, progress: 1.0, status: .completed)
                self.resumeData[model.id] = nil
            } catch {
                self.downloads[model.id]?.status = .failed
                self.downloads[model.id]?.error = error.localizedDescription
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