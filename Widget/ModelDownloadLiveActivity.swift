import WidgetKit
import SwiftUI
import ActivityKit

/// 模型下载 Live Activity（锁屏 + 灵动岛）
@available(iOS 16.1, *)
struct ModelDownloadLiveActivity: Widget {
    var body: some WidgetConfiguration {
        if #available(iOS 16.2, *) {
            return ActivityConfiguration(for: ModelDownloadAttributes.self) { context in
                downloadLockScreen(context)
            } dynamicIsland: { context in
                downloadDynamicIsland(context)
            }
        } else {
            return ActivityConfiguration(for: ModelDownloadAttributes.self) { context in
                downloadLockScreen(context)
            }
        }
    }

    @ViewBuilder
    private func downloadLockScreen(_ context: ActivityViewContext<ModelDownloadAttributes>) -> some View {
        HStack(spacing: 12) {
            Image(systemName: "arrow.down.circle.fill")
                .font(.system(size: 28))
                .foregroundColor(.blue)
            VStack(alignment: .leading, spacing: 4) {
                Text("正在下载 \(context.attributes.modelName)")
                    .font(.system(size: 14, weight: .semibold))
                    .lineLimit(1)
                ProgressView(value: context.state.progress)
                    .tint(.blue)
                HStack {
                    Text(String(format: "%.0f MB / %.0f MB",
                                context.state.downloadedMB,
                                context.state.totalMB))
                        .font(.system(size: 11))
                        .foregroundColor(.secondary)
                    Spacer()
                    Text("\(Int(context.state.progress * 100))%")
                        .font(.system(size: 12, weight: .bold))
                        .monospacedDigit()
                }
            }
        }
        .padding()
        .activityBackgroundTint(Color.black.opacity(0.4))
        .activitySystemActionForegroundColor(.white)
    }

    @DynamicIslandBuilder
    private func downloadDynamicIsland(_ context: ActivityViewContext<ModelDownloadAttributes>) -> DynamicIsland {
        DynamicIsland {
            DynamicIslandExpandedRegion(.leading) {
                Image(systemName: "arrow.down.circle.fill")
                    .font(.system(size: 22))
                    .foregroundColor(.blue)
            }
            DynamicIslandExpandedRegion(.center) {
                Text("\(Int(context.state.progress * 100))%")
                    .font(.system(size: 16, weight: .bold))
                    .monospacedDigit()
            }
            DynamicIslandExpandedRegion(.bottom) {
                ProgressView(value: context.state.progress)
                    .tint(.blue)
            }
        } compactLeading: {
            Image(systemName: "arrow.down.circle.fill")
                .foregroundColor(.blue)
        } compactTrailing: {
            Text("\(Int(context.state.progress * 100))%")
                .font(.system(size: 12, weight: .bold))
                .monospacedDigit()
        } minimal: {
            Image(systemName: "arrow.down.circle.fill")
                .foregroundColor(.blue)
        }
    }
}

/// 离线模型「生成回复」Live Activity（锁屏 + 灵动岛）
@available(iOS 16.1, *)
struct ModelInferenceLiveActivity: Widget {
    var body: some WidgetConfiguration {
        if #available(iOS 16.2, *) {
            return ActivityConfiguration(for: ModelInferenceAttributes.self) { context in
                inferenceLockScreen(context)
            } dynamicIsland: { context in
                inferenceDynamicIsland(context)
            }
        } else {
            return ActivityConfiguration(for: ModelInferenceAttributes.self) { context in
                inferenceLockScreen(context)
            }
        }
    }

    @ViewBuilder
    private func inferenceLockScreen(_ context: ActivityViewContext<ModelInferenceAttributes>) -> some View {
        HStack(spacing: 12) {
            Image(systemName: "cpu.fill")
                .font(.system(size: 26))
                .foregroundColor(.orange)
            VStack(alignment: .leading, spacing: 4) {
                Text(context.state.statusText)
                    .font(.system(size: 14, weight: .semibold))
                    .lineLimit(1)
                Text("离线模型 · \(context.attributes.modelName)")
                    .font(.system(size: 11))
                    .foregroundColor(.secondary)
                    .lineLimit(1)
                ProgressView(value: context.state.progress)
                    .tint(.orange)
                HStack {
                    Text("已生成 \(context.state.tokens) 字")
                        .font(.system(size: 11))
                        .foregroundColor(.secondary)
                    Spacer()
                    Text("\(Int(context.state.progress * 100))%")
                        .font(.system(size: 12, weight: .bold))
                        .monospacedDigit()
                }
            }
        }
        .padding()
        .activityBackgroundTint(Color.black.opacity(0.4))
        .activitySystemActionForegroundColor(.white)
    }

    @DynamicIslandBuilder
    private func inferenceDynamicIsland(_ context: ActivityViewContext<ModelInferenceAttributes>) -> DynamicIsland {
        DynamicIsland {
            DynamicIslandExpandedRegion(.leading) {
                Image(systemName: "cpu.fill")
                    .font(.system(size: 22))
                    .foregroundColor(.orange)
            }
            DynamicIslandExpandedRegion(.center) {
                Text(context.state.statusText)
                    .font(.system(size: 14, weight: .semibold))
                    .lineLimit(1)
            }
            DynamicIslandExpandedRegion(.bottom) {
                ProgressView(value: context.state.progress)
                    .tint(.orange)
            }
        } compactLeading: {
            Image(systemName: "cpu.fill")
                .foregroundColor(.orange)
        } compactTrailing: {
            Text("\(Int(context.state.progress * 100))%")
                .font(.system(size: 12, weight: .bold))
                .monospacedDigit()
        } minimal: {
            Image(systemName: "cpu.fill")
                .foregroundColor(.orange)
        }
    }
}

/// Widget 扩展入口：承载上述两个 Live Activity
@main
struct AIChatAppWidgetBundle: WidgetBundle {
    var body: some Widget {
        ModelDownloadLiveActivity()
        ModelInferenceLiveActivity()
    }
}
