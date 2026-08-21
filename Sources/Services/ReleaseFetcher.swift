import Foundation
import Combine
import UIKit

/// 检查更新服务：从 GitHub Releases 拉取最新 IPA 并下载到本机。
/// 不处理安装 / 签名（按需求由用户自行处理），仅负责「检查 → 下载 → 本地文件」。
final class ReleaseFetcher: ObservableObject {
    static let shared = ReleaseFetcher()

    private let owner = "m78srs6sys-design"
    private let repo = "AIChatApp"

    /// 当前 App 构建号（取自 Info.plist 的 CFBundleVersion）
    @Published var currentBuild: Int
    /// 线上最新构建号
    @Published var latestBuild: Int = 0
    @Published var latestVersion: String = ""
    /// 最新版本说明
    @Published var releaseNotes: String = ""
    /// 最新 IPA 下载地址（来自最新 release 的 .ipa 资产）
    @Published var downloadURL: URL? = nil
    @Published var isChecking = false
    @Published var isDownloading = false
    @Published var downloadProgress: Double = 0
    /// 最近一次检查/下载结果说明（设置页展示）
    @Published var lastResult: String = "尚未检查"
    /// 下载完成后的本地文件（用于分享/导出）
    @Published var downloadedURL: URL? = nil

    private var session: URLSession?
    private var activeDelegate: DownloadDelegate?

    /// 是否存在可下载的新版本
    var hasUpdate: Bool { latestBuild > currentBuild && downloadURL != nil }

    init() {
        let buildStr = (Bundle.main.infoDictionary?["CFBundleVersion"] as? String) ?? "1"
        currentBuild = Int(buildStr) ?? 1
    }

    // MARK: - 检查更新
    @MainActor
    func checkForUpdate() async {
        guard !isChecking else { return }
        isChecking = true
        lastResult = "正在检查更新…"
        defer { isChecking = false }

        do {
            guard let url = URL(string: "https://api.github.com/repos/\(owner)/\(repo)/releases?per_page=30") else {
                lastResult = "更新地址无效"
                return
            }
            var req = URLRequest(url: url)
            req.setValue("application/vnd.github+json", forHTTPHeaderField: "Accept")
            let (data, response) = try await URLSession.shared.data(for: req)
            guard let http = response as? HTTPURLResponse, http.statusCode == 200 else {
                lastResult = "无法连接更新服务器（HTTP \( (response as? HTTPURLResponse)?.statusCode ?? -1 )）"
                return
            }
            let releases = try JSONDecoder().decode([GitHubRelease].self, from: data)
            // 仅保留含 .ipa 资产、且 tag 可解析为构建号的 release，按构建号降序
            let candidates = releases.compactMap { rel -> (build: Int, rel: GitHubRelease)? in
                guard let build = buildFromTag(rel.tagName),
                      rel.assets.contains(where: { $0.name.hasSuffix(".ipa") }) else { return nil }
                return (build, rel)
            }.sorted { $0.build > $1.build }

            guard let best = candidates.first else {
                lastResult = "暂无可用更新"
                return
            }
            latestBuild = best.build
            latestVersion = best.rel.tagName
            releaseNotes = best.rel.body ?? ""
            downloadURL = best.rel.assets.first(where: { $0.name.hasSuffix(".ipa") })?.browserDownloadURL
            lastResult = latestBuild > currentBuild
                ? "发现新版本 v\(latestBuild)，点击「下载 IPA」获取"
                : "已是最新版本（v\(currentBuild)）"
        } catch {
            lastResult = "检查更新失败：\(error.localizedDescription)"
        }
    }

    /// 从 tag 解析构建号（支持 "v29" / "29" / "v1.2.3"）
    private func buildFromTag(_ tag: String) -> Int? {
        let cleaned = tag.hasPrefix("v") ? String(tag.dropFirst()) : tag
        for part in cleaned.components(separatedBy: ".") {
            if let n = Int(part) { return n }
        }
        return Int(cleaned)
    }

    // MARK: - 下载最新 IPA（带进度）
    @MainActor
    func downloadLatest() async {
        guard let source = downloadURL, !isDownloading else { return }
        isDownloading = true
        downloadProgress = 0
        lastResult = "正在下载 v\(latestBuild)…"

        await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
            let delegate = DownloadDelegate(
                onProgress: { [weak self] p in
                    Task { @MainActor in self?.downloadProgress = p }
                },
                onCompletion: { [weak self] localURL, error in
                    Task { @MainActor in
                        if let localURL {
                            self?.finalizeDownload(from: localURL)
                        } else {
                            self?.lastResult = "下载失败：\(error?.localizedDescription ?? "未知错误")"
                        }
                        self?.session?.finishTasksAndInvalidate()
                        self?.session = nil
                        self?.activeDelegate = nil
                        continuation.resume()
                    }
                }
            )
            self.activeDelegate = delegate
            let config = URLSessionConfiguration.default
            config.timeoutIntervalForResource = 300
            let session = URLSession(configuration: config, delegate: delegate, delegateQueue: nil)
            self.session = session
            session.downloadTask(with: source).resume()
        }
    }

    /// 把系统临时下载文件移动到 App 沙盒的 Downloads 目录
    private func finalizeDownload(from tmpURL: URL) {
        do {
            let fm = FileManager.default
            let dir = try fm.url(for: .documentDirectory, in: .userDomainMask,
                                 appropriateFor: nil, create: true)
                .appendingPathComponent("Downloads", isDirectory: true)
            try fm.createDirectory(at: dir, withIntermediateDirectories: true)
            let dest = dir.appendingPathComponent("AIChatApp-v\(latestBuild).ipa")
            if fm.fileExists(atPath: dest.path) { try fm.removeItem(at: dest) }
            try fm.moveItem(at: tmpURL, to: dest)
            downloadedURL = dest
            downloadProgress = 1
            lastResult = "下载完成，请在分享面板中导出 IPA（隔空投送 / 存储到文件）"
        } catch {
            lastResult = "保存失败：\(error.localizedDescription)"
        }
    }
}

// MARK: - 下载代理（带进度回调，且保证只完成一次）
private final class DownloadDelegate: NSObject, URLSessionDownloadDelegate {
    private var finished = false
    let onProgress: (Double) -> Void
    let onCompletion: (URL?, Error?) -> Void

    init(onProgress: @escaping (Double) -> Void, onCompletion: @escaping (URL?, Error?) -> Void) {
        self.onProgress = onProgress
        self.onCompletion = onCompletion
    }

    private func complete(_ url: URL?, _ error: Error?) {
        guard !finished else { return }
        finished = true
        onCompletion(url, error)
    }

    func urlSession(_ session: URLSession, downloadTask: URLSessionDownloadTask,
                    didWriteData bytesWritten: Int64,
                    totalBytesWritten: Int64,
                    totalBytesExpectedToWrite: Int64) {
        guard totalBytesExpectedToWrite > 0 else { return }
        onProgress(Double(totalBytesWritten) / Double(totalBytesExpectedToWrite))
    }

    func urlSession(_ session: URLSession, downloadTask: URLSessionDownloadTask,
                    didFinishDownloadingTo location: URL) {
        complete(location, nil)
    }

    func urlSession(_ session: URLSession, task: URLSessionTask, didCompleteWithError error: Error?) {
        if let error { complete(nil, error) }
    }
}

// MARK: - GitHub Releases API 模型
private struct GitHubRelease: Codable {
    let tagName: String
    let body: String?
    let assets: [GitHubAsset]
    enum CodingKeys: String, CodingKey {
        case tagName = "tag_name"
        case body
        case assets
    }
}

private struct GitHubAsset: Codable {
    let name: String
    let browserDownloadURL: URL
    enum CodingKeys: String, CodingKey {
        case name
        case browserDownloadURL = "browser_download_url"
    }
}
