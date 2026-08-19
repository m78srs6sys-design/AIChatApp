import Foundation
import ActivityKit

/// 离线模型「生成回复」的 Live Activity 属性（锁屏 + 灵动岛实时进度）
@available(iOS 16.1, *)
struct ModelInferenceAttributes: ActivityAttributes {
    public struct ContentState: Codable, Hashable {
        var statusText: String   // 状态文案，如「正在生成回复…」
        var progress: Double      // 0.0 ~ 1.0（软估算，生成完成后置 1.0）
        var tokens: Int          // 已生成的 token 数
    }

    /// 固定属性：模型名称（启动时确定，之后不变）
    var modelName: String
}
