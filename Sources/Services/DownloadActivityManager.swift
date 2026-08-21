import Foundation
import ActivityKit

/// 管理模型下载与离线推理的 Live Activity（锁屏 / 灵动岛实时进度）
@available(iOS 16.1, *)
final class DownloadActivityManager {
    static let shared = DownloadActivityManager()
    private var activities: [String: Activity<ModelDownloadAttributes>] = [:]
    private var inferenceActivities: [String: Activity<ModelInferenceAttributes>] = [:]

    private init() {}

    // MARK: - 模型下载

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

    // MARK: - 离线模型「生成回复」占用率

    private let inferenceId = "offline-inference"
    /// 当前推理使用的模型名（兜底重建时使用）
    private var activeInferenceModel = ""

    /// 开始一个离线推理 Live Activity（锁屏 / 灵动岛显示「正在加载/生成…」）
    func startInference(modelName: String) {
        activeInferenceModel = modelName
        guard ActivityAuthorizationInfo().areActivitiesEnabled else { return }
        guard inferenceActivities[inferenceId] == nil else { return }
        let attributes = ModelInferenceAttributes(modelName: modelName)
        let usage = SystemUsage.snapshot()
        let state = ModelInferenceAttributes.ContentState(statusText: "正在加载/生成…",
                                                          usagePercent: usage.memory,
                                                          cpuPercent: usage.cpu,
                                                          tokens: 0,
                                                          isFinal: false)
        do {
            inferenceActivities[inferenceId] = try Activity.request(attributes: attributes,
                                                                     contentState: state,
                                                                     pushType: nil)
        } catch {
            // Live Activity 可能被用户禁用，忽略即可，不影响生成
        }
    }

    /// 更新推理占用率（每约 2 秒调用一次；百分比 = 资源占用率，非生成进度）
    func updateInference(tokens: Int, cpuPercent: Double, memPercent: Double, statusText: String = "正在生成回复…") {
        // 兜底：活动意外缺失时自动重建（如系统因负载回收了活动）
        if inferenceActivities[inferenceId] == nil, !activeInferenceModel.isEmpty {
            startInference(modelName: activeInferenceModel)
        }
        guard let activity = inferenceActivities[inferenceId] else { return }
        let state = ModelInferenceAttributes.ContentState(statusText: statusText,
                                                          usagePercent: memPercent,
                                                          cpuPercent: cpuPercent,
                                                          tokens: tokens,
                                                          isFinal: false)
        Task {
            await activity.update(using: state)
        }
    }

    /// 结束推理 Live Activity（显示「回复完成」后自动消失）
    func endInference() {
        activeInferenceModel = ""
        guard let activity = inferenceActivities[inferenceId] else { return }
        inferenceActivities[inferenceId] = nil
        let final = ModelInferenceAttributes.ContentState(statusText: "回复完成",
                                                          usagePercent: SystemUsage.snapshot().memory,
                                                          cpuPercent: SystemUsage.snapshot().cpu,
                                                          tokens: 0,
                                                          isFinal: true)
        Task {
            await activity.end(using: final, dismissalPolicy: .immediate)
        }
    }
}
