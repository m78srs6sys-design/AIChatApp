import Foundation
import ActivityKit

/// 离线模型下载的 Live Activity 属性（供主 App 与 Widget 扩展共享）
@available(iOS 16.1, *)
struct ModelDownloadAttributes: ActivityAttributes {
    public struct ContentState: Codable, Hashable {
        var progress: Double        // 0.0 ~ 1.0
        var downloadedMB: Double
        var totalMB: Double
    }

    /// 固定属性：模型名称（启动时确定，之后不变）
    var modelName: String
}
