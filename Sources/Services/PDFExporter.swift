import Foundation
import UIKit
import PDFKit

/// 将对话记录导出为格式化 PDF 文件。
/// 支持附件：图片（预下载后按比例绘制）、天气 / 搜索结果 / 定位 / 网页 / HTML 卡片 / 系统操作（文本化卡片）。
enum PDFExporter {

    /// 导出对话为 PDF（含附件）。
    /// 图片附件在渲染前异步预下载；下载失败时以占位文本代替，不影响导出。
    static func export(messages: [ChatMessage]) async throws -> URL {
        // 1. 预下载所有图片附件
        var imageCache: [String: UIImage] = [:]
        let imageURLs = messages.flatMap { msg -> [String] in
            msg.attachments.compactMap { att in
                if case .image(let url) = att { return url }
                return nil
            }
        }
        for urlStr in imageURLs {
            guard imageCache[urlStr] == nil, let url = URL(string: urlStr) else { continue }
            if let (data, _) = try? await URLSession.shared.data(from: url),
               let img = UIImage(data: data) {
                imageCache[urlStr] = img
            }
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
            var y: CGFloat = margin

            func ensureSpace(_ needed: CGFloat) {
                if y + needed > pageRect.height - margin {
                    ctx.beginPage()
                    y = margin
                }
            }

            // 标题
            ensureSpace(40)
            "AI 对话记录".draw(in: CGRect(x: margin, y: y, width: maxWidth, height: 30),
                             withAttributes: Self.titleAttrs)
            y += 38
            let sub = "共 \(messages.count) 条消息 · 导出时间 \(Date().formatted(date: .abbreviated, time: .standard))"
            sub.draw(in: CGRect(x: margin, y: y, width: maxWidth, height: 16),
                     withAttributes: Self.subtitleAttrs)
            y += 26

            let df = DateFormatter()
            df.dateFormat = "yyyy-MM-dd HH:mm"

            for (i, msg) in messages.enumerated() {
                // 分隔线
                if i > 0 {
                    ensureSpace(20)
                    let line = UIBezierPath()
                    line.move(to: CGPoint(x: margin, y: y))
                    line.addLine(to: CGPoint(x: pageRect.width - margin, y: y))
                    line.lineWidth = 0.5
                    UIColor(white: 0.6, alpha: 0.35).setStroke()
                    line.stroke()
                    y += 14
                }

                // 角色 + 时间
                let isUser = msg.role == .user
                let header = "\(isUser ? "我" : "AI")  ·  \(df.string(from: msg.timestamp))"
                ensureSpace(22)
                header.draw(in: CGRect(x: margin, y: y, width: maxWidth, height: 18),
                            withAttributes: isUser ? Self.userHeaderAttrs : Self.aiHeaderAttrs)
                y += 24

                // 正文（自动换行）
                let content = msg.content.isEmpty ? "（无文字内容）" : msg.content
                let bodySize = (content as NSString).boundingRect(
                    with: CGSize(width: maxWidth, height: .greatestFiniteMagnitude),
                    options: [.usesLineFragmentOrigin, .usesFontLeading],
                    attributes: Self.bodyAttrs, context: nil)
                ensureSpace(bodySize.height + 4)
                (content as NSString).draw(
                    in: CGRect(x: margin, y: y, width: maxWidth, height: bodySize.height),
                    withAttributes: Self.bodyAttrs)
                y += bodySize.height + 10

                // 附件
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

    // MARK: - 字体样式

    private static let titleAttrs: [NSAttributedString.Key: Any] = [
        .font: UIFont.boldSystemFont(ofSize: 20),
        .foregroundColor: UIColor(red: 0.85, green: 0.45, blue: 0.2, alpha: 1)
    ]
    private static let subtitleAttrs: [NSAttributedString.Key: Any] = [
        .font: UIFont.systemFont(ofSize: 11),
        .foregroundColor: UIColor.lightGray
    ]
    private static let userHeaderAttrs: [NSAttributedString.Key: Any] = [
        .font: UIFont.boldSystemFont(ofSize: 13),
        .foregroundColor: UIColor.systemBlue
    ]
    private static let aiHeaderAttrs: [NSAttributedString.Key: Any] = [
        .font: UIFont.boldSystemFont(ofSize: 13),
        .foregroundColor: UIColor(red: 0.85, green: 0.45, blue: 0.2, alpha: 1)
    ]
    private static let bodyAttrs: [NSAttributedString.Key: Any] = [
        .font: UIFont.systemFont(ofSize: 13),
        .foregroundColor: UIColor.black
    ]
    private static let attachLabelAttrs: [NSAttributedString.Key: Any] = [
        .font: UIFont.boldSystemFont(ofSize: 12),
        .foregroundColor: UIColor.darkGray
    ]
    private static let attachSubAttrs: [NSAttributedString.Key: Any] = [
        .font: UIFont.systemFont(ofSize: 11),
        .foregroundColor: UIColor(white: 0.25, alpha: 1)
    ]
    private static let attachSnippetAttrs: [NSAttributedString.Key: Any] = [
        .font: UIFont.systemFont(ofSize: 10),
        .foregroundColor: UIColor.lightGray
    ]
}
