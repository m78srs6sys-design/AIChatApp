import SwiftUI

/// 底部自适应高度输入栏
struct InputBar: View {
    @Binding var text: String
    let isGenerating: Bool
    let onSend: () -> Void

    @FocusState private var isFocused: Bool

    private let minHeight: CGFloat = 40
    private let maxHeight: CGFloat = 100

    var body: some View {
        HStack(alignment: .bottom, spacing: 10) {
            // 自适应高度文本框
            ZStack(alignment: .topLeading) {
                Text(text.isEmpty ? " " : text)
                    .font(.system(size: 15))
                    .padding(.horizontal, 14)
                    .padding(.vertical, 8)
                    .background(GeometryReader { proxy in
                        Color.clear.preference(key: TextHeightKey.self, value: proxy.size.height)
                    })
                    .opacity(0)

                TextField("", text: $text, axis: .vertical)
                    .focused($isFocused)
                    .font(.system(size: 15))
                    .foregroundColor(AppTheme.primaryText)
                    .lineLimit(1...5)
                    .padding(.horizontal, 14)
                    .padding(.vertical, 8)
                    .frame(minHeight: minHeight, maxHeight: maxHeight)
                    .background(AppTheme.surfaceElevated)
                    .clipShape(RoundedRectangle(cornerRadius: AppTheme.cornerRadius, style: .continuous))
                    .overlay(
                        RoundedRectangle(cornerRadius: AppTheme.cornerRadius, style: .continuous)
                            .stroke(AppTheme.border.opacity(0.6), lineWidth: 0.5)
                    )
            }

            // 发送按钮
            Button(action: onSend) {
                Image(systemName: isGenerating ? "stop.fill" : "arrow.up")
                    .font(.system(size: 16, weight: .bold))
                    .foregroundColor(AppTheme.userBubbleText)
                    .frame(width: 40, height: 40)
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
        .padding(.horizontal, 16)
        .padding(.top, 6)
        .padding(.bottom, 2)
    }

    private var canSend: Bool {
        !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty && !isGenerating
    }
}

private struct TextHeightKey: PreferenceKey {
    static var defaultValue: CGFloat = 0
    static func reduce(value: inout CGFloat, nextValue: () -> CGFloat) {
        value = max(value, nextValue())
    }
}