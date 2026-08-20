import SwiftUI
import UIKit
import WebKit

/// 单条消息气泡：用户(右·亮色) / AI(左·深色磨砂)
struct MessageBubble: View {
    let message: ChatMessage
    @EnvironmentObject private var chatVM: ChatViewModel
    @EnvironmentObject private var settingsVM: SettingsViewModel
    /// 朗读服务（单例，用于实时反映播放状态）
    @ObservedObject private var speech = SpeechService.shared

    // 多选删除支持
    var isSelectionMode: Bool = false
    var isSelected: Bool = false
    var onSelect: (() -> Void)? = nil
    var onDeleteRequested: (() -> Void)? = nil
    /// 重新生成该回复（大厂标配交互，仅最后一条 AI 消息可用）
    var onRegenerate: (() -> Void)? = nil

    @State private var showReasoning: Bool = false

    /// 当前这条消息是否正在被朗读
    private var isThisSpeaking: Bool {
        speech.isSpeakingNow && speech.speakingText == message.content
    }

    var body: some View {
        HStack(alignment: .top, spacing: 8) {
            // 多选模式：前导勾选圈
            if isSelectionMode {
                selectionCircle
                    .onTapGesture { onSelect?() }
            }

            HStack(alignment: .top, spacing: 10) {
                if message.role == .user {
                    Spacer(minLength: 48)
                } else {
                    // AI 头像
                    ZStack {
                        Circle()
                            .fill(AppTheme.accent.opacity(0.15))
                        Image(systemName: "sparkles")
                            .font(.system(size: 16, weight: .semibold))
                            .foregroundColor(AppTheme.accent)
                    }
                    .frame(width: 36, height: 36)
                }

                VStack(alignment: message.role == .user ? .trailing : .leading, spacing: 6) {
                    // 深度思考过程（可展开/收起的小字）
                    if message.role == .assistant, !message.reasoning.isEmpty {
                        reasoningView
                    }
                    bubbleContent
                    attachmentViews

                    // 常驻朗读按钮（AI 消息）：一眼可见、点按即读，避免长按菜单「没反应」的误解
                    if message.role == .assistant, !message.content.isEmpty {
                        HStack(spacing: 6) {
                            Button {
                                if speech.isSpeakingNow {
                                    speech.stop()
                                } else {
                                    speech.speak(message.content)
                                }
                            } label: {
                                Image(systemName: isThisSpeaking ? "speaker.wave.2.fill" : "speaker.wave.2")
                                    .font(.system(size: 13, weight: .medium))
                                    .foregroundColor(isThisSpeaking ? AppTheme.accent : AppTheme.secondaryText)
                                    .frame(width: 30, height: 30)
                                    .background(Circle().fill(AppTheme.surfaceElevated.opacity(0.85)))
                                    .overlay(Circle().stroke(AppTheme.border.opacity(0.5), lineWidth: 0.5))
                            }
                            .buttonStyle(BounceButtonStyle())
                            Text(isThisSpeaking ? "停止朗读" : "朗读内容")
                                .font(.system(size: 12, weight: .medium))
                                .foregroundColor(isThisSpeaking ? AppTheme.accent : AppTheme.secondaryText)
                        }
                        .padding(.top, 2)
                        .frame(maxWidth: .infinity, alignment: .leading)
                    }
                }

                if message.role == .assistant {
                    Spacer(minLength: 48)
                }
            }
        }
        .padding(.horizontal, 0)
        .contentShape(Rectangle())
        .onTapGesture {
            if isSelectionMode { onSelect?() }
        }
        .contextMenu {
            if !isSelectionMode {
                if !message.content.isEmpty {
                    Button {
                        UIPasteboard.general.string = message.content
                    } label: {
                        Label("复制内容", systemImage: "doc.on.doc")
                    }
                    // 朗读 / 停止朗读（大厂 AI 应用标配）
                    Button {
                        if SpeechService.shared.isSpeakingNow {
                            SpeechService.shared.stop()
                        } else {
                            SpeechService.shared.speak(message.content)
                        }
                    } label: {
                        Label(SpeechService.shared.isSpeakingNow && SpeechService.shared.speakingText == message.content ? "停止朗读" : "朗读内容",
                              systemImage: "speaker.wave.2")
                    }
                    // 重新生成回复（仅最后一条 AI 消息）
                    if message.role == .assistant, let onRegenerate {
                        Button {
                            onRegenerate()
                        } label: {
                            Label("重新生成", systemImage: "arrow.clockwise")
                        }
                    }
                }
                Button(role: .destructive) {
                    onDeleteRequested?()
                } label: {
                    Label("删除此消息", systemImage: "trash")
                }
            }
        }
        .transition(.asymmetric(
            insertion: .scale(scale: 0.96, anchor: message.role == .user ? .trailing : .leading)
                .combined(with: .opacity),
            removal: .scale(scale: 0.6)
                .combined(with: .opacity)
                .combined(with: .move(edge: message.role == .user ? .trailing : .leading))
        ))
    }

    private var selectionCircle: some View {
        ZStack {
            Circle()
                .fill(isSelected ? AppTheme.accent : Color.clear)
                .frame(width: 24, height: 24)
                .overlay(
                    Circle().stroke(isSelected ? AppTheme.accent : AppTheme.secondaryText, lineWidth: 2)
                )
            if isSelected {
                Image(systemName: "checkmark")
                    .font(.system(size: 12, weight: .bold))
                    .foregroundColor(.white)
            }
        }
        .padding(.top, 14)
    }

    /// 深度思考过程：可展开/收起的小字
    private var reasoningView: some View {
        VStack(alignment: .leading, spacing: 4) {
            Button {
                withAnimation(.easeInOut(duration: 0.2)) { showReasoning.toggle() }
            } label: {
                HStack(spacing: 4) {
                    Image(systemName: "brain")
                        .font(.system(size: 11, weight: .semibold))
                    Text("深度思考过程")
                        .font(.system(size: 11, weight: .medium))
                    Image(systemName: showReasoning ? "chevron.up" : "chevron.down")
                        .font(.system(size: 9))
                }
                .foregroundColor(AppTheme.accentSoft)
            }
            if showReasoning {
                Text(message.reasoning)
                    .font(.system(size: 12))
                    .foregroundColor(AppTheme.tertiaryText)
                    .multilineTextAlignment(.leading)
                    .fixedSize(horizontal: false, vertical: true)
                    .padding(8)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .background(AppTheme.surface.opacity(0.6))
                    .clipShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
            }
        }
    }

    @ViewBuilder
    private var bubbleContent: some View {
        if message.role == .user {
            Text(message.content)
                .font(.system(size: 16))
                .foregroundColor(AppTheme.userBubbleText)
                .padding(.horizontal, 18)
                .padding(.vertical, 12)
                .background {
                    if settingsVM.settings.liquidGlassEnabled {
                        LiquidGlassBackdrop(radius: AppTheme.bubbleRadius, material: .thinMaterial)
                    } else {
                        AppTheme.userBubble
                    }
                }
                .clipShape(RoundedRectangle(cornerRadius: AppTheme.bubbleRadius, style: .continuous))
                .shadow(color: .black.opacity(0.15), radius: 6, x: 0, y: 3)
        } else {
            HStack(alignment: .bottom, spacing: 2) {
                if message.content.isEmpty && message.isStreaming {
                    HStack(spacing: 8) {
                        ShimmerView()
                            .frame(width: 26, height: 26)
                            .clipShape(Circle())
                        HStack(spacing: 4) {
                            ForEach(0..<3, id: \.self) { i in
                                DotPulse(delay: Double(i) * 0.2)
                            }
                        }
                    }
                    .padding(.horizontal, 18)
                    .padding(.vertical, 14)
                } else {
                    // AI 消息：支持 Markdown 渲染（加粗/斜体/行内代码/链接），解析失败回退纯文本
                    if let attr = try? AttributedString(
                        markdown: message.content,
                        options: .init(interpretedSyntax: .inlineOnlyPreservingWhitespace)
                    ) {
                        Text(attr)
                            .font(.system(size: 16))
                            .foregroundColor(AppTheme.aiBubbleText)
                            .multilineTextAlignment(.leading)
                            .padding(.horizontal, 18)
                            .padding(.vertical, 12)
                    } else {
                        Text(message.content)
                            .font(.system(size: 16))
                            .foregroundColor(AppTheme.aiBubbleText)
                            .multilineTextAlignment(.leading)
                            .padding(.horizontal, 18)
                            .padding(.vertical, 12)
                    }
                }
                if message.isStreaming && !message.content.isEmpty {
                    TypingCursor()
                        .padding(.bottom, 14)
                }
            }
            .background {
                if settingsVM.settings.liquidGlassEnabled {
                    LiquidGlassBackdrop(radius: AppTheme.bubbleRadius, material: .regularMaterial)
                } else {
                    RoundedRectangle(cornerRadius: AppTheme.bubbleRadius, style: .continuous)
                        .fill(.ultraThinMaterial)
                        .overlay(
                            RoundedRectangle(cornerRadius: AppTheme.bubbleRadius, style: .continuous)
                                .fill(AppTheme.aiBubble.opacity(0.85))
                        )
                }
            }
            .overlay {
                if !settingsVM.settings.liquidGlassEnabled {
                    RoundedRectangle(cornerRadius: AppTheme.bubbleRadius, style: .continuous)
                        .stroke(AppTheme.border.opacity(0.5), lineWidth: 0.5)
                }
            }
        }
    }

    @ViewBuilder
    private var attachmentViews: some View {
        ForEach(Array(message.attachments.enumerated()), id: \.offset) { _, attachment in
            AttachmentView(attachment: attachment)
        }
    }
}

/// 附件展示（图片 / 定位 / 搜索结果 / 天气 / 网页）
struct AttachmentView: View {
    let attachment: MessageAttachment
    /// HTML 卡片内容高度（由 WebView 内 JS 测量后回调，实现自适应）
    @State private var cardHeight: CGFloat = 140
    /// 图片全屏预览
    @State private var showImagePreview = false

    var body: some View {
        attachmentContent
            .fullScreenCover(isPresented: $showImagePreview) {
                if case .image(let url) = attachment {
                    FullScreenImageViewer(urlString: url, isPresented: $showImagePreview)
                }
            }
    }

    @ViewBuilder
    private var attachmentContent: some View {
        switch attachment {
        case .image(let url):
            AsyncImage(url: URL(string: url)) { phase in
                switch phase {
                case .empty:
                    RoundedRectangle(cornerRadius: AppTheme.cardRadius, style: .continuous)
                        .fill(AppTheme.surfaceElevated)
                        .frame(height: 200)
                        .overlay(ProgressView())
                case .success(let image):
                    image
                        .resizable()
                        .scaledToFill()
                        .frame(maxWidth: 260)
                        .frame(height: 200)
                        .clipped()
                        .clipShape(RoundedRectangle(cornerRadius: AppTheme.cardRadius, style: .continuous))
                case .failure:
                    Text("图片加载失败")
                        .font(.caption)
                        .foregroundColor(AppTheme.secondaryText)
                @unknown default:
                    EmptyView()
                }
            }
            .onTapGesture { showImagePreview = true }
        case .location(let lat, let lon, let name):
            VStack(alignment: .leading, spacing: 6) {
                HStack {
                    Image(systemName: "mappin.and.ellipse")
                        .foregroundColor(AppTheme.accent)
                    Text(name.isEmpty ? "当前位置" : name)
                        .font(.system(size: 14, weight: .medium))
                        .foregroundColor(AppTheme.primaryText)
                }
                Text(String(format: "%.4f, %.4f", lat, lon))
                    .font(.system(size: 12))
                    .foregroundColor(AppTheme.secondaryText)
            }
            .padding(14)
            .background(AppTheme.surfaceElevated)
            .clipShape(RoundedRectangle(cornerRadius: AppTheme.cardRadius, style: .continuous))
        case .searchResults(let items):
            VStack(alignment: .leading, spacing: 8) {
                HStack {
                    Image(systemName: "magnifyingglass")
                        .foregroundColor(AppTheme.accent)
                    Text("网络搜索结果")
                        .font(.system(size: 13, weight: .semibold))
                        .foregroundColor(AppTheme.primaryText)
                }
                ForEach(Array(items.prefix(3).enumerated()), id: \.offset) { _, item in
                    VStack(alignment: .leading, spacing: 2) {
                        Text(item.title)
                            .font(.system(size: 13, weight: .medium))
                            .foregroundColor(AppTheme.accentSoft)
                            .lineLimit(1)
                        if let snippet = item.snippet {
                            Text(snippet)
                                .font(.system(size: 12))
                                .foregroundColor(AppTheme.secondaryText)
                                .lineLimit(2)
                        }
                    }
                }
            }
            .padding(14)
            .background(AppTheme.surfaceElevated)
            .clipShape(RoundedRectangle(cornerRadius: AppTheme.cardRadius, style: .continuous))

        case .weather(let w):
            VStack(alignment: .leading, spacing: 6) {
                HStack(spacing: 8) {
                    Image(systemName: "cloud.sun.fill")
                        .font(.system(size: 18))
                        .foregroundColor(AppTheme.accent)
                    Text(w.city)
                        .font(.system(size: 14, weight: .medium))
                        .foregroundColor(AppTheme.primaryText)
                    Spacer()
                    Text(String(format: "%.0f%@", w.temperature, w.units))
                        .font(.system(size: 20, weight: .bold))
                        .foregroundColor(AppTheme.primaryText)
                }
                Text(w.condition)
                    .font(.system(size: 13))
                    .foregroundColor(AppTheme.secondaryText)
                if let h = w.humidity, let wind = w.windSpeed {
                    Text("湿度 \(h)% · 风速 \(String(format: "%.0f", wind)) km/h")
                        .font(.system(size: 12))
                        .foregroundColor(AppTheme.tertiaryText)
                }
            }
            .padding(14)
            .background(AppTheme.surfaceElevated)
            .clipShape(RoundedRectangle(cornerRadius: AppTheme.cardRadius, style: .continuous))

        case .webpage(let p):
            VStack(alignment: .leading, spacing: 6) {
                HStack(spacing: 8) {
                    Image(systemName: "doc.richtext.fill")
                        .font(.system(size: 16))
                        .foregroundColor(AppTheme.accent)
                    Text(p.title)
                        .font(.system(size: 13, weight: .semibold))
                        .foregroundColor(AppTheme.primaryText)
                        .lineLimit(1)
                }
                Text(p.summary)
                    .font(.system(size: 12))
                    .foregroundColor(AppTheme.secondaryText)
                    .lineLimit(10)
                if let u = URL(string: p.url) {
                    Link(destination: u) {
                        Text("查看原文")
                            .font(.system(size: 12, weight: .medium))
                            .foregroundColor(AppTheme.accentSoft)
                    }
                }
            }
            .padding(14)
            .background(AppTheme.surfaceElevated)
            .clipShape(RoundedRectangle(cornerRadius: AppTheme.cardRadius, style: .continuous))

        case .htmlCard(let html):
            WebViewCard(html: html, onHeightChange: { h in cardHeight = h })
                .frame(height: min(max(120, cardHeight), 480))
                .clipShape(RoundedRectangle(cornerRadius: AppTheme.cardRadius, style: .continuous))
                .overlay(
                    RoundedRectangle(cornerRadius: AppTheme.cardRadius, style: .continuous)
                        .stroke(AppTheme.border.opacity(0.5), lineWidth: 0.5)
                )

        case .systemAction(_, let description):
            HStack(spacing: 10) {
                Image(systemName: "gearshape.2.fill")
                    .font(.system(size: 16))
                    .foregroundColor(AppTheme.accent)
                VStack(alignment: .leading, spacing: 2) {
                    Text("系统操作")
                        .font(.system(size: 12, weight: .semibold))
                        .foregroundColor(AppTheme.secondaryText)
                    Text(description)
                        .font(.system(size: 13))
                        .foregroundColor(AppTheme.primaryText)
                }
                Spacer()
            }
            .padding(14)
            .background(AppTheme.surfaceElevated)
            .clipShape(RoundedRectangle(cornerRadius: AppTheme.cardRadius, style: .continuous))
        }
    }
}

/// 图片全屏查看器（点击图片放大查看，支持捏合缩放）
struct FullScreenImageViewer: View {
    let urlString: String
    @Binding var isPresented: Bool
    /// 缩放状态
    @State private var scale: CGFloat = 1.0
    @State private var lastScale: CGFloat = 1.0

    var body: some View {
        ZStack(alignment: .topTrailing) {
            Color.black.ignoresSafeArea()

            // 图片区域（捏合缩放）
            AsyncImage(url: URL(string: urlString)) { phase in
                switch phase {
                case .success(let image):
                    image
                        .resizable()
                        .scaledToFit()
                        .scaleEffect(scale)
                        .gesture(
                            MagnificationGesture()
                                .onChanged { value in
                                    scale = min(4.0, max(1.0, lastScale * value))
                                }
                                .onEnded { _ in lastScale = scale }
                        )
                        .frame(maxWidth: .infinity, maxHeight: .infinity)
                case .empty:
                    ProgressView()
                        .tint(.white)
                        .frame(maxWidth: .infinity, maxHeight: .infinity)
                case .failure:
                    VStack(spacing: 10) {
                        Image(systemName: "photo.badge.exclamationmark")
                            .font(.system(size: 40))
                            .foregroundColor(.gray)
                        Text("图片加载失败")
                            .font(.system(size: 14))
                            .foregroundColor(.gray)
                    }
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                @unknown default:
                    EmptyView()
                }
            }

            // 关闭按钮
            Button {
                isPresented = false
            } label: {
                Image(systemName: "xmark.circle.fill")
                    .font(.system(size: 30))
                    .foregroundColor(.white.opacity(0.9))
                    .shadow(color: .black.opacity(0.5), radius: 4)
                    .padding(16)
            }
        }
        .statusBarHidden()
    }
}

/// HTML 可视化卡片（圆角，WKWebView 渲染，带防御性错误处理）
/// 加载失败时不暴露原始 HTML，统一降级为「该链接暂不支持预览」
/// 支持内容高度自适应：加载完成后通过 JS 测量内容高度并回调
struct WebViewCard: UIViewRepresentable {
    let html: String
    var onHeightChange: ((CGFloat) -> Void)? = nil
    @State private var hasError: Bool = false

    func makeUIView(context: Context) -> ErrorHandlingHostingView {
        let config = WKWebViewConfiguration()
        let webView = WKWebView(frame: .zero, configuration: config)
        webView.isUserInteractionEnabled = false
        webView.scrollView.isScrollEnabled = false
        webView.backgroundColor = .clear
        webView.isOpaque = false
        webView.navigationDelegate = context.coordinator
        
        let hostingView = ErrorHandlingHostingView(webView: webView, hasError: $hasError)
        hostingView.load(html: wrappedHTML)
        return hostingView
    }

    func updateUIView(_ view: ErrorHandlingHostingView, context: Context) {
        context.coordinator.resetErrorIfNeeded()
        view.load(html: wrappedHTML)
    }

    func makeCoordinator() -> WebViewCoordinator {
        let coordinator = WebViewCoordinator()
        coordinator.onHeightChange = onHeightChange
        return coordinator
    }

    /// 智能包装：模型输出完整 HTML 文档时直接使用（避免双重包裹）；
    /// 输出内容片段时包装成深色主题卡片，并注入统一样式。
    private var wrappedHTML: String {
        let lower = html.lowercased()
        if lower.contains("<html") || lower.contains("<body") {
            return html
        }
        return """
        <!DOCTYPE html>
        <html>
        <head>
        <meta name="viewport" content="width=device-width, initial-scale=1.0, maximum-scale=1.0">
        <style>
            * { margin: 0; padding: 0; box-sizing: border-box; }
            body {
                font-family: -apple-system, BlinkMacSystemFont, "PingFang SC", sans-serif;
                font-size: 14px;
                color: #e8e6f0;
                background: transparent;
                padding: 14px;
                line-height: 1.55;
                word-break: break-word;
            }
            .card {
                background: linear-gradient(135deg, rgba(38, 34, 60, 0.92), rgba(24, 22, 40, 0.92));
                border: 1px solid rgba(255,255,255,0.06);
                border-radius: 16px;
                padding: 16px 18px;
                overflow: hidden;
                box-shadow: 0 8px 24px rgba(0,0,0,0.25);
            }
            h1, h2, h3, h4 { color: #FFA06B; margin: 10px 0 6px; line-height: 1.3; }
            h1 { font-size: 20px; } h2 { font-size: 17px; } h3 { font-size: 15px; } h4 { font-size: 14px; }
            p { margin: 6px 0; color: #c8c6d0; }
            table { width: 100%; border-collapse: collapse; margin: 8px 0; }
            th, td { padding: 8px 10px; text-align: left; border-bottom: 1px solid rgba(255,255,255,0.08); }
            th { font-weight: 600; color: #FFA06B; font-size: 13px; }
            td { color: #e8e6f0; font-size: 13px; }
            tr:last-child td { border-bottom: none; }
            ul, ol { padding-left: 22px; margin: 6px 0; }
            li { margin: 4px 0; color: #c8c6d0; }
            a { color: #6FB7FF; text-decoration: none; }
            code {
                background: rgba(255,255,255,0.08);
                padding: 2px 7px;
                border-radius: 5px;
                font-size: 12.5px;
                color: #FFB86C;
                font-family: ui-monospace, SFMono-Regular, Menlo, monospace;
            }
            pre {
                background: rgba(0,0,0,0.35);
                padding: 12px;
                border-radius: 10px;
                overflow-x: auto;
                margin: 8px 0;
            }
            pre code { background: transparent; padding: 0; color: #e8e6f0; }
            blockquote {
                border-left: 3px solid #FFA06B;
                padding: 4px 0 4px 12px;
                margin: 8px 0;
                color: #a8a6b8;
                font-style: italic;
            }
            hr { border: none; border-top: 1px solid rgba(255,255,255,0.1); margin: 14px 0; }
            img { max-width: 100%; border-radius: 12px; margin: 6px 0; }
            strong { color: #ffffff; }
            .badge {
                display: inline-block;
                background: rgba(255, 160, 107, 0.15);
                color: #FFA06B;
                padding: 3px 12px;
                border-radius: 12px;
                font-size: 12px;
                font-weight: 500;
                margin: 2px 2px;
            }
        </style>
        </head>
        <body><div class="card">\(html)</div></body>
        </html>
        """
    }
}

/// 协调器：捕获加载失败事件 + 测量内容高度
final class WebViewCoordinator: NSObject, WKNavigationDelegate {
    @MainActor var hasError: Bool = false
    /// 内容高度变化回调（JS 测量 document 高度）
    var onHeightChange: ((CGFloat) -> Void)?

    @MainActor
    func resetErrorIfNeeded() {
        hasError = false
    }

    @MainActor
    func markError() {
        hasError = true
    }

    @MainActor
    func webView(_ webView: WKWebView,
                 didFinish navigation: WKNavigation!) {
        // 加载完成后测量内容高度，实现卡片自适应
        measureHeight(webView)
        // 延迟二次测量：图片等异步资源可能加载后才撑起高度
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.4) { [weak self] in
            guard let self else { return }
            self.measureHeight(webView)
        }
    }

    @MainActor
    private func measureHeight(_ webView: WKWebView) {
        webView.evaluateJavaScript("document.documentElement.scrollHeight") { [weak self] result, _ in
            // JS 返回的是 NSNumber，需转 Double 再转 CGFloat
            if let num = result as? NSNumber {
                let h = CGFloat(num.doubleValue)
                if h > 0 {
                    DispatchQueue.main.async {
                        self?.onHeightChange?(h + 28) // 上下 padding 补偿
                    }
                }
            }
        }
    }

    @MainActor
    func webView(_ webView: WKWebView,
                 didFail navigation: WKNavigation!,
                 withError error: Error) {
        markError()
    }

    @MainActor
    func webView(_ webView: WKWebView,
                 didFailProvisionalNavigation navigation: WKNavigation!,
                 withError error: Error) {
        markError()
    }
}

/// 自定义宿主视图：包含 WKWebView + 错误降级叠加层
final class ErrorHandlingHostingView: UIView {
    private let webView: WKWebView
    private let errorOverlay = UILabel()
    var errorBinding: Binding<Bool>?

    init(webView: WKWebView, hasError: Binding<Bool>) {
        self.webView = webView
        self.errorBinding = hasError
        super.init(frame: .zero)
        setupSubviews()
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    private func setupSubviews() {
        // WKWebView 铺满
        addSubview(webView)
        webView.translatesAutoresizingMaskIntoConstraints = false
        NSLayoutConstraint.activate([
            webView.topAnchor.constraint(equalTo: topAnchor),
            webView.leadingAnchor.constraint(equalTo: leadingAnchor),
            webView.trailingAnchor.constraint(equalTo: trailingAnchor),
            webView.bottomAnchor.constraint(equalTo: bottomAnchor)
        ])

        // 错误叠加层：默认隐藏
        errorOverlay.textAlignment = .center
        errorOverlay.numberOfLines = 0
        errorOverlay.font = .systemFont(ofSize: 13)
        errorOverlay.textColor = UIColor(AppTheme.secondaryText)
        errorOverlay.isHidden = true
        errorOverlay.alpha = 0
        addSubview(errorOverlay)
        errorOverlay.translatesAutoresizingMaskIntoConstraints = false
        NSLayoutConstraint.activate([
            errorOverlay.centerXAnchor.constraint(equalTo: centerXAnchor),
            errorOverlay.centerYAnchor.constraint(equalTo: centerYAnchor)
        ])
    }

    /// 切换错误叠加层的可见性
    func syncErrorOverlay(isHidden: Bool) {
        UIView.animate(withDuration: 0.2) {
            if isHidden {
                self.errorOverlay.isHidden = true
                self.errorOverlay.alpha = 0
            } else {
                self.errorOverlay.isHidden = false
                self.errorOverlay.alpha = 1
            }
        }
    }

    func load(html: String) {
        webView.loadHTMLString(html, baseURL: nil)
    }
}

// MARK: - Binding 桥接：在 Coordinator 回调中同步更新 State
extension WebViewCoordinator {
    /// 监听 Coordinator 状态变化并同步到外部 State
    @MainActor
    static func bind(coordinator: WebViewCoordinator, hasError: Binding<Bool>) {
        let value = coordinator.hasError
        // 利用 Task 异步调度确保不会在 KVO 中间产生副作用
        // 实际通过 didSet 来观察变更
        hasError.wrappedValue = value
    }
}

/// AI 思考中的脉冲点
struct DotPulse: View {
    let delay: Double
    @State private var scale: CGFloat = 0.6

    var body: some View {
        Circle()
            .fill(AppTheme.secondaryText)
            .frame(width: 8, height: 8)
            .scaleEffect(scale)
            .onAppear {
                withAnimation(.easeInOut(duration: 0.6).repeatForever(autoreverses: true).delay(delay)) {
                    scale = 1.1
                }
            }
    }
}
