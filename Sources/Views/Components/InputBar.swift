import SwiftUI

/// 底部自适应高度输入栏（紧凑版，语音开关为框内圆形按钮）
struct InputBar: View {
    @Binding var text: String
    @Binding var voiceMode: Bool
    let isGenerating: Bool
    let onSend: () -> Void

    @FocusState private var isFocused: Bool

    private let minHeight: CGFloat = 38
    private let maxHeight: CGFloat = 46

    var body: some View {
        HStack(alignment: .bottom, spacing: 6) {
            // 输入容器：圆形语音开关 + 文本 / 长按说话（同一圆角框内）
            inputBox
            sendButton
        }
        .padding(.horizontal, 10)
        .padding(.top, 0)
        .padding(.bottom, 2)
    }

    // 输入框整体容器（含圆形语音开关在框内最左侧）
    private var inputBox: some View {
        HStack(spacing: 6) {
            circularMicButton
            if voiceMode {
                holdToTalkInner
            } else {
                textFieldInner
            }
        }
        .padding(.horizontal, 8)
        .padding(.vertical, 3)
        .frame(minHeight: minHeight, maxHeight: maxHeight)
        .background(AppTheme.surfaceElevated)
        .clipShape(RoundedRectangle(cornerRadius: 14, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: 14, style: .continuous)
                .stroke(AppTheme.border.opacity(0.6), lineWidth: 0.5)
        )
    }

    /// 圆形语音开关（始终显示在输入框内最左侧，无文字）
    private var circularMicButton: some View {
        Button {
            withAnimation(.spring(response: 0.35, dampingFraction: 0.8)) {
                voiceMode.toggle()
            }
        } label: {
            Image(systemName: voiceMode ? "mic.fill" : "mic")
                .font(.system(size: 13, weight: .semibold))
                .foregroundColor(voiceMode ? AppTheme.userBubbleText : AppTheme.secondaryText)
                .frame(width: 30, height: 30)
                .background(Circle().fill(voiceMode ? AppTheme.accent : AppTheme.surface))
                .overlay(
                    Circle().stroke(AppTheme.border.opacity(0.5), lineWidth: 0.5)
                )
        }
        .buttonStyle(BounceButtonStyle())
    }

    /// 文本框（无外框，由容器提供背景）
    private var textFieldInner: some View {
        TextField("输入消息…", text: $text, axis: .vertical)
            .focused($isFocused)
            .font(.system(size: 13))
            .foregroundColor(AppTheme.primaryText)
            .lineLimit(1...3)
            .frame(minHeight: 26, maxHeight: 38)
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

    /// 长按语音输入内容（Apple Speech 公开框架，端侧识别），位于输入框内
    private var holdToTalkInner: some View {
        HStack(spacing: 8) {
            Image(systemName: SpeechRecognizer.shared.isRecording ? "waveform" : "mic.fill")
                .font(.system(size: 14))
                .foregroundColor(SpeechRecognizer.shared.isRecording ? AppTheme.error : AppTheme.accent)
            Text(SpeechRecognizer.shared.isRecording ? "正在聆听…松开发送" : "按住 说话")
                .font(.system(size: 14, weight: .medium))
                .foregroundColor(AppTheme.primaryText)
            Spacer()
        }
        .frame(maxWidth: .infinity)
        .frame(height: 36)
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

    private var sendButton: some View {
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

    private var canSend: Bool {
        !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty && !isGenerating
    }
}
