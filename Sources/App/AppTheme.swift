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

// MARK: - 液态玻璃（Liquid Glass）质感
/// 通过毛玻璃材质 + 顶部高光渐变 + 高光描边 + 投影，模拟液态玻璃观感。
/// enabled=false 时整体不生效，保持原有样式（默认关闭，由设置项控制）。
extension View {
    @ViewBuilder
    func liquidGlass(enabled: Bool, radius: CGFloat = 18, material: Material = .ultraThinMaterial) -> some View {
        if enabled {
            self.background(LiquidGlassBackdrop(radius: radius, material: material))
        } else {
            self
        }
    }
}

/// 系统液态玻璃底板：仅使用 SwiftUI `Material`。
/// 在 iOS 26+ 设备上，系统会把 Material 直接渲染成真正的 Liquid Glass（折射 / 高光 / 边缘由系统处理），
/// 因此这里只负责提供形状与材质，不再手搓任何白色描边 / 扫光 / 高光（那是假效果）。
struct LiquidGlassBackdrop: View {
    let radius: CGFloat
    let material: Material

    var body: some View {
        RoundedRectangle(cornerRadius: radius, style: .continuous)
            .fill(material)
    }
}

// MARK: - 全局液态玻璃助手（让任意表面/控件一键变成液态玻璃）
extension View {
    /// 矩形表面：开启液态玻璃时用毛玻璃底板，否则回落到原实色 fallback。
    /// 用在原本 `.background(AppTheme.surface)` / `.surfaceElevated` 的地方。
    @ViewBuilder
    func glassify(fallback: Color,
                  radius: CGFloat = AppTheme.cardRadius,
                  material: Material = .regularMaterial,
                  enabled: Bool) -> some View {
        self.background {
            if enabled {
                LiquidGlassBackdrop(radius: radius, material: material)
            } else {
                fallback
            }
        }
    }

    /// 圆形控件：开启液态玻璃时用系统毛玻璃圆（iOS 26 上即 Liquid Glass），否则回落原实色圆。
    @ViewBuilder
    func glassCircle(fallback: Color, enabled: Bool, line: Color = AppTheme.border.opacity(0.5)) -> some View {
        if enabled {
            self.background(Circle().fill(.regularMaterial))
        } else {
            self.background(Circle().fill(fallback))
                .overlay(Circle().stroke(line, lineWidth: 0.5))
        }
    }

    /// 胶囊控件（如模式切换）：开启液态玻璃时用系统毛玻璃胶囊，否则回落原实色胶囊。
    @ViewBuilder
    func glassifyCapsule(fallback: Color, enabled: Bool) -> some View {
        self.background {
            if enabled {
                Capsule().fill(.regularMaterial)
            } else {
                Capsule().fill(fallback)
            }
        }
    }
}