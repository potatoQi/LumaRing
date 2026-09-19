import AppKit
import LumaRingCore

@MainActor final class ActionPanel: NSPanel {
    override var canBecomeKey: Bool { false }
    override var canBecomeMain: Bool { false }

    // Reuse the ordinary ring's launcher in this non-key panel. Neither surface
    // changes input focus, and the action page/selection snapshot stays intact.
    func setLauncherVisible(_ show: Bool, launcher: RingView, actions: ActionRingView, restoreTo panel: NSPanel?) {
        if show {
            guard contentView !== launcher else { return }
            launcher.launcherInnerArtwork = { [weak actions] paging in
                actions?.drawRing(inactive: true, launcherPaging: paging)
            }
            panel?.contentView = nil
            contentView = launcher
            launcher.frame = NSRect(origin: .zero, size: frame.size)
            launcher.bounds = NSRect(x: 0, y: 0, width: RingGeometry.canvas, height: RingGeometry.canvas)
            launcher.refresh()
        } else if contentView === launcher {
            launcher.launcherInnerArtwork = nil
            contentView = actions
            panel?.contentView = launcher
            actions.frame = NSRect(origin: .zero, size: frame.size)
            actions.bounds = NSRect(x: 0, y: 0, width: RingGeometry.canvas, height: RingGeometry.canvas)
            launcher.bounds = NSRect(x: 0, y: 0, width: RingGeometry.canvas, height: RingGeometry.canvas)
            actions.refresh()
        }
    }
}

@MainActor final class ActionRingView: NSView {
    var actions: [AppAction] = []
    var appName = ""
    var icon: NSImage?
    var ready = false
    var message = ""
    var acceptsPointerEvent: ((NSEvent) -> Bool)?
    var onPointerInteraction: (() -> Void)?
    var onAction: ((AppAction) -> Void)?
    var onClose: (() -> Void)?
    var onSettings: (() -> Void)?
    private(set) var page = 0
    private var hover: String?
    private var pressed: String?
    private var pressPoint: CGPoint?
    private var tracking: NSTrackingArea?
    private var scrollTime = 0.0
    private let material = RingMaterial()
    private let artwork = RingArtwork()
    var isPointerDown: Bool { pressPoint != nil }
    var visible: [AppAction] { Array(actions[RingGeometry.pageRange(page: page, total: actions.count, size: 6)]) }
    private var pages: Int { RingGeometry.pageCount(total: actions.count, size: 6) }
    private let pageRect = CGRect(x: 214, y: 207, width: 52, height: 15)
    override var acceptsFirstResponder: Bool { false }
    override var needsPanelToBecomeKey: Bool { false }
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }
    override func hitTest(_ point: NSPoint) -> NSView? { bounds.contains(convert(point, from: superview)) ? self : nil }

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        addSubview(material); material.content.addSubview(artwork)
        artwork.render = { [weak self] in self?.drawRing() }
    }
    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }
    override func layout() {
        super.layout()
        material.frame = bounds; artwork.frame = bounds
        material.setShape(RingGeometry.surfacePath(windowCount: 0, anchor: 0))
    }
    override func updateTrackingAreas() {
        if let tracking { removeTrackingArea(tracking) }
        tracking = NSTrackingArea(rect: .zero, options: [.activeAlways, .mouseMoved, .mouseEnteredAndExited, .inVisibleRect], owner: self)
        addTrackingArea(tracking!)
        super.updateTrackingAreas()
    }
    override func viewDidChangeEffectiveAppearance() { super.viewDidChangeEffectiveAppearance(); refresh() }
    func reset() { page = 0; hover = nil; pressed = nil; pressPoint = nil; refresh() }
    func refresh() {
        artwork.needsDisplay = true
        guard let window else { return }
        var items = visible.enumerated().map { index, action -> RingAccessibleItem in
            let item = RingAccessibleItem()
            let point = RingGeometry.point(angle: RingGeometry.angle(index: index, count: visible.count), radius: 82)
            item.setAccessibilityRole(.button); item.setAccessibilityLabel(action.displayName)
            item.setAccessibilityHelp(action.shortcut?.display ?? ""); item.setAccessibilityParent(self)
            item.setAccessibilityEnabled(ready)
            item.setAccessibilityFrame(window.convertToScreen(convert(CGRect(x: point.x - 32, y: point.y - 20, width: 64, height: 48), to: nil)))
            item.action = { [weak self] in if self?.ready == true { self?.onAction?(action) } }
            return item
        }
        func control(_ label: String, rect: CGRect, action: @escaping () -> Void) -> RingAccessibleItem {
            let item = RingAccessibleItem()
            item.setAccessibilityRole(.button); item.setAccessibilityLabel(label); item.setAccessibilityParent(self)
            item.setAccessibilityFrame(window.convertToScreen(convert(rect, to: nil)))
            item.action = action
            return item
        }
        if pages > 1 {
            items.append(control(L10n.text("上一页操作", "Previous actions"), rect: CGRect(x: 214, y: 207, width: 26, height: 15)) { [weak self] in self?.turnPage(-1) })
            items.append(control(L10n.text("下一页操作", "Next actions"), rect: CGRect(x: 240, y: 207, width: 26, height: 15)) { [weak self] in self?.turnPage(1) })
        }
        if actions.isEmpty {
            items.append(control(L10n.text("在设置的快捷操作中配置", "Configure in Settings → Actions"), rect: CGRect(x: 204, y: 220, width: 72, height: 35)) { [weak self] in self?.onSettings?() })
        }
        setAccessibilityChildren(items)
    }
    func target(at point: CGPoint) -> AppAction? {
        guard let index = RingGeometry.appIndex(at: point, count: visible.count) else { return nil }
        return visible[index]
    }
    func begin(at point: CGPoint) { onPointerInteraction?(); pressPoint = point; pressed = target(at: point)?.id }
    func end(at point: CGPoint) {
        let original = pressPoint, id = pressed
        pressPoint = nil; pressed = nil
        guard let original else { return }
        if let action = target(at: point), action.id == id {
            if ready { onAction?(action) }
        } else if id == nil, hypot(point.x - original.x, point.y - original.y) < 6 {
            if pageRect.contains(point), pages > 1 { turnPage(point.x < RingGeometry.center.x ? -1 : 1) }
            else if hypot(point.x - RingGeometry.center.x, point.y - RingGeometry.center.y) < RingGeometry.appInner, actions.isEmpty { onSettings?() }
            else if hypot(point.x - RingGeometry.center.x, point.y - RingGeometry.center.y) > RingGeometry.appOuter { onClose?() }
        }
    }
    func turnPage(_ direction: Int) {
        guard !isPointerDown else { return }
        page = RingGeometry.wrapped(page + direction, count: pages); hover = nil; refresh()
    }
    override func mouseDown(with event: NSEvent) { guard acceptsPointerEvent?(event) != false else { return }; begin(at: convert(event.locationInWindow, from: nil)) }
    override func mouseUp(with event: NSEvent) { guard acceptsPointerEvent?(event) != false else { return }; end(at: convert(event.locationInWindow, from: nil)) }
    override func mouseMoved(with event: NSEvent) {
        let value = target(at: convert(event.locationInWindow, from: nil))?.id
        if hover != value { hover = value; refresh() }
    }
    override func mouseExited(with event: NSEvent) { hover = nil; refresh() }
    override func scrollWheel(with event: NSEvent) {
        guard event.momentumPhase == [], abs(event.scrollingDeltaY) > 0.1,
              event.timestamp - scrollTime > 0.22 else { return }
        scrollTime = event.timestamp; turnPage(event.scrollingDeltaY < 0 ? 1 : -1)
    }
    func drawRing(inactive: Bool = false, launcherPaging: Bool = false) {
        let dark = NSAppearance.currentDrawing().bestMatch(from: [.aqua, .darkAqua]) == .darkAqua
        if !inactive, let index = visible.firstIndex(where: { $0.id == hover }), let context = NSGraphicsContext.current?.cgContext {
            NSColor.controlAccentColor.withAlphaComponent(dark ? 0.25 : 0.12).setFill()
            context.addPath(RingGeometry.appSectorPath(index: index, count: visible.count)); context.fillPath()
        }
        for (index, action) in visible.enumerated() {
            let point = RingGeometry.point(angle: RingGeometry.angle(index: index, count: visible.count), radius: 82)
            text(action.displayName, rect: CGRect(x: point.x - 32, y: point.y - 2, width: 64, height: 30), size: 12,
                 color: ready && !inactive ? .labelColor : .secondaryLabelColor, wrap: true)
            text(action.shortcut?.display ?? "", rect: CGRect(x: point.x - 32, y: point.y - 20, width: 64, height: 16), size: 11,
                 color: ready && !inactive ? .labelColor : .secondaryLabelColor, weight: .medium)
        }
        RingCenterLabel.draw(title: appName, detail: message, paging: inactive ? launcherPaging : pages > 1, icon: icon)
        if !inactive, pages > 1 { RingCenterLabel.page("‹  \(page + 1)/\(pages)  ›", in: pageRect) }
    }
    private func text(_ value: String, rect: CGRect, size: CGFloat, color: NSColor, wrap: Bool = false, weight: NSFont.Weight = .regular) {
        let paragraph = NSMutableParagraphStyle(); paragraph.alignment = .center
        paragraph.lineBreakMode = wrap ? .byWordWrapping : .byTruncatingTail
        NSGraphicsContext.saveGraphicsState()
        defer { NSGraphicsContext.restoreGraphicsState() }
        NSBezierPath(rect: rect).addClip()
        (value as NSString).draw(in: rect, withAttributes: [.font: NSFont.systemFont(ofSize: size, weight: weight), .foregroundColor: color, .paragraphStyle: paragraph])
    }
}
