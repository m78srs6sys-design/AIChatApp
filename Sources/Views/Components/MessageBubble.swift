import SwiftUI
import UIKit
import WebKit

/// 单条消息气泡：用户(右·亮色) / AI(左·深色磨砂)
struct MessageBubble: View {
    let message: ChatMessage
    @EnvironmentObject private var chatVM: ChatViewModel

    // 多选删除支持
    var isSelectionMode: Bool = false
    var isSelected: Bool = false
    var onSelect: (() -> Void)? = nil
    var onDeleteRequested: (() -> Void)? = nil

    @State private var showReasoning: Bool = false

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
                .background(AppTheme.userBubble)
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
                    Text(message.content)
                        .font(.system(size: 16))
                        .foregroundColor(AppTheme.aiBubbleText)
                        .multilineTextAlignment(.leading)
                        .padding(.horizontal, 18)
                        .padding(.vertical, 12)
                }
                if message.isStreaming && !message.content.isEmpty {
                    TypingCursor()
                        .padding(.bottom, 14)
                }
            }
            .background(
                RoundedRectangle(cornerRadius: AppTheme.bubbleRadius, style: .continuous)
                    .fill(.ultraThinMaterial)
                    .overlay(
                        RoundedRectangle(cornerRadius: AppTheme.bubbleRadius, style: .continuous)
                            .fill(AppTheme.aiBubble.opacity(0.85))
                    )
            )
            .overlay(
                RoundedRectangle(cornerRadius: AppTheme.bubbleRadius, style: .continuous)
                    .stroke(AppTheme.border.opacity(0.5), lineWidth: 0.5)
            )
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

    var body: some View {
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
                    .lineLimit(4)
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
            WebViewCard(html: html)
                .frame(minHeight: 120, maxHeight: 360)
                .clipShape(RoundedRectangle(cornerRadius: AppTheme.cardRadius, style: .continuous))
                .overlay(
                    RoundedRectangle(cornerRadius: AppTheme.cardRadius, style: .continuous)
                        .stroke(AppTheme.border.opacity(0.5), lineWidth: 0.5)
                )

        case .systemAction(let action, let description):
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

/// HTML 可视化卡片（圆角，WKWebView 渲染）
struct WebViewCard: UIViewRepresentable {
    let html: String

    func makeUIView(context: Context) -> WKWebView {
        let config = WKWebViewConfiguration()
        // 禁止用户交互（滚动/点击等），纯展示
        let webView = WKWebView(frame: .zero, configuration: config)
        webView.isUserInteractionEnabled = false
        webView.scrollView.isScrollEnabled = false
        webView.backgroundColor = UIColor.clear
        webView.isOpaque = false
        webView.loadHTMLString(wrappedHTML, baseURL: nil)
        return webView
    }

    func updateUIView(_ webView: WKWebView, context: Context) {
        webView.loadHTMLString(wrappedHTML, baseURL: nil)
    }

    /// 包裹 HTML，添加深色主题适配
    private var wrappedHTML: String {
        """
        <!DOCTYPE html>
        <html>
        <head>
        <meta name="viewport" content="width=device-width, initial-scale=1.0, maximum-scale=1.0">
        <style>
            * { margin: 0; padding: 0; box-sizing: border-box; }
            body {
                font-family: -apple-system, BlinkMacSystemFont, sans-serif;
                font-size: 14px;
                color: #e8e6f0;
                background: transparent;
                padding: 14px;
                line-height: 1.5;
            }
            /* 圆角卡片容器 */
            .card {
                background: rgba(30, 28, 46, 0.85);
                border-radius: 16px;
                padding: 16px;
                overflow: hidden;
            }
            table { width: 100%; border-collapse: collapse; }
            th, td { padding: 8px 10px; text-align: left; border-bottom: 1px solid rgba(255,255,255,0.08); }
            th { font-weight: 600; color: #FFA06B; }
            td { color: #e8e6f0; }
            h1, h2, h3, h4 { color: #FFA06B; margin: 8px 0; }
            p { margin: 6px 0; color: #c8c6d0; }
            .badge {
                display: inline-block;
                background: rgba(255, 160, 107, 0.15);
                color: #FFA06B;
                padding: 2px 10px;
                border-radius: 12px;
                font-size: 12px;
                font-weight: 500;
            }
        </style>
        </head>
        <body><div class="card">\(html)</div></body>
        </html>
        """
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
