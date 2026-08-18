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
struct AmbientBackground: View {
    @State private var move = false

    var body: some View {
        LinearGradient(
            colors: [
                AppTheme.background,
                AppTheme.background.opacity(0.55),
                AppTheme.accent.opacity(0.10),
                AppTheme.background
            ],
            startPoint: move ? .topLeading : .bottomTrailing,
            endPoint: move ? .bottomTrailing : .topLeading
        )
        .ignoresSafeArea()
        .onAppear {
            withAnimation(.easeInOut(duration: 9).repeatForever(autoreverses: true)) {
                move.toggle()
            }
        }
    }
}