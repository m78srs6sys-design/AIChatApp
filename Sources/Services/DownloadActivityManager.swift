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

    // MARK: - 离线模型「生成回复」进度（复用同一管理器的活动表）

    private let inferenceId = "offline-inference"

    /// 开始一个离线推理 Live Activity（锁屏 / 灵动岛显示「正在生成回复…」）
    func startInference(modelName: String) {
        guard #available(iOS 16.1, *), ActivityAuthorizationInfo().areActivitiesEnabled else { return }
        guard activities[inferenceId] == nil else { return }
        let attributes = ModelInferenceAttributes(modelName: modelName)
        let state = ModelInferenceAttributes.ContentState(statusText: "正在生成回复…", progress: 0.02, tokens: 0)
        do {
            activities[inferenceId] = try Activity.request(attributes: attributes,
                                                           contentState: state,
                                                           pushType: nil)
        } catch {
            // Live Activity 可能被用户禁用，忽略即可，不影响生成
        }
    }

    /// 更新推理进度（每生成若干 token 调用一次）
    func updateInference(tokens: Int, progress: Double) {
        guard #available(iOS 16.1, *), let activity = activities[inferenceId] else { return }
        let state = ModelInferenceAttributes.ContentState(statusText: "正在生成回复…",
                                                         progress: progress,
                                                         tokens: tokens)
        Task {
            await activity.update(using: state)
        }
    }

    /// 结束推理 Live Activity（显示「回复完成」后自动消失）
    func endInference() {
        guard #available(iOS 16.1, *), let activity = activities[inferenceId] else { return }
        activities[inferenceId] = nil
        let final = ModelInferenceAttributes.ContentState(statusText: "回复完成", progress: 1.0, tokens: 0)
        Task {
            await activity.end(using: final, dismissalPolicy: .after(date: Date().addingTimeInterval(2)))
        }
    }
}
