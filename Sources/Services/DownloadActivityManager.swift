import Foundation
import ActivityKit

/// 管理模型下载的 Live Activity（锁屏 / 灵动岛实时进度）
@available(iOS 16.1, *)
final class DownloadActivityManager {
    static let shared = DownloadActivityManager()
    private var activities: [String: Activity<ModelDownloadAttributes>] = [:]

    private init() {}

    func start(modelName: String, modelId: String) {
        guard ActivityAuthorizationInfo().areActivitiesEnabled else { return }
        guard activities[modelId] == nil else { return }
        let attributes = ModelDownloadAttributes(modelName: modelName)
        let state = ModelDownloadAttributes.ContentState(progress: 0, downloadedMB: 0, totalMB: 0)
        do {
            activities[modelId] = try Activity.request(attributes: attributes,
                                                       contentState: state,
                                                       pushType: nil)
        } catch {
            // Live Activity 可能被用户禁用，忽略即可，不影响下载
        }
    }

    func update(modelId: String, progress: Double, downloadedBytes: Int64, totalBytes: Int64) {
        guard let activity = activities[modelId] else { return }
        let state = ModelDownloadAttributes.ContentState(
            progress: progress,
            downloadedMB: Double(downloadedBytes) / 1_048_576,
            totalMB: Double(totalBytes) / 1_048_576
        )
        Task {
            await activity.update(using: state)
        }
    }

    func end(modelId: String) {
        guard let activity = activities[modelId] else { return }
        activities[modelId] = nil
        Task {
            await activity.end(dismissalPolicy: .immediate)
        }
    }
}
