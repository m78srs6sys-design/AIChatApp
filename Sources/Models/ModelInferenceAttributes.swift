import Foundation
import ActivityKit

/// 离线模型「生成回复」的 Live Activity 属性（锁屏 + 灵动岛实时进度）
/// 百分比显示的是「资源占用率」（内存/CPU），而非生成进度。
@available(iOS 16.1, *)
struct ModelInferenceAttributes: ActivityAttributes {
    public struct ContentState: Codable, Hashable {
        var statusText: String    // 状态文案，如「正在生成回复…」
        var usagePercent: Double  // 内存占用率 0~100（主指标）
        var cpuPercent: Double    // CPU 占用率 0~100（辅助指标）
        var tokens: Int           // 已生成的 token 数
        var isFinal: Bool         // true = 回复完成（结束态）
    }

    /// 固定属性：模型名称（启动时确定，之后不变）
    var modelName: String
}