import UIKit

/// 极短震动反馈：生成每个字时调用一次。
enum Haptics {
    private static let generator = UIImpactFeedbackGenerator(style: .rigid)

    /// 预热，建议在开始生成前调用，保证连续震动跟手。
    static func prepare() {
        generator.prepare()
    }

    /// 触发一次极短震动。
    static func tick() {
        generator.impactOccurred(intensity: 0.35)
    }
}
