import SwiftUI

struct ChatView: View {
    @EnvironmentObject var chatVM: ChatViewModel
    @EnvironmentObject var settingsVM: SettingsViewModel
    @EnvironmentObject var modelManager: LocalModelManager
    @EnvironmentObject var store: ConversationStore

    @State private var showClearAlert = false
    @State private var showPDFShare = false
    @State private var showConversations = false
    @State private var pdfURL: URL?

    // 语音输入开关
    @State private var voiceMode: Bool = false
    // 多选删除模式
    @State private var selectionMode: Bool = false
    @State private var selectedIDs: Set<UUID> = []

    private var activeModel: LocalModel? {
        guard let id = modelManager.activeModelId else { return nil }
        return LocalModelCatalog.find(id: id)
    }

    private var messages: [ChatMessage] {
        store.current?.messages ?? []
    }

    var body: some View {
        ZStack {
            AmbientBackground()

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
                if store.currentMode == .online {
                    deepThinkingBar
                }
                if selectionMode {
                    selectionBar
                }
                InputBar(text: $chatVM.inputText, voiceMode: $voiceMode,
                         isGenerating: chatVM.isGenerating,
                         onSend: { chatVM.send(settings: settingsVM.settings, activeModel: activeModel) },
                         onVoiceError: { chatVM.errorMessage = $0 })
            }
        }
        .navigationBarHidden(true)
        .sheet(isPresented: $showConversations) {
            ConversationListView(isPresented: $showConversations)
                .environmentObject(store)
        }
        .sheet(isPresented: $showPDFShare) {
            if let url = pdfURL {
                ShareSheet(items: [url])
            }
        }
        .alert("清空对话", isPresented: $showClearAlert) {
            Button("取消", role: .cancel) {}
            Button("清空", role: .destructive) { chatVM.clearMessages() }
        } message: {
            Text("确定要清空当前对话的全部记录吗？此操作不可撤销。")
        }
    }

    // MARK: - Top Bar
    private var topBar: some View {
        HStack(spacing: 10) {
            // 对话列表
            Button {
                withAnimation(.spring(response: 0.4, dampingFraction: 0.8)) {
                    showConversations = true
                }
            } label: {
                Image(systemName: "line.3.horizontal")
                    .font(.system(size: 16, weight: .semibold))
                    .foregroundColor(AppTheme.secondaryText)
                    .frame(width: 38, height: 38)
                    .background(Circle().fill(AppTheme.surface))
            }
            .buttonStyle(BounceButtonStyle())

            ModeSwitcher(mode: Binding(
                get: { store.current?.mode ?? .online },
                set: { chatVM.setMode($0) }
            ))
            .frame(maxWidth: 240)

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
                    if messages.isEmpty {
                        emptyState
                    }
                    ForEach(messages) { msg in
                        MessageBubble(
                            message: msg,
                            isSelectionMode: selectionMode,
                            isSelected: selectedIDs.contains(msg.id)
                        ) {
                            toggleSelect(msg.id)
                        } onDeleteRequested: {
                            enterSelectionMode(preselect: msg.id)
                        }
                        .id(msg.id)
                    }
                }
                .padding(.vertical, 12)
            }
            .scrollDismissesKeyboard(.immediately)
            .onAppear {
                // 打开 App 自动滑到最近对话最底部
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.15) {
                    scrollToBottom(proxy)
                }
            }
            .onChange(of: messages.count) { _ in
                scrollToBottom(proxy)
            }
            .onChange(of: messages.last?.content) { _ in
                scrollToBottom(proxy)
            }
        }
    }

    private func scrollToBottom(_ proxy: ScrollViewProxy) {
        guard let last = messages.last else { return }
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
            Text(store.currentMode == .online ? "开始你的 AI 对话" : "离线模式已就绪")
                .font(.system(size: 18, weight: .semibold))
                .foregroundColor(AppTheme.primaryText)
            Text(store.currentMode == .online
                 ? "支持联网搜索、图片生成、天气、网页摘要等能力"
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

    // MARK: - Deep Thinking + 联网功能开关
    private var deepThinkingBar: some View {
        HStack(spacing: 8) {
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

            Button {
                settingsVM.settings.onlineFeaturesEnabled.toggle()
                settingsVM.save()
            } label: {
                HStack(spacing: 6) {
                    Image(systemName: settingsVM.settings.onlineFeaturesEnabled ? "network" : "network.slash")
                        .font(.system(size: 12, weight: .semibold))
                    Text("联网功能")
                        .font(.system(size: 12, weight: .medium))
                }
                .foregroundColor(settingsVM.settings.onlineFeaturesEnabled ? AppTheme.accent : AppTheme.secondaryText)
                .padding(.horizontal, 12)
                .padding(.vertical, 6)
                .background(settingsVM.settings.onlineFeaturesEnabled ? AppTheme.accent.opacity(0.16) : AppTheme.surface)
                .clipShape(Capsule())
                .overlay(Capsule().stroke(AppTheme.border.opacity(0.5), lineWidth: 0.5))
            }
            .buttonStyle(BounceButtonStyle())

            Spacer()
        }
        .padding(.horizontal, 16)
        .padding(.top, 6)
        .padding(.bottom, 4)
    }

    // MARK: - 多选删除工具条
    private var selectionBar: some View {
        HStack(spacing: 10) {
            Button {
                withAnimation(.easeInOut(duration: 0.2)) {
                    selectionMode = false
                    selectedIDs.removeAll()
                }
            } label: {
                Text("取消")
                    .font(.system(size: 14, weight: .medium))
                    .foregroundColor(AppTheme.secondaryText)
            }
            Spacer()
            Text("已选 \(selectedIDs.count) 条")
                .font(.system(size: 13))
                .foregroundColor(AppTheme.secondaryText)
            Button {
                withAnimation(.spring(response: 0.35, dampingFraction: 0.8)) {
                    chatVM.deleteMessages(ids: selectedIDs)
                    selectionMode = false
                    selectedIDs.removeAll()
                }
            } label: {
                Text("删除")
                    .font(.system(size: 14, weight: .semibold))
                    .foregroundColor(.white)
                    .padding(.horizontal, 18)
                    .padding(.vertical, 8)
                    .background(AppTheme.error)
                    .clipShape(Capsule())
            }
            .disabled(selectedIDs.isEmpty)
            .opacity(selectedIDs.isEmpty ? 0.5 : 1)
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 8)
        .background(AppTheme.surface.opacity(0.9))
    }

    // MARK: - 多选逻辑
    private func toggleSelect(_ id: UUID) {
        if selectedIDs.contains(id) {
            selectedIDs.remove(id)
        } else {
            selectedIDs.insert(id)
        }
    }

    private func enterSelectionMode(preselect: UUID? = nil) {
        withAnimation(.easeInOut(duration: 0.2)) {
            selectionMode = true
            selectedIDs = preselect.map { [$0] } ?? []
        }
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
