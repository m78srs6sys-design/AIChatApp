import SwiftUI

/// AI 流式输出时的打字光标（流光动画）
struct TypingCursor: View {
    @State private var opacity: Double = 1.0

    var body: some View {
        Circle()
            .fill(AppTheme.accent)
            .frame(width: 8, height: 8)
            .opacity(opacity)
            .onAppear {
                withAnimation(.easeInOut(duration: 0.6).repeatForever(autoreverses: true)) {
                    opacity = 0.2
                }
            }
    }
}

/// 加载流光特效（用于推理/下载进度）
struct ShimmerView: View {
    @State private var phase: CGFloat = -1

    var body: some View {
        GeometryReader { geo in
            LinearGradient(
                colors: [
                    AppTheme.surfaceElevated.opacity(0.6),
                    AppTheme.accent.opacity(0.35),
                    AppTheme.surfaceElevated.opacity(0.6)
                ],
                startPoint: .leading,
                endPoint: .trailing
            )
            .frame(width: geo.size.width * 1.5)
            .offset(x: phase * geo.size.width * 1.5)
            .onAppear {
                withAnimation(.linear(duration: 1.4).repeatForever(autoreverses: false)) {
                    phase = 1
                }
            }
        }
        .clipped()
    }
}

/// 按压回弹按钮样式
struct BounceButtonStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .scaleEffect(configuration.isPressed ? 0.92 : 1.0)
            .animation(.spring(response: 0.25, dampingFraction: 0.6), value: configuration.isPressed)
    }
}

/// 背景流动光晕（缓慢呼吸，提升质感）
/// 注意：改用 TimelineView 驱动，不用 withAnimation(.repeatForever)+@State 改布局属性——
/// 后者在 iOS 18/26 上会触发 SwiftUI `LocationBox.update` 无限递归 SIGTRAP 崩溃。
struct AmbientBackground: View {
    var body: some View {
        TimelineView(.animation(minimumInterval: 1 / 30)) { context in
            let t = context.date.timeIntervalSinceReferenceDate
            // 0...1 缓慢呼吸，周期 18s（一呼一吸）
            let phase = (sin(t * 2 * .pi / 18) + 1) / 2
            LinearGradient(
                colors: [
                    AppTheme.background,
                    AppTheme.background.opacity(0.55),
                    AppTheme.accent.opacity(0.10),
                    AppTheme.background
                ],
                startPoint: UnitPoint(x: 0.5 - 0.5 * phase, y: 0.5 - 0.5 * phase),
                endPoint: UnitPoint(x: 0.5 + 0.5 * phase, y: 0.5 + 0.5 * phase)
            )
            .ignoresSafeArea()
        }
    }
}