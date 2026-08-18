import SwiftUI

/// 底部自适应高度输入栏
struct InputBar: View {
    @Binding var text: String
    let isGenerating: Bool
    let onSend: () -> Void

    @FocusState private var isFocused: Bool

    private let minHeight: CGFloat = 52
    private let maxHeight: CGFloat = 140

    var body: some View {
        HStack(alignment: .bottom, spacing: 10) {
            // 自适应高度文本框
            ZStack(alignment: .topLeading) {
                Text(text.isEmpty ? " " : text)
                    .font(.system(size: 16))
                    .padding(.horizontal, 16)
                    .padding(.vertical, 16)
                    .background(GeometryReader { proxy in
                        Color.clear.preference(key: TextHeightKey.self, value: proxy.size.height)
                    })
                    .opacity(0)

                TextField("", text: $text, axis: .vertical)
                    .focused($isFocused)
                    .font(.system(size: 16))
                    .foregroundColor(AppTheme.primaryText)
                    .lineLimit(1...6)
                    .padding(.horizontal, 16)
                    .padding(.vertical, 14)
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
                    .font(.system(size: 18, weight: .bold))
                    .foregroundColor(AppTheme.userBubbleText)
                    .frame(width: 52, height: 52)
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
        .padding(.top, 8)
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