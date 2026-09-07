import AppKit
import LumaRingCore

@MainActor final class WindowPreview {
    private let panel: NSPanel
    let view = WindowPreviewView()
    init() {
        panel = NSPanel(contentRect: NSRect(x: 0, y: 0, width: 840, height: 630), styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false)
        panel.level = NSWindow.Level(rawValue: NSWindow.Level.popUpMenu.rawValue + 1)
        panel.isOpaque = false; panel.backgroundColor = .clear; panel.hasShadow = true
        panel.ignoresMouseEvents = true
        panel.hidesOnDeactivate = false
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .ignoresCycle, .stationary]
        panel.isReleasedWhenClosed = false
        panel.contentView = view
    }
    func show(window: WindowRecord, image: NSImage?, message: String, anchor: CGRect, occupied: CGRect, screen: CGRect, preferredSize: CGSize) {
        let frame = PreviewPlacement.frame(anchor: anchor, avoiding: occupied, screen: screen, preferredSize: preferredSize)
        view.title = window.title; view.image = image; view.message = message
        panel.setFrame(frame, display: false)
        view.frame = NSRect(origin: .zero, size: frame.size)
        view.needsDisplay = true
        panel.orderFrontRegardless()
    }
    var capturePixelSize: CGSize {
        CGSize(width: max(1, view.bounds.width - 24) * panel.backingScaleFactor,
               height: max(1, view.bounds.height - 76) * panel.backingScaleFactor)
    }
    func dismiss() {
        panel.orderOut(nil)
        view.image = nil; view.title = ""; view.message = ""
    }
}

@MainActor final class WindowPreviewView: NSView {
    var image: NSImage?
    var title = ""
    var message = ""
    override var isOpaque: Bool { false }
    override func viewDidChangeEffectiveAppearance() { super.viewDidChangeEffectiveAppearance(); needsDisplay = true }
    override func draw(_ dirtyRect: NSRect) {
        let dark = effectiveAppearance.bestMatch(from: [.aqua, .darkAqua]) == .darkAqua
        (dark ? NSColor.black : NSColor.white).setFill()
        NSBezierPath(roundedRect: bounds, xRadius: 16, yRadius: 16).fill()
        let paragraph = NSMutableParagraphStyle()
        paragraph.lineBreakMode = .byTruncatingTail
        (title as NSString).draw(with: NSRect(x: 18, y: bounds.height - 57, width: bounds.width - 36, height: 39),
                                options: [.usesLineFragmentOrigin, .truncatesLastVisibleLine],
                                attributes: [.font: NSFont.systemFont(ofSize: 14, weight: .medium), .foregroundColor: NSColor.labelColor, .paragraphStyle: paragraph])
        let area = NSRect(x: 12, y: 12, width: bounds.width - 24, height: bounds.height - 76)
        NSColor.labelColor.withAlphaComponent(0.035).setFill()
        NSBezierPath(roundedRect: area, xRadius: 8, yRadius: 8).fill()
        if let image, image.size.width > 0, image.size.height > 0 {
            let scale = min(area.width / image.size.width, area.height / image.size.height)
            let size = NSSize(width: image.size.width * scale, height: image.size.height * scale)
            let rect = NSRect(x: area.midX - size.width / 2, y: area.midY - size.height / 2, width: size.width, height: size.height)
            NSGraphicsContext.saveGraphicsState()
            NSBezierPath(roundedRect: area, xRadius: 8, yRadius: 8).addClip()
            image.draw(in: rect)
            NSGraphicsContext.restoreGraphicsState()
        } else {
            paragraph.alignment = .center
            paragraph.lineBreakMode = .byWordWrapping
            (message as NSString).draw(with: NSRect(x: area.minX + 28, y: area.midY - 30, width: area.width - 56, height: 60),
                                      options: [.usesLineFragmentOrigin],
                                      attributes: [.font: NSFont.systemFont(ofSize: 13), .foregroundColor: NSColor.secondaryLabelColor, .paragraphStyle: paragraph])
        }
    }
}
