import Foundation
import UIKit
import PDFKit

/// 将对话记录导出为格式化 PDF 文件
enum PDFExporter {
    static func export(messages: [ChatMessage]) throws -> URL {
        let pageRect = CGRect(x: 0, y: 0, width: 612, height: 792) // US Letter
        let format = UIGraphicsPDFRendererFormat()
        let renderer = UIGraphicsPDFRenderer(bounds: pageRect, format: format)

        let tempURL = FileManager.default.temporaryDirectory.appendingPathComponent("AIChat_\(Int(Date().timeIntervalSince1970)).pdf")

        let titleAttrs: [NSAttributedString.Key: Any] = [
            .font: UIFont.boldSystemFont(ofSize: 18),
            .foregroundColor: UIColor.black
        ]
        let roleUserAttrs: [NSAttributedString.Key: Any] = [
            .font: UIFont.boldSystemFont(ofSize: 13),
            .foregroundColor: UIColor.darkGray
        ]
        let bodyAttrs: [NSAttributedString.Key: Any] = [
            .font: UIFont.systemFont(ofSize: 13),
            .foregroundColor: UIColor.black
        ]

        try renderer.writePDF(to: tempURL) { context in
            context.beginPage()
            let margin: CGFloat = 48
            var y: CGFloat = margin
            let maxWidth = pageRect.width - margin * 2

            "AI 对话记录".draw(in: CGRect(x: margin, y: y, width: maxWidth, height: 30), withAttributes: titleAttrs)
            y += 40

            let dateFormatter = DateFormatter()
            dateFormatter.dateFormat = "yyyy-MM-dd HH:mm"

            for msg in messages {
                let role = msg.role == .user ? "我" : "AI"
                let timeStr = dateFormatter.string(from: msg.timestamp)
                let header = "[\(timeStr)] \(role)"
                let headerRect = CGRect(x: margin, y: y, width: maxWidth, height: 20)
                header.draw(in: headerRect, withAttributes: roleUserAttrs)
                y += 24

                let bodyRect = CGRect(x: margin, y: y, width: maxWidth, height: 0)
                let bodySize = (msg.content as NSString).boundingRect(
                    with: CGSize(width: maxWidth, height: .greatestFiniteMagnitude),
                    options: [.usesLineFragmentOrigin, .usesFontLeading],
                    attributes: bodyAttrs, context: nil
                )
                (msg.content as NSString).draw(in: CGRect(x: margin, y: y, width: maxWidth, height: bodySize.height), withAttributes: bodyAttrs)
                y += bodySize.height + 20

                if y > pageRect.height - margin {
                    context.beginPage()
                    y = margin
                }
            }
        }

        return tempURL
    }
}