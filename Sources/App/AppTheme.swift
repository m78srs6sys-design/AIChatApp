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

/// 液态玻璃背景层：毛玻璃 + 光泽 + 描边 + 柔和投影，并带一道缓慢流动的高光扫光动画。
struct LiquidGlassBackdrop: View {
    let radius: CGFloat
    let material: Material
    @State private var sheen = false

    var body: some View {
        RoundedRectangle(cornerRadius: radius, style: .continuous)
            .fill(material)
            .overlay(
                // 顶部左高光 → 右下透明的光泽，营造玻璃厚度感
                RoundedRectangle(cornerRadius: radius, style: .continuous)
                    .fill(LinearGradient(
                        colors: [Color.white.opacity(0.28), Color.white.opacity(0.06), Color.clear],
                        startPoint: .topLeading, endPoint: .bottomTrailing))
            )
            .overlay(
                // 缓慢扫过的高光，增强「液态」流动感
                RoundedRectangle(cornerRadius: radius, style: .continuous)
                    .fill(LinearGradient(
                        colors: [Color.clear, Color.white.opacity(0.18), Color.clear],
                        startPoint: .leading, endPoint: .trailing))
                    .rotationEffect(.degrees(-18))
                    .offset(x: sheen ? 80 : -80)
                    .mask(RoundedRectangle(cornerRadius: radius, style: .continuous))
                    .opacity(0.6)
            )
            .overlay(
                RoundedRectangle(cornerRadius: radius, style: .continuous)
                    .stroke(Color.white.opacity(0.30), lineWidth: 1)
            )
            .shadow(color: .black.opacity(0.20), radius: 12, x: 0, y: 6)
            .onAppear {
                withAnimation(.easeInOut(duration: 3.2).repeatForever(autoreverses: true)) {
                    sheen.toggle()
                }
            }
    }
}