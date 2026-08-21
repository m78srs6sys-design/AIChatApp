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
    @State private var isExportingPDF = false
    @State private var pdfProgress: Double = 0

    // 语音输入开关
    @State private var voiceMode: Bool = false
    // 多选删除模式
    @State private var selectionMode: Bool = false
    @State private var selectedIDs: Set<UUID> = []
    // 自动滚动防重入：流式输出时避免每个 token 都触发 scrollTo 造成更新期重入崩溃
    @State private var autoScrollBusy = false
    // 生成时可手动滚动：记录用户是否停在底部；一旦用户上滑离开底部，自动滚动暂停，回到底部后恢复跟随
    @State private var bottomHintY: CGFloat = 0
    @State private var viewportHeight: CGFloat = 0

    private var activeModel: LocalModel? {
        guard let id = modelManager.activeModelId else { return nil }
        return LocalModelCatalog.find(id: id)
            ?? modelManager.remoteModels.first(where: { $0.id == id })
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
                         onStop: { chatVM.stopGeneration() },
                         onVoiceError: { chatVM.errorMessage = $0 })
            }
            // PDF 导出进度浮层
            if isExportingPDF {
                Color.black.opacity(0.35)
                    .ignoresSafeArea()
                    .transition(.opacity)
                VStack(spacing: 12) {
                    ProgressView(value: pdfProgress, total: 1.0)
                        .progressViewStyle(LinearProgressViewStyle(tint: AppTheme.accent))
                        .frame(width: 160)
                    Text("正在生成 PDF…\(Int(pdfProgress * 100))%")
                        .font(.system(size: 14, weight: .medium))
                        .foregroundColor(AppTheme.primaryText)
                }
                .padding(20)
                .glassify(fallback: AppTheme.surfaceElevated, radius: 16, enabled: settingsVM.settings.liquidGlassEnabled)
                .transition(.scale(scale: 0.9).combined(with: .opacity))
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
        // 系统操作许可弹窗：AI 调用「系统操作」工具（传感器/打开App/调亮度等）前必须征得用户同意
        .alert("允许这个系统操作吗？", isPresented: Binding(
            get: { chatVM.systemPermissionRequest != nil },
            set: { if !$0 && chatVM.systemPermissionRequest != nil { chatVM.respondToPermission(granted: false) } }
        ), presenting: chatVM.systemPermissionRequest) { request in
            Button("不许可", role: .cancel) { chatVM.respondToPermission(granted: false) }
            Button("允许") { chatVM.respondToPermission(granted: true) }
        } message: { request in
            Text("AI 想要：\(request.explanation)\n\n是否允许它执行这个操作？")
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
                    .glassCircle(fallback: AppTheme.surface, enabled: settingsVM.settings.liquidGlassEnabled)
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
                guard !isExportingPDF else { return }
                Task {
                    isExportingPDF = true
                    pdfProgress = 0
                    chatVM.statusMessage = "正在生成 PDF…"
                    do {
                        pdfURL = try await chatVM.exportPDF { progress in
                            pdfProgress = progress
                        }
                        chatVM.statusMessage = nil
                        showPDFShare = true
                    } catch {
                        chatVM.statusMessage = nil
                        chatVM.errorMessage = "无内容可导出"
                    }
                    isExportingPDF = false
                }
            } label: {
                Image(systemName: isExportingPDF ? "doc.text.fill" : "doc.text.fill")
                    .font(.system(size: 16))
                    .foregroundColor(AppTheme.secondaryText)
                    .frame(width: 38, height: 38)
                    .glassCircle(fallback: AppTheme.surface, enabled: settingsVM.settings.liquidGlassEnabled)
            }
            .disabled(isExportingPDF)
            .buttonStyle(BounceButtonStyle())

            // 清空
            Button {
                showClearAlert = true
            } label: {
                Image(systemName: "trash.fill")
                    .font(.system(size: 15))
                    .foregroundColor(AppTheme.secondaryText)
                    .frame(width: 38, height: 38)
                    .glassCircle(fallback: AppTheme.surface, enabled: settingsVM.settings.liquidGlassEnabled)
            }
            .buttonStyle(BounceButtonStyle())

            // 设置
            NavigationLink(value: AppRoute.settings) {
                Image(systemName: "gearshape.fill")
                    .font(.system(size: 16))
                    .foregroundColor(AppTheme.secondaryText)
                    .frame(width: 38, height: 38)
                    .glassCircle(fallback: AppTheme.surface, enabled: settingsVM.settings.liquidGlassEnabled)
            }
            .buttonStyle(BounceButtonStyle())
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 10)
        .background {
            if settingsVM.settings.liquidGlassEnabled {
                AppTheme.background
            } else {
                AppTheme.background
            }
        }
    }

    // MARK: - Message List
    private var messageList: some View {
        GeometryReader { geo in
            ScrollViewReader { proxy in
                ZStack(alignment: .bottomTrailing) {
                    ScrollView {
                        LazyVStack(spacing: 4) {
                            // 顶部锚点：悬浮「回到顶部」按钮跳转目标（多条消息时列表可能很长）
                            Color.clear.frame(height: 1).id("topAnchor")
                            if messages.isEmpty {
                                emptyState
                            }
                            ForEach(messages) { msg in
                                bubble(for: msg)
                                    .id(msg.id)
                            }
                            // 底部锚点：用于检测当前是否停在底部（决定自动滚动是否跟随）
                            Color.clear.frame(height: 1)
                                .id("bottomHint")
                                .background(
                                    GeometryReader { pin in
                                        Color.clear.preference(
                                            key: BottomHintYPreferenceKey.self,
                                            value: pin.frame(in: .named("chatScroll")).minY
                                        )
                                    }
                                )
                        }
                        .padding(.vertical, 12)
                    }
                    .scrollDismissesKeyboard(.immediately)
                    // 悬浮「回到顶部」按钮：仅当用户离开底部时出现
                    topFloatButton(proxy)
                }
                .coordinateSpace(name: "chatScroll")
                .onPreferenceChange(BottomHintYPreferenceKey.self) { bottomHintY = $0 }
                .onAppear {
                    viewportHeight = geo.size.height
                    // 打开 App 自动滑到最近对话最底部
                    DispatchQueue.main.asyncAfter(deadline: .now() + 0.15) {
                        scrollToBottom(proxy)
                    }
                }
                .onChange(of: geo.size.height) { _ in
                    viewportHeight = geo.size.height
                }
                .onChange(of: messages.count) { _ in
                    // 用户已经手动翻到上面时，不强制跳底（允许生成过程中自由浏览）
                    if isAtBottom { scrollToBottom(proxy) }
                }
                .onChange(of: messages.last?.content) { _ in
                    if isAtBottom { scrollToBottom(proxy) }
                }
            }
        }
    }

    /// 当前视口是否停在底部：底部锚点顶部进入视口底部 20pt 内即认为在底部。
    /// viewportHeight 尚未拿到时（初次布局）默认视为底部，避免首屏自动滚动被误吞。
    private var isAtBottom: Bool {
        guard viewportHeight > 0 else { return true }
        return bottomHintY <= viewportHeight + 20
    }

    /// 悬浮「回到顶部」按钮（右下角）
    private func topFloatButton(_ proxy: ScrollViewProxy) -> some View {
        Group {
            if !isAtBottom && !messages.isEmpty && !selectionMode {
                Button {
                    withAnimation(.easeOut(duration: 0.28)) {
                        proxy.scrollTo("topAnchor", anchor: .top)
                    }
                } label: {
                    Image(systemName: "arrow.up")
                        .font(.system(size: 16, weight: .semibold))
                        .foregroundColor(AppTheme.primaryText)
                        .frame(width: 42, height: 42)
                        .background(AppTheme.surfaceElevated)
                        .clipShape(Circle())
                        .overlay(
                            Circle().strokeBorder(AppTheme.divider.opacity(0.6), lineWidth: 1)
                        )
                        .shadow(color: Color.black.opacity(0.18), radius: 10, x: 0, y: 3)
                }
                .buttonStyle(BounceButtonStyle())
                .transition(.scale(scale: 0.7).combined(with: .opacity))
                .padding(.trailing, 14)
                .padding(.bottom, 12)
            }
        }
        .animation(.spring(response: 0.3, dampingFraction: 0.8), value: isAtBottom)
    }

    private func scrollToBottom(_ proxy: ScrollViewProxy) {
        guard let last = messages.last, !autoScrollBusy else { return }
        autoScrollBusy = true
        withAnimation(.easeOut(duration: 0.2)) {
            proxy.scrollTo(last.id, anchor: .bottom)
        }
        // 防重入：短时间内合并多次滚动请求，避免更新期递归
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.25) {
            autoScrollBusy = false
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
        .glassify(fallback: AppTheme.surface.opacity(0.6), radius: 12, enabled: settingsVM.settings.liquidGlassEnabled)
    }

    // MARK: - Deep Thinking + 联网附加开关
    private var deepThinkingBar: some View {
        HStack(spacing: 8) {
            Button {
                settingsVM.settings.deepThinking.toggle()
                // 深度思考关闭时，强制关闭联网附加
                if !settingsVM.settings.deepThinking {
                    settingsVM.settings.onlineFeaturesEnabled = false
                }
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
                .glassify(fallback: (settingsVM.settings.deepThinking ? AppTheme.accent.opacity(0.16) : AppTheme.surface), radius: 999, enabled: settingsVM.settings.liquidGlassEnabled)
                .clipShape(Capsule())
            }
            .buttonStyle(BounceButtonStyle())

            // 联网附加：仅当深度思考开启时才可操作
            Button {
                guard settingsVM.settings.deepThinking else { return }
                settingsVM.settings.onlineFeaturesEnabled.toggle()
                settingsVM.save()
            } label: {
                HStack(spacing: 6) {
                    Image(systemName: settingsVM.settings.onlineFeaturesEnabled ? "network" : "network.slash")
                        .font(.system(size: 12, weight: .semibold))
                    Text("联网附加")
                        .font(.system(size: 12, weight: .medium))
                }
                .foregroundColor(settingsVM.settings.onlineFeaturesEnabled ? AppTheme.accent : AppTheme.secondaryText)
                .padding(.horizontal, 12)
                .padding(.vertical, 6)
                .glassify(fallback: (settingsVM.settings.onlineFeaturesEnabled ? AppTheme.accent.opacity(0.16) : AppTheme.surface), radius: 999, enabled: settingsVM.settings.liquidGlassEnabled)
                .clipShape(Capsule())
                .opacity(settingsVM.settings.deepThinking ? 1.0 : 0.5)
            }
            .buttonStyle(BounceButtonStyle())
            .disabled(!settingsVM.settings.deepThinking)

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
        .glassify(fallback: AppTheme.surface.opacity(0.9), radius: 14, enabled: settingsVM.settings.liquidGlassEnabled)
    }

    // MARK: - 多选逻辑
    private func toggleSelect(_ id: UUID) {
        if selectedIDs.contains(id) {
            selectedIDs.remove(id)
        } else {
            selectedIDs.insert(id)
        }
    }

    /// 构建单条消息气泡（独立函数避免类型推断超时）
    private func bubble(for msg: ChatMessage) -> MessageBubble {
        let canRegenerate = msg.role == .assistant && msg.id == messages.last?.id
        let regen: (() -> Void)? = canRegenerate ? {
            chatVM.regenerateLast(settings: settingsVM.settings, activeModel: activeModel)
        } : nil
        return MessageBubble(
            message: msg,
            isSelectionMode: selectionMode,
            isSelected: selectedIDs.contains(msg.id),
            onSelect: { toggleSelect(msg.id) },
            onDeleteRequested: { enterSelectionMode(preselect: msg.id) },
            onRegenerate: regen
        )
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

/// 上报底部锚点在「chatScroll」坐标系中的 minY，用于判断用户是否停留在对话底部。
/// 只在滚动位置变化时更新一次（只读，无副作用）。
private struct BottomHintYPreferenceKey: PreferenceKey {
    static var defaultValue: CGFloat = .greatestFiniteMagnitude
    static func reduce(value: inout CGFloat, nextValue: () -> CGFloat) {
        value = nextValue()
    }
}
