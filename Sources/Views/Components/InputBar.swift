import SwiftUI

/// 底部自适应高度输入栏（紧凑版，高度已降低一半）
struct InputBar: View {
    @Binding var text: String
    @Binding var voiceMode: Bool
    let isGenerating: Bool
    let onSend: () -> Void

    @FocusState private var isFocused: Bool

    private let minHeight: CGFloat = 26
    private let maxHeight: CGFloat = 38

    var body: some View {
        HStack(alignment: .bottom, spacing: 6) {
            if voiceMode {
                voiceButton
            } else {
                textField
            }

            // 发送按钮
            Button(action: onSend) {
                Image(systemName: isGenerating ? "stop.fill" : "arrow.up")
                    .font(.system(size: 13, weight: .bold))
                    .foregroundColor(AppTheme.userBubbleText)
                    .frame(width: 30, height: 30)
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
        .padding(.top, 2)
        .padding(.bottom, 2)
    }

    private var textField: some View {
        TextField("输入消息…", text: $text, axis: .vertical)
            .focused($isFocused)
            .font(.system(size: 13))
            .foregroundColor(AppTheme.primaryText)
            .lineLimit(1...3)
            .padding(.horizontal, 10)
            .padding(.vertical, 3)
            .frame(minHeight: minHeight, maxHeight: maxHeight)
            .background(AppTheme.surfaceElevated)
            .clipShape(RoundedRectangle(cornerRadius: 14, style: .continuous))
            .overlay(
                RoundedRectangle(cornerRadius: 14, style: .continuous)
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
    }

    /// 长按语音输入（Apple Speech 公开框架，端侧识别）
    private var voiceButton: some View {
        Button {
            // 实际录制由长按手势控制
        } label: {
            HStack(spacing: 8) {
                Image(systemName: SpeechRecognizer.shared.isRecording ? "waveform" : "mic.fill")
                    .font(.system(size: 14))
                    .foregroundColor(SpeechRecognizer.shared.isRecording ? AppTheme.error : AppTheme.accent)
                Text(SpeechRecognizer.shared.isRecording ? "正在聆听…松开发送" : "按住 说话")
                    .font(.system(size: 14, weight: .medium))
                    .foregroundColor(AppTheme.primaryText)
            }
            .frame(maxWidth: .infinity)
            .frame(height: maxHeight + 6)
            .background(AppTheme.surfaceElevated)
            .clipShape(RoundedRectangle(cornerRadius: 14, style: .continuous))
            .overlay(
                RoundedRectangle(cornerRadius: 14, style: .continuous)
                    .stroke(AppTheme.border.opacity(0.6), lineWidth: 0.5)
            )
        }
        .onLongPressGesture(minimumDuration: 0.05, maximumDistance: .infinity,
            pressing: { pressing in
                if pressing {
                    SpeechRecognizer.shared.start()
                } else {
                    let transcript = SpeechRecognizer.shared.stop()
                    if !transcript.isEmpty {
                        let merged = (text + transcript).trimmingCharacters(in: .whitespacesAndNewlines)
                        text = merged
                    }
                }
            }, perform: {})
    }

    private var canSend: Bool {
        !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty && !isGenerating
    }
}
