import SwiftUI

struct ChatView: View {
    @EnvironmentObject var chatVM: ChatViewModel
    @EnvironmentObject var settingsVM: SettingsViewModel
    @EnvironmentObject var modelManager: LocalModelManager

    @State private var showClearAlert = false
    @State private var showPDFShare = false
    @State private var pdfURL: URL?

    private var activeModel: LocalModel? {
        guard let id = modelManager.activeModelId else { return nil }
        return LocalModelCatalog.find(id: id)
    }

    var body: some View {
        ZStack {
            AppTheme.background.ignoresSafeArea()

            VStack(spacing: 0) {
                topBar
                Divider().background(AppTheme.divider)
                messageList
                if let err = chatVM.errorMessage {
                    errorBanner(err)
                }
                if let status = chatVM.statusMessage, chatVM.isGenerating {
                    statusBanner(status)
                }
                if chatVM.mode == .online {
                    deepThinkingBar
                }
                InputBar(text: $chatVM.inputText, isGenerating: chatVM.isGenerating) {
                    chatVM.send(settings: settingsVM.settings, activeModel: activeModel)
                }
            }
        }
        .navigationBarHidden(true)
        .sheet(isPresented: $showPDFShare) {
            if let url = pdfURL {
                ShareSheet(items: [url])
            }
        }
        .alert("清空对话", isPresented: $showClearAlert) {
            Button("取消", role: .cancel) {}
            Button("清空", role: .destructive) { chatVM.clearMessages() }
        } message: {
            Text("确定要清空当前所有对话记录吗？此操作不可撤销。")
        }
    }

    // MARK: - Top Bar
    private var topBar: some View {
        HStack(spacing: 12) {
            ModeSwitcher(mode: Binding(
                get: { chatVM.mode },
                set: { chatVM.switchMode(to: $0) }
            ))
            .frame(maxWidth: 260)

            Spacer()

            // PDF 导出
            Button {
                do {
                    pdfURL = try chatVM.exportPDF()
                    showPDFShare = true
                } catch {
                    chatVM.errorMessage = "无内容可导出"
                }
            } label: {
                Image(systemName: "doc.text.fill")
                    .font(.system(size: 16))
                    .foregroundColor(AppTheme.secondaryText)
                    .frame(width: 38, height: 38)
                    .background(Circle().fill(AppTheme.surface))
            }
            .buttonStyle(BounceButtonStyle())

            // 清空
            Button {
                showClearAlert = true
            } label: {
                Image(systemName: "trash.fill")
                    .font(.system(size: 15))
                    .foregroundColor(AppTheme.secondaryText)
                    .frame(width: 38, height: 38)
                    .background(Circle().fill(AppTheme.surface))
            }
            .buttonStyle(BounceButtonStyle())

            // 设置
            NavigationLink(value: AppRoute.settings) {
                Image(systemName: "gearshape.fill")
                    .font(.system(size: 16))
                    .foregroundColor(AppTheme.secondaryText)
                    .frame(width: 38, height: 38)
                    .background(Circle().fill(AppTheme.surface))
            }
            .buttonStyle(BounceButtonStyle())
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 10)
        .background(AppTheme.background)
    }

    // MARK: - Message List
    private var messageList: some View {
        ScrollViewReader { proxy in
            ScrollView {
                LazyVStack(spacing: 4) {
                    if chatVM.messages.isEmpty {
                        emptyState
                    }
                    ForEach(chatVM.messages) { msg in
                        MessageBubble(message: msg)
                            .id(msg.id)
                    }
                }
                .padding(.vertical, 12)
            }
            .scrollDismissesKeyboard(.immediately)
            .onChange(of: chatVM.messages.count) { _ in
                scrollToBottom(proxy)
            }
            .onChange(of: chatVM.messages.last?.content) { _ in
                scrollToBottom(proxy)
            }
        }
    }

    private func scrollToBottom(_ proxy: ScrollViewProxy) {
        guard let last = chatVM.messages.last else { return }
        withAnimation(.easeOut(duration: 0.2)) {
            proxy.scrollTo(last.id, anchor: .bottom)
        }
    }

    // MARK: - Empty State
    private var emptyState: some View {
        VStack(spacing: 16) {
            ZStack {
                Circle()
                    .fill(AppTheme.accent.opacity(0.12))
                    .frame(width: 88, height: 88)
                Image(systemName: "sparkles")
                    .font(.system(size: 36, weight: .light))
                    .foregroundColor(AppTheme.accent)
            }
            Text(chatVM.mode == .online ? "开始你的 AI 对话" : "离线模式已就绪")
                .font(.system(size: 18, weight: .semibold))
                .foregroundColor(AppTheme.primaryText)
            Text(chatVM.mode == .online
                 ? "支持联网搜索、图片生成、语音合成等能力"
                 : "所有推理在本地完成，隐私无忧")
                .font(.system(size: 14))
                .foregroundColor(AppTheme.secondaryText)
                .multilineTextAlignment(.center)
                .padding(.horizontal, 40)
        }
        .padding(.top, 80)
    }

    // MARK: - Status Banner
    private func statusBanner(_ message: String) -> some View {
        HStack(spacing: 8) {
            ProgressView()
                .tint(AppTheme.accent)
                .scaleEffect(0.8)
            Text(message)
                .font(.system(size: 13))
                .foregroundColor(AppTheme.secondaryText)
            Spacer()
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 8)
        .background(AppTheme.surface.opacity(0.6))
    }

    // MARK: - Deep Thinking Bar
    private var deepThinkingBar: some View {
        HStack {
            Button {
                settingsVM.settings.deepThinking.toggle()
                settingsVM.save()
            } label: {
                HStack(spacing: 6) {
                    Image(systemName: settingsVM.settings.deepThinking ? "brain.fill" : "brain")
                        .font(.system(size: 12, weight: .semibold))
                    Text("深度思考")
                        .font(.system(size: 12, weight: .medium))
                }
                .foregroundColor(settingsVM.settings.deepThinking ? AppTheme.accent : AppTheme.secondaryText)
                .padding(.horizontal, 12)
                .padding(.vertical, 6)
                .background(settingsVM.settings.deepThinking ? AppTheme.accent.opacity(0.16) : AppTheme.surface)
                .clipShape(Capsule())
                .overlay(Capsule().stroke(AppTheme.border.opacity(0.5), lineWidth: 0.5))
            }
            .buttonStyle(BounceButtonStyle())

            Spacer()
        }
        .padding(.horizontal, 16)
        .padding(.top, 8)
        .padding(.bottom, 2)
    }

    // MARK: - Error Banner
    private func errorBanner(_ message: String) -> some View {
        HStack(spacing: 8) {
            Image(systemName: "exclamationmark.triangle.fill")
                .foregroundColor(AppTheme.error)
            Text(message)
                .font(.system(size: 13))
                .foregroundColor(AppTheme.primaryText)
            Spacer()
            Button {
                chatVM.errorMessage = nil
            } label: {
                Image(systemName: "xmark.circle.fill")
                    .foregroundColor(AppTheme.secondaryText)
            }
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 10)
        .background(AppTheme.error.opacity(0.15))
    }
}

/// 系统分享面板
struct ShareSheet: UIViewControllerRepresentable {
    let items: [Any]
    func makeUIViewController(context: Context) -> UIActivityViewController {
        UIActivityViewController(activityItems: items, applicationActivities: nil)
    }
    func updateUIViewController(_ uiViewController: UIActivityViewController, context: Context) {}
}