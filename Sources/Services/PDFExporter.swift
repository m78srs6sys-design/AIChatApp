import Foundation
import UIKit
import PDFKit

/// 将对话记录导出为排版清晰、可读性强的 PDF 文件（浅色专业风格）。
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

        // 2. 渲染 PDF（A4 尺寸，白底浅色专业风格）
        let pageRect = CGRect(x: 0, y: 0, width: 595, height: 842) // A4
        let format = UIGraphicsPDFRendererFormat()
        let renderer = UIGraphicsPDFRenderer(bounds: pageRect, format: format)
        let tempURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("AIChat_\(Int(Date().timeIntervalSince1970)).pdf")

        try renderer.writePDF(to: tempURL) { ctx in
            let margin: CGFloat = 48
            let maxWidth = pageRect.width - margin * 2
            let bubbleMaxWidth = maxWidth * 0.78
            var y: CGFloat = margin

            func ensureSpace(_ needed: CGFloat) {
                if y + needed > pageRect.height - margin {
                    ctx.beginPage()
                    y = margin
                }
            }

            // 标题
            ensureSpace(48)
            let title = "AI 对话记录"
            title.draw(in: CGRect(x: margin, y: y, width: maxWidth, height: 30),
                       withAttributes: Self.titleAttrs)
            y += 36
            let sub = "共 \(messages.count) 条消息 · 导出时间 \(Date().formatted(date: .abbreviated, time: .standard))"
            sub.draw(in: CGRect(x: margin, y: y, width: maxWidth, height: 14),
                     withAttributes: Self.subtitleAttrs)
            y += 22
            // 标题下分隔线
            let headerLine = UIBezierPath()
            headerLine.move(to: CGPoint(x: margin, y: y))
            headerLine.addLine(to: CGPoint(x: pageRect.width - margin, y: y))
            headerLine.lineWidth = 0.8
            Self.primaryAccent.setStroke()
            headerLine.stroke()
            y += 24

            let df = DateFormatter()
            df.dateFormat = "yyyy-MM-dd HH:mm"

            for (i, msg) in messages.enumerated() {
                progress?(0.3 + 0.7 * Double(i) / Double(messages.count))
                let isUser = msg.role == .user

                // 时间戳小标签
                ensureSpace(18)
                let timeText = df.string(from: msg.timestamp)
                let timeSize = (timeText as NSString).boundingRect(
                    with: CGSize(width: 120, height: CGFloat.greatestFiniteMagnitude),
                    options: [.usesLineFragmentOrigin, .usesFontLeading],
                    attributes: Self.timeAttrs, context: nil)
                let timeX = isUser ? pageRect.width - margin - timeSize.width : margin
                timeText.draw(in: CGRect(x: timeX, y: y, width: timeSize.width, height: timeSize.height),
                              withAttributes: Self.timeAttrs)
                y += timeSize.height + 6

                // 正文气泡（白底、浅色气泡、深色文字，任何阅读器均可读）
                let content = msg.content.isEmpty ? "（无文字内容）" : msg.content
                let bodyAttrs = isUser ? Self.userBodyAttrs : Self.aiBodyAttrs
                let bodySize = (content as NSString).boundingRect(
                    with: CGSize(width: bubbleMaxWidth - 32, height: CGFloat.greatestFiniteMagnitude),
                    options: [.usesLineFragmentOrigin, .usesFontLeading],
                    attributes: bodyAttrs, context: nil)
                let bubbleHeight = bodySize.height + 22
                ensureSpace(bubbleHeight + 10)
                let bubbleW = min(bodySize.width + 32, bubbleMaxWidth)
                let bubbleX = isUser ? pageRect.width - margin - bubbleW : margin
                let bubbleRect = CGRect(x: bubbleX, y: y, width: bubbleW, height: bubbleHeight)
                let bubblePath = UIBezierPath(roundedRect: bubbleRect,
                                              byRoundingCorners: isUser ? [.topLeft, .topRight, .bottomLeft] : [.topLeft, .topRight, .bottomRight],
                                              cornerRadii: CGSize(width: 14, height: 14))
                (isUser ? Self.userBubbleColor : Self.aiBubbleColor).setFill()
                bubblePath.fill()
                // 气泡描边（浅色风格下增加层次）
                bubblePath.lineWidth = 0.5
                (isUser ? Self.userBubbleBorder : Self.aiBubbleBorder).setStroke()
                bubblePath.stroke()
                content.draw(in: CGRect(x: bubbleX + 16, y: y + 11, width: bubbleW - 32, height: bodySize.height),
                             withAttributes: bodyAttrs)
                y += bubbleHeight + 14

                // 附件卡片
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
        let cardX = margin
        let cardWidth = maxWidth

        func need(_ h: CGFloat) {
            if y + h > 842 - 48 {
                beginPage()
                y = 48
            }
        }
        // 附件卡片浅灰背景
        func drawCard(_ h: CGFloat) {
            let rect = CGRect(x: cardX, y: y - 2, width: cardWidth, height: h + 6)
            let path = UIBezierPath(roundedRect: rect, cornerRadius: 10)
            Self.cardBgColor.setFill()
            path.fill()
        }

        switch att {
        case .image(let urlStr):
            if let img = imageCache[urlStr] {
                let ratio = min(cardWidth / img.size.width, 400 / img.size.height, 1)
                let drawW = img.size.width * ratio
                let drawH = img.size.height * ratio
                need(drawH + 16)
                let rect = CGRect(x: cardX + 8, y: y, width: drawW, height: drawH)
                let path = UIBezierPath(roundedRect: rect, cornerRadius: 8)
                path.addClip()
                img.draw(in: rect)
                y += drawH + 14
            } else {
                need(24)
                "图片（下载失败，未包含在 PDF 中）".draw(
                    in: CGRect(x: cardX + 8, y: y, width: cardWidth - 16, height: 18),
                    withAttributes: Self.attachSubAttrs)
                y += 22
            }

        case .location(let lat, let lon, let name):
            need(46)
            drawCard(36)
            "📍 位置".draw(in: CGRect(x: cardX + 10, y: y + 2, width: cardWidth - 20, height: 18),
                          withAttributes: Self.attachLabelAttrs)
            y += 22
            "\(name.isEmpty ? "当前位置" : name)  (\(String(format: "%.4f", lat)), \(String(format: "%.4f", lon)))".draw(
                in: CGRect(x: cardX + 10, y: y, width: cardWidth - 20, height: 16),
                withAttributes: Self.attachSubAttrs)
            y += 26

        case .weather(let w):
            need(48)
            drawCard(38)
            "☀️ 天气 · \(w.city)".draw(in: CGRect(x: cardX + 10, y: y + 2, width: cardWidth - 20, height: 18),
                                       withAttributes: Self.attachLabelAttrs)
            y += 22
            var line = "\(w.condition) · \(String(format: "%.0f", w.temperature))\(w.units)"
            if let h = w.humidity { line += " · 湿度 \(h)%" }
            if let wind = w.windSpeed { line += " · 风速 \(String(format: "%.0f", wind)) km/h" }
            line.draw(in: CGRect(x: cardX + 10, y: y, width: cardWidth - 20, height: 16),
                      withAttributes: Self.attachSubAttrs)
            y += 26

        case .searchResults(let items):
            need(30)
            "🔍 网络搜索结果".draw(in: CGRect(x: cardX + 10, y: y, width: cardWidth - 20, height: 18),
                                   withAttributes: Self.attachLabelAttrs)
            y += 24
            var maxCardH: CGFloat = 18
            var linesY: [CGFloat] = []
            var linesText: [(String, [NSAttributedString.Key: Any])] = []
            for (idx, item) in items.prefix(5).enumerated() {
                let line = "\(idx + 1). \(item.title)"
                let size = (line as NSString).boundingRect(
                    with: CGSize(width: cardWidth - 24, height: CGFloat.greatestFiniteMagnitude),
                    options: [.usesLineFragmentOrigin, .usesFontLeading],
                    attributes: Self.attachSubAttrs, context: nil)
                linesText.append((line, Self.attachSubAttrs))
                linesY.append(size.height)
                maxCardH += size.height + 3
                if let snippet = item.snippet, !snippet.isEmpty {
                    let s = "   \(snippet)"
                    let sSize = (s as NSString).boundingRect(
                        with: CGSize(width: cardWidth - 28, height: CGFloat.greatestFiniteMagnitude),
                        options: [.usesLineFragmentOrigin, .usesFontLeading],
                        attributes: Self.attachSnippetAttrs, context: nil)
                    linesText.append((s, Self.attachSnippetAttrs))
                    linesY.append(sSize.height)
                    maxCardH += sSize.height + 3
                }
            }
            need(maxCardH + 8)
            drawCard(maxCardH)
            for (idx, entry) in linesText.enumerated() {
                let (text, attrs) = entry
                let h = linesY[idx]
                text.draw(in: CGRect(x: cardX + 10, y: y, width: cardWidth - 20, height: h),
                          withAttributes: attrs)
                y += h + 3
            }
            y += 8

        case .webpage(let p):
            need(60)
            let summary = String(p.summary.prefix(400))
            let sSize = (summary as NSString).boundingRect(
                with: CGSize(width: cardWidth - 24, height: CGFloat.greatestFiniteMagnitude),
                options: [.usesLineFragmentOrigin, .usesFontLeading],
                attributes: Self.attachSubAttrs, context: nil)
            let cardH = 22 + sSize.height + 18 + 10
            need(cardH)
            drawCard(cardH)
            "🌐 网页摘要 · \(p.title)".draw(in: CGRect(x: cardX + 10, y: y + 2, width: cardWidth - 20, height: 18),
                                            withAttributes: Self.attachLabelAttrs)
            y += 22
            summary.draw(in: CGRect(x: cardX + 10, y: y, width: cardWidth - 20, height: sSize.height),
                         withAttributes: Self.attachSubAttrs)
            y += sSize.height + 4
            p.url.draw(in: CGRect(x: cardX + 10, y: y, width: cardWidth - 20, height: 14),
                       withAttributes: Self.attachSnippetAttrs)
            y += 22

        case .htmlCard(let html):
            need(30)
            "📊 可视化卡片内容".draw(in: CGRect(x: cardX + 10, y: y, width: cardWidth - 20, height: 18),
                                     withAttributes: Self.attachLabelAttrs)
            y += 24
            let plain = Self.htmlToText(html)
            let sSize = (plain as NSString).boundingRect(
                with: CGSize(width: cardWidth - 24, height: CGFloat.greatestFiniteMagnitude),
                options: [.usesLineFragmentOrigin, .usesFontLeading],
                attributes: Self.attachSubAttrs, context: nil)
            let cardH = sSize.height + 10
            need(cardH)
            drawCard(cardH)
            plain.draw(in: CGRect(x: cardX + 10, y: y + 4, width: cardWidth - 20, height: sSize.height),
                       withAttributes: Self.attachSubAttrs)
            y += cardH + 8

        case .systemAction(let action, let description):
            need(30)
            drawCard(24)
            "⚙️ 系统操作：\(description.isEmpty ? action : description)".draw(
                in: CGRect(x: cardX + 10, y: y + 4, width: cardWidth - 20, height: 18),
                withAttributes: Self.attachSubAttrs)
            y += 30
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

    // MARK: - 字体样式（浅色专业风格：白底 + 深色文字，任何阅读器可读）

    private static let primaryAccent = UIColor(red: 0.91, green: 0.35, blue: 0.05, alpha: 1)      // 深橙
    private static let userBubbleColor = UIColor(red: 0.90, green: 0.94, blue: 1.00, alpha: 1)   // 浅蓝
    private static let userBubbleBorder = UIColor(red: 0.62, green: 0.73, blue: 0.95, alpha: 1)
    private static let aiBubbleColor = UIColor(red: 0.95, green: 0.95, blue: 0.96, alpha: 1)     // 浅灰
    private static let aiBubbleBorder = UIColor(red: 0.84, green: 0.84, blue: 0.86, alpha: 1)
    private static let cardBgColor = UIColor(red: 0.97, green: 0.97, blue: 0.98, alpha: 1)

    private static let titleAttrs: [NSAttributedString.Key: Any] = [
        .font: UIFont.boldSystemFont(ofSize: 22),
        .foregroundColor: primaryAccent
    ]
    private static let subtitleAttrs: [NSAttributedString.Key: Any] = [
        .font: UIFont.systemFont(ofSize: 11),
        .foregroundColor: UIColor(white: 0.45, alpha: 1)
    ]
    private static let timeAttrs: [NSAttributedString.Key: Any] = [
        .font: UIFont.systemFont(ofSize: 9),
        .foregroundColor: UIColor(white: 0.55, alpha: 1)
    ]
    private static let userBodyAttrs: [NSAttributedString.Key: Any] = [
        .font: UIFont.systemFont(ofSize: 13),
        .foregroundColor: UIColor(red: 0.10, green: 0.22, blue: 0.42, alpha: 1)   // 深蓝
    ]
    private static let aiBodyAttrs: [NSAttributedString.Key: Any] = [
        .font: UIFont.systemFont(ofSize: 13),
        .foregroundColor: UIColor(white: 0.12, alpha: 1)                          // 深灰
    ]
    private static let attachLabelAttrs: [NSAttributedString.Key: Any] = [
        .font: UIFont.boldSystemFont(ofSize: 12),
        .foregroundColor: primaryAccent
    ]
    private static let attachSubAttrs: [NSAttributedString.Key: Any] = [
        .font: UIFont.systemFont(ofSize: 11),
        .foregroundColor: UIColor(white: 0.2, alpha: 1)
    ]
    private static let attachSnippetAttrs: [NSAttributedString.Key: Any] = [
        .font: UIFont.systemFont(ofSize: 10),
        .foregroundColor: UIColor(white: 0.4, alpha: 1)
    ]
}
