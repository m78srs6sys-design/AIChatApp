import SwiftUI

/// 底部自适应高度输入栏（紧凑版）
struct InputBar: View {
    @Binding var text: String
    let isGenerating: Bool
    let onSend: () -> Void

    @FocusState private var isFocused: Bool

    private let minHeight: CGFloat = 30
    private let maxHeight: CGFloat = 68

    var body: some View {
        HStack(alignment: .bottom, spacing: 6) {
            TextField("输入消息…", text: $text, axis: .vertical)
                .focused($isFocused)
                .font(.system(size: 13))
                .foregroundColor(AppTheme.primaryText)
                .lineLimit(1...3)
                .padding(.horizontal, 11)
                .padding(.vertical, 5)
                .frame(minHeight: minHeight, maxHeight: maxHeight)
                .background(AppTheme.surfaceElevated)
                .clipShape(RoundedRectangle(cornerRadius: 15, style: .continuous))
                .overlay(
                    RoundedRectangle(cornerRadius: 15, style: .continuous)
                        .stroke(AppTheme.border.opacity(0.6), lineWidth: 0.5)
                )
                .toolbar {
                    ToolbarItemGroup(placement: .keyboard) {
                        Spacer()
                        Button("完成") {
                            isFocused = false
                        }
                        .font(.system(size: 14, weight: .medium))
                    }
                }

            // 发送按钮
            Button(action: onSend) {
                Image(systemName: isGenerating ? "stop.fill" : "arrow.up")
                    .font(.system(size: 14, weight: .bold))
                    .foregroundColor(AppTheme.userBubbleText)
                    .frame(width: 32, height: 32)
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
        .padding(.horizontal, 10)
        .padding(.top, 3)
        .padding(.bottom, 3)
    }

    private var canSend: Bool {
        !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty && !isGenerating
    }
}
