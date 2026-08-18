import WidgetKit
import SwiftUI
import ActivityKit

/// 模型下载 Live Activity（锁屏 + 灵动岛）
@available(iOS 16.1, *)
struct ModelDownloadLiveActivity: Widget {
    var body: some WidgetConfiguration {
        ActivityConfiguration(for: ModelDownloadAttributes.self) { context in
            // 锁屏 / 通知中心横幅
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
        } dynamicIsland: { context in
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
}
