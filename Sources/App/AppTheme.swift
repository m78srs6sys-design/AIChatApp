import SwiftUI

/// 全局深色主题色板
enum AppTheme {
    // 背景层级
    static let background = Color(red: 0.05, green: 0.04, blue: 0.08)       // #0D0A14 深底
    static let surface = Color(red: 0.09, green: 0.08, blue: 0.13)          // 卡片表面
    static let surfaceElevated = Color(red: 0.12, green: 0.11, blue: 0.18)  // 抬升表面

    // 用户气泡：高对比度亮色
    static let userBubble = Color(red: 0.98, green: 0.96, blue: 0.94)
    static let userBubbleText = Color(red: 0.08, green: 0.07, blue: 0.10)

    // AI 气泡：低饱和深色磨砂
    static let aiBubble = Color(red: 0.15, green: 0.14, blue: 0.22)
    static let aiBubbleText = Color(red: 0.90, green: 0.89, blue: 0.93)

    // 强调色
    static let accent = Color(red: 1.0, green: 0.63, blue: 0.42)            // 暖橙 #FFA06B
    static let accentSoft = Color(red: 1.0, green: 0.72, blue: 0.55)

    // 文本
    static let primaryText = Color(red: 0.95, green: 0.94, blue: 0.97)
    static let secondaryText = Color(red: 0.62, green: 0.60, blue: 0.68)
    static let tertiaryText = Color(red: 0.45, green: 0.43, blue: 0.50)

    // 边框 / 分隔
    static let border = Color(red: 0.20, green: 0.19, blue: 0.27)
    static let divider = Color(red: 0.16, green: 0.15, blue: 0.22)

    // 状态
    static let success = Color(red: 0.30, green: 0.85, blue: 0.55)
    static let warning = Color(red: 1.0, green: 0.80, blue: 0.30)
    static let error = Color(red: 1.0, green: 0.45, blue: 0.45)

    // 超大圆角
    static let cornerRadius: CGFloat = 28
    static let bubbleRadius: CGFloat = 30
    static let cardRadius: CGFloat = 24
    static let chipRadius: CGFloat = 999
}