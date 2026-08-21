import SwiftUI

/// 全局深色主题色板
/// 热更新：所有颜色改为计算属性，优先读取远程主题（AppConfig.shared.themeColor），
/// 未配置时回退到内置深色默认值。这样 UI 主题可远程热更、灰度发布。
enum AppTheme {
    // 背景层级
    static var background: Color { themed("background") ?? Color(red: 0.05, green: 0.04, blue: 0.08) }       // #0D0A14 深底
    static var surface: Color { themed("surface") ?? Color(red: 0.09, green: 0.08, blue: 0.13) }             // 卡片表面
    static var surfaceElevated: Color { themed("surfaceElevated") ?? Color(red: 0.12, green: 0.11, blue: 0.18) } // 抬升表面

    // 用户气泡：高对比度亮色
    static var userBubble: Color { themed("userBubble") ?? Color(red: 0.98, green: 0.96, blue: 0.94) }
    static var userBubbleText: Color { themed("userBubbleText") ?? Color(red: 0.08, green: 0.07, blue: 0.10) }

    // AI 气泡：低饱和深色磨砂
    static var aiBubble: Color { themed("aiBubble") ?? Color(red: 0.15, green: 0.14, blue: 0.22) }
    static var aiBubbleText: Color { themed("aiBubbleText") ?? Color(red: 0.90, green: 0.89, blue: 0.93) }

    // 强调色
    static var accent: Color { themed("accent") ?? Color(red: 1.0, green: 0.63, blue: 0.42) }                 // 暖橙 #FFA06B
    static var accentSoft: Color { themed("accentSoft") ?? Color(red: 1.0, green: 0.72, blue: 0.55) }

    // 文本
    static var primaryText: Color { themed("primaryText") ?? Color(red: 0.95, green: 0.94, blue: 0.97) }
    static var secondaryText: Color { themed("secondaryText") ?? Color(red: 0.62, green: 0.60, blue: 0.68) }
    static var tertiaryText: Color { themed("tertiaryText") ?? Color(red: 0.45, green: 0.43, blue: 0.50) }

    // 边框 / 分隔
    static var border: Color { themed("border") ?? Color(red: 0.20, green: 0.19, blue: 0.27) }
    static var divider: Color { themed("divider") ?? Color(red: 0.16, green: 0.15, blue: 0.22) }

    // 状态
    static var success: Color { themed("success") ?? Color(red: 0.30, green: 0.85, blue: 0.55) }
    static var warning: Color { themed("warning") ?? Color(red: 1.0, green: 0.80, blue: 0.30) }
    static var error: Color { themed("error") ?? Color(red: 1.0, green: 0.45, blue: 0.45) }

    // 超大圆角
    static var cornerRadius: CGFloat { AppConfig.shared.cornerRadius("cornerRadius", fallback: 28) }
    static var bubbleRadius: CGFloat { AppConfig.shared.cornerRadius("bubbleRadius", fallback: 30) }
    static let cardRadius: CGFloat = 24
    static let chipRadius: CGFloat = 999

    /// 读取远程主题色（nil = 未配置，回退默认）
    private static func themed(_ key: String) -> Color? {
        AppConfig.shared.themeColor(key)
    }
}

// MARK: - 表面/控件背景助手
/// 说明：原「液态玻璃」方案已按需求移除（开关与视觉效果一并取消）。
/// 以下助手保留原签名仅为兼容既有调用点，但 `enabled` 不再产生任何特殊效果，
/// 始终回落到 `fallback` 原实色，UI 表现与移除液态玻璃前一致。
extension View {
    /// 矩形表面：始终使用 fallback 实色（液态玻璃已移除）。
    @ViewBuilder
    func glassify(fallback: Color,
                  radius: CGFloat = AppTheme.cardRadius,
                  material: Material = .regularMaterial,
                  enabled: Bool) -> some View {
        self.background(fallback)
    }

    /// 圆形控件：始终使用 fallback 实色（液态玻璃已移除）。
    @ViewBuilder
    func glassCircle(fallback: Color, enabled: Bool, line: Color = AppTheme.border.opacity(0.5)) -> some View {
        self.background(Circle().fill(fallback))
            .overlay(Circle().stroke(line, lineWidth: 0.5))
    }

    /// 胶囊控件（如模式切换）：始终使用 fallback 实色（液态玻璃已移除）。
    @ViewBuilder
    func glassifyCapsule(fallback: Color, enabled: Bool) -> some View {
        self.background(Capsule().fill(fallback))
    }
}