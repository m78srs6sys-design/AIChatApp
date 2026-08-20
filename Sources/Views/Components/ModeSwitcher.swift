import SwiftUI

/// 模式切换胶囊（带渐变动画）
struct ModeSwitcher: View {
    @Binding var mode: ChatMode
    @EnvironmentObject var settingsVM: SettingsViewModel

    var body: some View {
        HStack(spacing: 0) {
            ForEach(ChatMode.allCases, id: \.self) { m in
                Button {
                    withAnimation(.spring(response: 0.4, dampingFraction: 0.75)) {
                        mode = m
                    }
                } label: {
                    Text(m.title)
                        .font(.system(size: 13, weight: .semibold))
                        .foregroundColor(mode == m ? AppTheme.userBubbleText : AppTheme.secondaryText)
                        .padding(.horizontal, 16)
                        .padding(.vertical, 8)
                        .frame(maxWidth: .infinity)
                        .background(
                            ZStack {
                                if mode == m {
                                    Capsule()
                                        .fill(AppTheme.userBubble)
                                        .matchedGeometryEffect(id: "modeCapsule", in: namespace)
                                        .shadow(color: AppTheme.accent.opacity(0.25), radius: 6, x: 0, y: 2)
                                }
                            }
                        )
                }
                .buttonStyle(BounceButtonStyle())
            }
        }
        .padding(4)
        .glassifyCapsule(fallback: AppTheme.surface, enabled: settingsVM.settings.liquidGlassEnabled)
    }

    @Namespace private var namespace
}