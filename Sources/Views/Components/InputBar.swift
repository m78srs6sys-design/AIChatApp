import SwiftUI

/// 底部自适应高度输入栏（紧凑版，语音开关为框内圆形按钮）
struct InputBar: View {
    @Binding var text: String
    @Binding var voiceMode: Bool
    let isGenerating: Bool
    let onSend: () -> Void
    /// 强制终止生成的回调
    var onStop: (() -> Void)? = nil
    /// 语音识别出错时回调（用于弹出错误提示）
    var onVoiceError: ((String) -> Void)? = nil

    @FocusState private var isFocused: Bool

    /// 长按录音的瞬时状态（由手势 .updating 维护，松手后自动复位）
    private struct HoldState { var active: Bool = false; var cancel: Bool = false }
    @GestureState private var hold = HoldState()

    private let minHeight: CGFloat = 38
    private let maxHeight: CGFloat = 46
    /// 上滑超过该距离（向上为负）即判定为取消
    private let cancelThreshold: CGFloat = -60

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

    /// 长按语音输入：长按开始聆听，上滑取消，松开发送为文字
    private var holdToTalkInner: some View {
        let gesture = LongPressGesture(minimumDuration: 0.25)
            .sequenced(before: DragGesture(minimumDistance: 0))
            .updating($hold) { value, state, _ in
                switch value {
                case .first(true):
                    state = HoldState(active: true, cancel: false)
                    let ok = SpeechRecognizer.shared.start()
                    if !ok, let err = SpeechRecognizer.shared.lastError { onVoiceError?(err) }
                case .second(true, let drag):
                    let c = (drag?.translation.height ?? 0) < cancelThreshold
                    state = HoldState(active: true, cancel: c)
                default:
                    break
                }
            }
            .onEnded { value in
                switch value {
                case .second(true, let drag):
                    let cancel = (drag?.translation.height ?? 0) < cancelThreshold
                    if cancel {
                        // 上滑取消：丢弃识别结果
                        SpeechRecognizer.shared.cancel()
                    } else {
                        // 延迟 0.5 秒再停止录音，防止用户话没说完
                        Task { @MainActor in
                            try? await Task.sleep(nanoseconds: 500_000_000)
                            let t = SpeechRecognizer.shared.stop()
                            if !t.isEmpty {
                                let merged = (text + t).trimmingCharacters(in: .whitespacesAndNewlines)
                                text = merged
                                onSend()
                            } else {
                                SpeechRecognizer.shared.stop()
                            }
                        }
                    }
                default:
                    SpeechRecognizer.shared.cancel()
                }
            }

        let iconName = hold.active ? (hold.cancel ? "xmark.circle.fill" : "waveform") : "mic.fill"
        let tint = hold.cancel ? AppTheme.error : (hold.active ? AppTheme.error : AppTheme.accent)
        let label = hold.active ? (hold.cancel ? "松开取消" : "松开发送 · 上滑取消") : "按住 说话"

        return HStack(spacing: 8) {
            Image(systemName: iconName)
                .font(.system(size: 14))
                .foregroundColor(tint)
            Text(label)
                .font(.system(size: 14, weight: .medium))
                .foregroundColor(AppTheme.primaryText)
            Spacer()
        }
        .frame(maxWidth: .infinity)
        .frame(height: 36)
        .background(
            hold.cancel ? AppTheme.error.opacity(0.16) :
            (hold.active ? AppTheme.accent.opacity(0.12) : Color.clear)
        )
        .contentShape(Rectangle())
        .gesture(gesture)
        .onReceive(SpeechRecognizer.shared.$lastError) { err in
            if let err {
                onVoiceError?(err)
                SpeechRecognizer.shared.lastError = nil
            }
        }
    }

    private var sendButton: some View {
        Button(action: {
            if isGenerating {
                onStop?()
            } else {
                onSend()
            }
        }) {
            Image(systemName: isGenerating ? "stop.fill" : "arrow.up")
                .font(.system(size: 13, weight: .bold))
                .foregroundColor(AppTheme.userBubbleText)
                .frame(width: 30, height: 30)
                .background(
                    Circle()
                        .fill(canSend || isGenerating ? AppTheme.accent : AppTheme.surfaceElevated)
                )
                .overlay(
                    Circle().stroke(canSend || isGenerating ? Color.clear : AppTheme.border.opacity(0.5), lineWidth: 0.5)
                )
        }
        .buttonStyle(BounceButtonStyle())
        .disabled(!canSend && !isGenerating)
    }

    private var canSend: Bool {
        !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty && !isGenerating
    }
}
