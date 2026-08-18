import SwiftUI
import UIKit

/// 单条消息气泡：用户(右·亮色) / AI(左·深色磨砂)
struct MessageBubble: View {
    let message: ChatMessage
    @EnvironmentObject private var chatVM: ChatViewModel

    var body: some View {
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
                bubbleContent
                attachmentViews
            }
            .contextMenu {
                if !message.content.isEmpty {
                    Button {
                        UIPasteboard.general.string = message.content
                    } label: {
                        Label("复制内容", systemImage: "doc.on.doc")
                    }
                }
                Button(role: .destructive) {
                    chatVM.deleteMessage(message)
                } label: {
                    Label("删除此消息", systemImage: "trash")
                }
            }

            if message.role == .assistant {
                Spacer(minLength: 48)
            }
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 4)
        .transition(.asymmetric(
            insertion: .move(edge: message.role == .user ? .trailing : .leading).combined(with: .opacity),
            removal: .opacity
        ))
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
                    HStack(spacing: 4) {
                        ForEach(0..<3, id: \.self) { i in
                            DotPulse(delay: Double(i) * 0.2)
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

/// 附件展示（图片 / 定位 / 搜索结果）
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
        }
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