import Foundation
import UIKit
import PDFKit

/// 将对话记录导出为与 App UI 风格一致的 PDF 文件。
/// 支持附件：图片（预下载后按比例绘制）、天气 / 搜索结果 / 定位 / 网页 / HTML 卡片 / 系统操作。
enum PDFExporter {

    /// 导出对话为 PDF（含附件）。
    /// 图片附件在渲染前异步预下载；下载失败时以占位文本代替，不影响导出。
    static func export(messages: [ChatMessage], progress: ((Double) -> Void)? = nil) async throws -> URL {
        // 1. 预下载所有图片附件
        var imageCache: [String: UIImage] = [:]
        let imageURLs = messages.flatMap { msg -> [String] in
            msg.attachments.compactMap { att in
                if case .image(let url) = att { return url }
                return nil
            }
        }
        let totalImages = imageURLs.count
        for (idx, urlStr) in imageURLs.enumerated() {
            guard imageCache[urlStr] == nil, let url = URL(string: urlStr) else { continue }
            if let (data, _) = try? await URLSession.shared.data(from: url),
               let img = UIImage(data: data) {
                imageCache[urlStr] = img
            }
            progress?(0.1 + 0.2 * Double(idx + 1) / Double(max(totalImages, 1)))
        }

        // 2. 渲染 PDF
        let pageRect = CGRect(x: 0, y: 0, width: 612, height: 792) // US Letter
        let format = UIGraphicsPDFRendererFormat()
        let renderer = UIGraphicsPDFRenderer(bounds: pageRect, format: format)
        let tempURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("AIChat_\(Int(Date().timeIntervalSince1970)).pdf")

        try renderer.writePDF(to: tempURL) { ctx in
            let margin: CGFloat = 44
            let maxWidth = pageRect.width - margin * 2
            let bubbleMaxWidth = maxWidth * 0.82
            var y: CGFloat = margin

            func fillBackground() {
                Self.pageBgColor.setFill()
                UIRectFill(pageRect)
            }
            func ensureSpace(_ needed: CGFloat) {
                if y + needed > pageRect.height - margin {
                    ctx.beginPage()
                    fillBackground()
                    y = margin
                }
            }

            fillBackground()

            // 标题（与 App 主题色一致）
            ensureSpace(44)
            let title = "AI 对话记录"
            title.draw(in: CGRect(x: margin, y: y, width: maxWidth, height: 30),
                       withAttributes: Self.titleAttrs)
            y += 36
            let sub = "共 \(messages.count) 条消息 · 导出时间 \(Date().formatted(date: .abbreviated, time: .standard))"
            sub.draw(in: CGRect(x: margin, y: y, width: maxWidth, height: 14),
                     withAttributes: Self.subtitleAttrs)
            y += 28

            let df = DateFormatter()
            df.dateFormat = "yyyy-MM-dd HH:mm"

            for (i, msg) in messages.enumerated() {
                progress?(0.3 + 0.7 * Double(i) / Double(messages.count))
                let isUser = msg.role == .user

                // 角色 + 时间 小标签
                ensureSpace(20)
                let header = "\(isUser ? "我" : "AI")  ·  \(df.string(from: msg.timestamp))"
                let headerSize = (header as NSString).boundingRect(
                    with: CGSize(width: bubbleMaxWidth, height: .greatestFiniteMagnitude),
                    options: [.usesLineFragmentOrigin, .usesFontLeading],
                    attributes: Self.headerAttrs, context: nil)
                let headerX: CGFloat = isUser ? pageRect.width - margin - headerSize.width : margin
                header.draw(in: CGRect(x: headerX, y: y, width: headerSize.width, height: headerSize.height),
                            withAttributes: Self.headerAttrs)
                y += headerSize.height + 6

                // 正文气泡
                let content = msg.content.isEmpty ? "（无文字内容）" : msg.content
                let bodySize = (content as NSString).boundingRect(
                    with: CGSize(width: bubbleMaxWidth - 28, height: .greatestFiniteMagnitude),
                    options: [.usesLineFragmentOrigin, .usesFontLeading],
                    attributes: isUser ? Self.userBodyAttrs : Self.aiBodyAttrs, context: nil)
                let bubbleHeight = bodySize.height + 20
                ensureSpace(bubbleHeight + 10)
                let bubbleX: CGFloat = isUser ? pageRect.width - margin - bodySize.width - 28 : margin
                let bubbleRect = CGRect(x: bubbleX, y: y, width: bodySize.width + 28, height: bubbleHeight)
                let bubblePath = UIBezierPath(roundedRect: bubbleRect,
                                              byRoundingCorners: isUser ? [.topLeft, .topRight, .bottomLeft] : [.topLeft, .topRight, .bottomRight],
                                              cornerRadii: CGSize(width: 16, height: 16))
                (isUser ? Self.userBubbleColor : Self.aiBubbleColor).setFill()
                bubblePath.fill()
                content.draw(in: CGRect(x: bubbleX + 14, y: y + 10, width: bodySize.width, height: bodySize.height),
                             withAttributes: isUser ? Self.userBodyAttrs : Self.aiBodyAttrs)
                y += bubbleHeight + 12

                // 附件卡片（App 卡片样式）
                for att in msg.attachments {
                    let result = Self.drawAttachment(att,
                                                     atY: y,
                                                     margin: margin,
                                                     maxWidth: maxWidth,
                                                     imageCache: imageCache,
                                                     beginPage: { ctx.beginPage(); y = margin })
                    y = result
                }
            }
            progress?(1.0)
        }
        return tempURL
    }

    // MARK: - 附件绘制

    /// 绘制单个附件，返回绘制结束后的 y 坐标。
    private static func drawAttachment(_ att: MessageAttachment,
                                       atY startY: CGFloat,
                                       margin: CGFloat,
                                       maxWidth: CGFloat,
                                       imageCache: [String: UIImage],
                                       beginPage: () -> Void) -> CGFloat {
        var y = startY
        let cardX = margin + 8
        let cardWidth = maxWidth - 16

        func need(_ h: CGFloat) {
            if y + h > 792 - 44 {
                beginPage()
                y = 44
            }
        }

        switch att {
        case .image(let urlStr):
            if let img = imageCache[urlStr] {
                // 图片按比例缩放：宽不超过卡片宽度，高不超过 420
                let ratio = min(cardWidth / img.size.width, 420 / img.size.height, 1)
                let drawW = img.size.width * ratio
                let drawH = img.size.height * ratio
                need(drawH + 16)
                let rect = CGRect(x: cardX, y: y, width: drawW, height: drawH)
                let path = UIBezierPath(roundedRect: rect, cornerRadius: 8)
                path.addClip()
                img.draw(in: rect)
                y += drawH + 14
            } else {
                need(24)
                "🖼 图片（下载失败，未包含在 PDF 中）".draw(
                    in: CGRect(x: cardX, y: y, width: cardWidth, height: 18),
                    withAttributes: Self.attachLabelAttrs)
                y += 22
            }

        case .location(let lat, let lon, let name):
            need(26)
            "📍 位置：\(name.isEmpty ? "当前位置" : name)".draw(
                in: CGRect(x: cardX, y: y, width: cardWidth, height: 18),
                withAttributes: Self.attachLabelAttrs)
            y += 18
            String(format: "    %.4f, %.4f", lat, lon).draw(
                in: CGRect(x: cardX, y: y, width: cardWidth, height: 16),
                withAttributes: Self.attachSubAttrs)
            y += 20

        case .weather(let w):
            need(26)
            "☀️ 天气：\(w.city) · \(w.condition) · \(String(format: "%.0f", w.temperature))\(w.units)".draw(
                in: CGRect(x: cardX, y: y, width: cardWidth, height: 18),
                withAttributes: Self.attachLabelAttrs)
            y += 18
            var extra: [String] = []
            if let h = w.humidity { extra.append("湿度 \(h)%") }
            if let wind = w.windSpeed { extra.append("风速 \(String(format: "%.0f", wind)) km/h") }
            if !extra.isEmpty {
                ("    " + extra.joined(separator: " · ")).draw(
                    in: CGRect(x: cardX, y: y, width: cardWidth, height: 16),
                    withAttributes: Self.attachSubAttrs)
                y += 20
            } else { y += 4 }

        case .searchResults(let items):
            need(26)
            "🔍 网络搜索结果：".draw(in: CGRect(x: cardX, y: y, width: cardWidth, height: 18),
                                     withAttributes: Self.attachLabelAttrs)
            y += 22
            for (idx, item) in items.prefix(5).enumerated() {
                let line = "\(idx + 1). \(item.title)"
                let size = (line as NSString).boundingRect(
                    with: CGSize(width: cardWidth, height: .greatestFiniteMagnitude),
                    options: [.usesLineFragmentOrigin, .usesFontLeading],
                    attributes: Self.attachSubAttrs, context: nil)
                need(size.height + 2)
                (line as NSString).draw(in: CGRect(x: cardX + 6, y: y, width: cardWidth - 6, height: size.height),
                                        withAttributes: Self.attachSubAttrs)
                y += size.height + 3
                if let snippet = item.snippet, !snippet.isEmpty {
                    let s = "      \(snippet)"
                    let sSize = (s as NSString).boundingRect(
                        with: CGSize(width: cardWidth - 12, height: .greatestFiniteMagnitude),
                        options: [.usesLineFragmentOrigin, .usesFontLeading],
                        attributes: Self.attachSnippetAttrs, context: nil)
                    need(sSize.height + 2)
                    (s as NSString).draw(in: CGRect(x: cardX + 6, y: y, width: cardWidth - 12, height: sSize.height),
                                         withAttributes: Self.attachSnippetAttrs)
                    y += sSize.height + 3
                }
            }
            y += 4

        case .webpage(let p):
            need(26)
            "🌐 网页摘要：\(p.title)".draw(
                in: CGRect(x: cardX, y: y, width: cardWidth, height: 18),
                withAttributes: Self.attachLabelAttrs)
            y += 20
            let summary = String(p.summary.prefix(500))
            let sSize = (summary as NSString).boundingRect(
                with: CGSize(width: cardWidth, height: .greatestFiniteMagnitude),
                options: [.usesLineFragmentOrigin, .usesFontLeading],
                attributes: Self.attachSubAttrs, context: nil)
            need(sSize.height + 2)
            (summary as NSString).draw(in: CGRect(x: cardX + 4, y: y, width: cardWidth - 4, height: sSize.height),
                                       withAttributes: Self.attachSubAttrs)
            y += sSize.height + 6
            p.url.draw(in: CGRect(x: cardX + 4, y: y, width: cardWidth - 4, height: 14),
                       withAttributes: Self.attachSnippetAttrs)
            y += 18

        case .htmlCard(let html):
            need(26)
            "📊 可视化卡片".draw(in: CGRect(x: cardX, y: y, width: cardWidth, height: 18),
                                 withAttributes: Self.attachLabelAttrs)
            y += 20
            // HTML 内容转纯文本摘要
            let plain = Self.htmlToText(html)
            let sSize = (plain as NSString).boundingRect(
                with: CGSize(width: cardWidth, height: .greatestFiniteMagnitude),
                options: [.usesLineFragmentOrigin, .usesFontLeading],
                attributes: Self.attachSubAttrs, context: nil)
            need(sSize.height + 2)
            (plain as NSString).draw(in: CGRect(x: cardX + 4, y: y, width: cardWidth - 4, height: sSize.height),
                                     withAttributes: Self.attachSubAttrs)
            y += sSize.height + 8

        case .systemAction(let action, let description):
            need(26)
            "⚙️ 系统操作：\(description.isEmpty ? action : description)".draw(
                in: CGRect(x: cardX, y: y, width: cardWidth, height: 18),
                withAttributes: Self.attachLabelAttrs)
            y += 22
        }

        return y + 6
    }

    /// HTML 转纯文本（去标签、去实体，截取前 600 字）
    private static func htmlToText(_ html: String) -> String {
        var s = html
        s = s.replacingOccurrences(of: "<[^>]+>", with: " ", options: .regularExpression)
        s = s.replacingOccurrences(of: "&nbsp;", with: " ")
        s = s.replacingOccurrences(of: "&amp;", with: "&")
        s = s.replacingOccurrences(of: "&lt;", with: "<")
        s = s.replacingOccurrences(of: "&gt;", with: ">")
        s = s.replacingOccurrences(of: "&quot;", with: "\"")
        s = s.components(separatedBy: .whitespacesAndNewlines)
            .filter { !$0.isEmpty }.joined(separator: " ")
        return String(s.prefix(600))
    }

    // MARK: - 字体样式（匹配 App 深色主题）

    private static let pageBgColor = UIColor(red: 0.08, green: 0.07, blue: 0.12, alpha: 1)
    private static let userBubbleColor = UIColor(red: 0.20, green: 0.42, blue: 1.00, alpha: 0.95)
    private static let aiBubbleColor = UIColor(red: 0.12, green: 0.11, blue: 0.18, alpha: 1)
    private static let accentColor = UIColor(red: 1.00, green: 0.63, blue: 0.42, alpha: 1)
    private static let primaryText = UIColor(white: 0.92, alpha: 1)
    private static let secondaryText = UIColor(white: 0.55, alpha: 1)
    private static let cardBgColor = UIColor(red: 0.15, green: 0.14, blue: 0.22, alpha: 1)

    private static let titleAttrs: [NSAttributedString.Key: Any] = [
        .font: UIFont.boldSystemFont(ofSize: 20),
        .foregroundColor: accentColor
    ]
    private static let subtitleAttrs: [NSAttributedString.Key: Any] = [
        .font: UIFont.systemFont(ofSize: 11),
        .foregroundColor: secondaryText
    ]
    private static let headerAttrs: [NSAttributedString.Key: Any] = [
        .font: UIFont.systemFont(ofSize: 10),
        .foregroundColor: secondaryText
    ]
    private static let userBodyAttrs: [NSAttributedString.Key: Any] = [
        .font: UIFont.systemFont(ofSize: 13),
        .foregroundColor: UIColor.white
    ]
    private static let aiBodyAttrs: [NSAttributedString.Key: Any] = [
        .font: UIFont.systemFont(ofSize: 13),
        .foregroundColor: primaryText
    ]
    private static let attachLabelAttrs: [NSAttributedString.Key: Any] = [
        .font: UIFont.boldSystemFont(ofSize: 12),
        .foregroundColor: accentColor
    ]
    private static let attachSubAttrs: [NSAttributedString.Key: Any] = [
        .font: UIFont.systemFont(ofSize: 11),
        .foregroundColor: primaryText
    ]
    private static let attachSnippetAttrs: [NSAttributedString.Key: Any] = [
        .font: UIFont.systemFont(ofSize: 10),
        .foregroundColor: secondaryText
    ]
}
