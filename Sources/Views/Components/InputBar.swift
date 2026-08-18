import SwiftUI

/// 底部自适应高度输入栏（紧凑版）
struct InputBar: View {
    @Binding var text: String
    let isGenerating: Bool
    let onSend: () -> Void

    @FocusState private var isFocused: Bool

    private let minHeight: CGFloat = 36
    private let maxHeight: CGFloat = 84

    var body: some View {
        HStack(alignment: .bottom, spacing: 8) {
            TextField("输入消息…", text: $text, axis: .vertical)
                .focused($isFocused)
                .font(.system(size: 14))
                .foregroundColor(AppTheme.primaryText)
                .lineLimit(1...4)
                .padding(.horizontal, 12)
                .padding(.vertical, 7)
                .frame(minHeight: minHeight, maxHeight: maxHeight)
                .background(AppTheme.surfaceElevated)
                .clipShape(RoundedRectangle(cornerRadius: 18, style: .continuous))
                .overlay(
                    RoundedRectangle(cornerRadius: 18, style: .continuous)
                        .stroke(AppTheme.border.opacity(0.6), lineWidth: 0.5)
                )

            // 发送按钮
            Button(action: onSend) {
                Image(systemName: isGenerating ? "stop.fill" : "arrow.up")
                    .font(.system(size: 15, weight: .bold))
                    .foregroundColor(AppTheme.userBubbleText)
                    .frame(width: 36, height: 36)
                    .background(
                        Circle()
                            .fill(canSend ? AppTheme.accent : AppTheme.surfaceElevated)
                    )
                    .overlay(
                        Circle().stroke(canSend ? Color.clear : AppTheme.border.opacity(0.5), lineWidth: 0.5)
                    )
            }
            .buttonStyle(BounceButtonStyle())
            .disabled(!canSend && !isGenerating)
        }
        .padding(.horizontal, 12)
        .padding(.top, 4)
        .padding(.bottom, 4)
    }

    private var canSend: Bool {
        !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty && !isGenerating
    }
}
