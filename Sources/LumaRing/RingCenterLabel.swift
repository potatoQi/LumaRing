import AppKit
import LumaRingCore

/// Shared typography for the neutral center in every ring mode.
@MainActor enum RingCenterLabel {
    static var titleFont: NSFont {
        NSFont.systemFont(ofSize: CGFloat(Preferences.shared.options.centerTitleSize), weight: .medium)
    }
    static let detailFont = NSFont.systemFont(ofSize: 10)

    static func draw(title: String, detail: String, paging: Bool = false, icon: NSImage? = nil,
                     titleColor: NSColor = .labelColor, detailColor: NSColor = .secondaryLabelColor) {
        let center = RingGeometry.center
        let titleFont = titleFont
        let titleHeight = height(title, font: titleFont, width: 72, lines: paging || icon != nil ? 1 : 2)
        // A long title gets two lines without shrinking its font. Reserve one
        // detail line in that case, or when the paging controls need space.
        let detailHeight = detail.isEmpty ? 0 : height(detail, font: detailFont, width: 76,
                                                     lines: paging || icon != nil || titleHeight > titleFont.pointSize + 3 ? 1 : 2)
        let gap: CGFloat = detail.isEmpty ? 0 : 5
        let iconHeight: CGFloat = icon == nil ? 0 : 21
        let total = iconHeight + titleHeight + gap + detailHeight
        let bottom = paging ? center.y - (icon == nil ? 14 : 16) : center.y - total / 2
        if let icon {
            icon.draw(in: CGRect(x: center.x - 9, y: bottom + total - 18, width: 18, height: 18))
        }
        text(title, in: CGRect(x: center.x - 36, y: bottom + detailHeight + gap, width: 72, height: titleHeight),
             font: titleFont, color: titleColor, wraps: !paging)
        if !detail.isEmpty {
            text(detail, in: CGRect(x: center.x - 38, y: bottom, width: 76, height: detailHeight),
                 font: detailFont, color: detailColor, wraps: detailHeight > 13)
        }
    }

    static func page(_ value: String, in rect: CGRect, color: NSColor = .secondaryLabelColor) {
        text(value, in: rect, font: detailFont, color: color, wraps: false)
    }

    private static func height(_ value: String, font: NSFont, width: CGFloat, lines: Int) -> CGFloat {
        let lineHeight = font.pointSize + 3
        let measured = (value as NSString).boundingRect(with: CGSize(width: width, height: .greatestFiniteMagnitude),
            options: [.usesLineFragmentOrigin], attributes: [.font: font, .paragraphStyle: paragraph(font: font, wraps: true)])
        return measured.height > lineHeight && lines > 1 ? lineHeight * 2 : lineHeight
    }

    private static func paragraph(font: NSFont, wraps: Bool) -> NSParagraphStyle {
        let style = NSMutableParagraphStyle()
        style.alignment = .center
        style.lineBreakMode = wraps ? .byWordWrapping : .byTruncatingTail
        style.minimumLineHeight = font.pointSize + 3
        style.maximumLineHeight = font.pointSize + 3
        return style
    }

    private static func text(_ value: String, in rect: CGRect, font: NSFont, color: NSColor, wraps: Bool) {
        NSGraphicsContext.saveGraphicsState()
        defer { NSGraphicsContext.restoreGraphicsState() }
        NSBezierPath(rect: rect).addClip()
        (value as NSString).draw(with: rect, options: [.usesLineFragmentOrigin, .truncatesLastVisibleLine],
            attributes: [.font: font, .foregroundColor: color, .paragraphStyle: paragraph(font: font, wraps: wraps)])
    }
}
