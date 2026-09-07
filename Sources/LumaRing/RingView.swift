import AppKit
import LumaRingCore

@MainActor final class RingView: NSView {
    var apps: [AppRecord] = []
    var windows: [WindowRecord] = []
    var appPage = 0
    var windowPage = 0
    var selectedApp: pid_t?
    var hoveredWindow: String?
    var message = L10n.text("悬停应用", "Point at an app")
    var loading = false
    var options = Options()
    var onSelectApp: ((AppRecord) -> Void)?
    var onActivateApp: ((AppRecord) -> Void)?
    var onActivateWindow: ((WindowRecord) -> Void)?
    var onHoverWindow: ((WindowRecord?) -> Void)?
    var onClose: (() -> Void)?
    var onSettings: (() -> Void)?
    private var hoveredApp: pid_t?
    private var collapseWork: DispatchWorkItem?
    private let diskMaterial = RingMaterial()
    private let diskArtwork = RingArtwork()
    private let arcArtwork = RingArtwork()
    private let arcGroup = NSView()

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        wantsLayer = true
        arcGroup.wantsLayer = true
        addSubview(diskMaterial)
        addSubview(arcGroup)
        arcGroup.addSubview(arcArtwork)
        addSubview(diskArtwork)
        diskArtwork.render = { [weak self] in self?.drawDisk() }
        arcArtwork.render = { [weak self] in self?.drawWindows() }
        arcGroup.isHidden = true
    }
    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    override func layout() {
        super.layout()
        diskMaterial.frame = bounds; diskArtwork.frame = bounds
        arcGroup.frame = bounds; arcArtwork.frame = bounds
        diskMaterial.setShape(surfacePath)
    }

    override func viewDidChangeEffectiveAppearance() {
        super.viewDidChangeEffectiveAppearance()
        refreshArtwork()
    }

    var showsWindowArc: Bool { selectedApp != nil && windows.count > 1 }
    var arcAnchor: Double {
        let index = visibleApps.firstIndex { $0.pid == selectedApp } ?? 0
        return RingGeometry.angle(index: index, count: visibleApps.count)
    }
    var surfacePath: CGPath {
        RingGeometry.surfacePath(windowCount: showsWindowArc ? visibleWindows.count : 0, anchor: arcAnchor)
    }
    var occupiedScreenFrame: CGRect {
        guard let window else { return .zero }
        return window.convertToScreen(convert(surfacePath.boundingBoxOfPath, to: nil))
    }
    func windowScreenFrame(_ id: String) -> CGRect? {
        guard let window, let index = visibleWindows.firstIndex(where: { $0.id == id }) else { return nil }
        let p = windowPoint(index)
        return window.convertToScreen(convert(NSRect(x: p.x - 35, y: p.y - 29, width: 70, height: 58), to: nil))
    }
    var appPageSize: Int { min(24, max(4, options.appPageSize)) }
    var windowPageSize: Int {
        min(RingGeometry.windowPageSizeRange.upperBound, max(RingGeometry.windowPageSizeRange.lowerBound, options.windowPageSize))
    }
    var appIconSize: Double { min(34, 2 * RingGeometry.appRadius * sin(.pi / Double(max(visibleApps.count, 2))) * 0.76) }
    private var arcPath: CGPath { RingGeometry.arcPath(count: visibleWindows.count, anchor: arcAnchor) }
    private var appPages: Int { RingGeometry.pageCount(total: apps.count, size: appPageSize) }
    private var windowPages: Int { RingGeometry.pageCount(total: windows.count, size: windowPageSize) }
    private func windowPoint(_ index: Int) -> CGPoint {
        RingGeometry.point(angle: RingGeometry.arcAngle(index: index, count: visibleWindows.count, anchor: arcAnchor), radius: RingGeometry.windowRadius)
    }
    private func windowIndex(at point: CGPoint) -> Int? {
        guard showsWindowArc else { return nil }
        return RingGeometry.arcIndex(at: point, count: visibleWindows.count, anchor: arcAnchor)
    }

    private var tracking: NSTrackingArea?
    private var scrollTime = 0.0

    override var acceptsFirstResponder: Bool { true }
    override var isOpaque: Bool { false }
    override func hitTest(_ point: NSPoint) -> NSView? {
        bounds.contains(convert(point, from: superview)) ? self : nil
    }
    var visibleApps: [AppRecord] {
        Array(apps[RingGeometry.pageRange(page: appPage, total: apps.count, size: appPageSize)])
    }
    var visibleWindows: [WindowRecord] {
        guard showsWindowArc else { return [] }
        return Array(windows[RingGeometry.pageRange(page: windowPage, total: windows.count, size: windowPageSize)])
    }
    var secondaryName: String { options.contentMode(for: currentApp?.bundleID ?? "").title }
    var currentApp: AppRecord? { apps.first { $0.pid == selectedApp } }
    var currentWindow: WindowRecord? { windows.first { $0.id == hoveredWindow } }

    func reset(apps: [AppRecord], options: Options) {
        cancelHover()
        onHoverWindow?(nil)
        self.apps = apps; self.options = options
        windows = []; appPage = 0; windowPage = 0
        selectedApp = nil; hoveredApp = nil; hoveredWindow = nil
        message = apps.isEmpty ? L10n.text("没有可切换的应用", "No apps available") : L10n.text("悬停应用", "Point at an app")
        loading = false
        refresh()
    }

    func cancelHover() {
        collapseWork?.cancel(); collapseWork = nil
    }

    func select(_ app: AppRecord) {
        cancelHover()
        guard selectedApp != app.pid else { return }
        selectedApp = app.pid; windows = []; windowPage = 0
        hoveredWindow = nil
        loading = true; message = ""
        onHoverWindow?(nil)
        onSelectApp?(app)
        refresh()
    }

    func setWindows(_ result: WindowResult, for pid: pid_t) {
        guard selectedApp == pid else { return }
        loading = false
        switch result {
        case .ready(let all, let limited):
            windows = all.filter { options.includeMinimized || !$0.minimized }
            message = limited ? L10n.text("已载入 \(windows.count) 个\(secondaryName) · 应用响应较慢，请重新呼出刷新", "Loaded \(windows.count) \(secondaryName.lowercased()) · Reopen to refresh") : (windows.count > 1 ? L10n.text("\(windows.count) 个\(secondaryName)", "\(windows.count) \(secondaryName.lowercased())") : L10n.text("点击切换", "Click to switch"))
        case .permissionRequired:
            windows = []; message = L10n.text("点击中心授权", "Click center for access")
        case .unavailable(let text):
            windows = []; message = text
        }
        refresh()
    }

    func refresh() {
        arcGroup.isHidden = !showsWindowArc
        arcGroup.frame = bounds
        diskMaterial.setShape(surfacePath)
        refreshArtwork()
        rebuildAccessibility()
    }

    func refreshArtwork() {
        diskArtwork.needsDisplay = true
        arcArtwork.needsDisplay = true
    }

    override func updateTrackingAreas() {
        if let tracking { removeTrackingArea(tracking) }
        let area = NSTrackingArea(rect: .zero, options: [.activeAlways, .mouseMoved, .mouseEnteredAndExited, .inVisibleRect], owner: self)
        addTrackingArea(area); tracking = area
        super.updateTrackingAreas()
    }

    private func point(_ event: NSEvent) -> CGPoint { convert(event.locationInWindow, from: nil) }

    override func mouseMoved(with event: NSEvent) { updateHover(at: point(event)) }

    func updateHover(at p: CGPoint) {
        if let index = RingGeometry.index(at: p, count: visibleApps.count, inner: RingGeometry.appInner, outer: RingGeometry.appOuter) {
            collapseWork?.cancel(); collapseWork = nil
            let app = visibleApps[index]
            if hoveredApp != app.pid { hoveredApp = app.pid; refreshArtwork() }
            if hoveredWindow != nil { setHoveredWindow(nil) }
            if selectedApp != app.pid { select(app) }
        } else {
            if let index = windowIndex(at: p) {
                collapseWork?.cancel(); collapseWork = nil
                setHoveredWindow(visibleWindows[index])
            } else {
                let radius = hypot(p.x - RingGeometry.center.x, p.y - RingGeometry.center.y)
                let angle = atan2(p.y - RingGeometry.center.y, p.x - RingGeometry.center.x)
                let distance = abs(atan2(sin(angle - arcAnchor), cos(angle - arcAnchor)))
                let pageControl = showsWindowArc && windowPages > 1 && CGRect(x: RingGeometry.center.x - 50, y: RingGeometry.center.y - 49, width: 100, height: 28).contains(p)
                let bridge = pageControl || (showsWindowArc && radius >= RingGeometry.appOuter && radius <= RingGeometry.windowOuter
                    && distance <= Double(visibleWindows.count) * RingGeometry.arcStep / 2 + 0.12
                )
                if !bridge {
                    if hoveredApp != nil { hoveredApp = nil; refreshArtwork() }
                    setHoveredWindow(nil)
                    if selectedApp != nil && collapseWork == nil {
                        let work = DispatchWorkItem { [weak self] in self?.clearSelection() }
                        collapseWork = work
                        DispatchQueue.main.asyncAfter(deadline: .now() + 0.20, execute: work)
                    }
                } else { collapseWork?.cancel(); collapseWork = nil }
            }
        }
    }

    func clearSelection() {
        cancelHover()
        selectedApp = nil; hoveredApp = nil; windows = []; hoveredWindow = nil
        loading = false; message = L10n.text("悬停应用", "Point at an app")
        onHoverWindow?(nil)
        refresh()
    }

    override func mouseExited(with event: NSEvent) { clearSelection() }

    private func setHoveredWindow(_ window: WindowRecord?) {
        guard hoveredWindow != window?.id else { return }
        hoveredWindow = window?.id
        onHoverWindow?(window)
        refreshArtwork()
    }

    override func mouseDown(with event: NSEvent) { activate(at: point(event)) }

    func activate(at p: CGPoint) {
        if let index = windowIndex(at: p) {
            onActivateWindow?(visibleWindows[index]); return
        }
        if let index = RingGeometry.index(at: p, count: visibleApps.count, inner: RingGeometry.appInner, outer: RingGeometry.appOuter) {
            let app = visibleApps[index]
            if selectedApp == app.pid, windows.count == 1 { onActivateWindow?(windows[0]) }
            else { onActivateApp?(app) }
            return
        }
        let radius = hypot(p.x - RingGeometry.center.x, p.y - RingGeometry.center.y)
        if radius < RingGeometry.appInner {
            if p.y < RingGeometry.center.y - 22 {
                if showsWindowArc && windowPages > 1 { changeWindowPage(p.x < RingGeometry.center.x ? -1 : 1) }
                else if appPages > 1 { changeAppPage(p.x < RingGeometry.center.x ? -1 : 1) }
            } else if !AXIsProcessTrusted() { onSettings?() }
            return
        }
        onClose?()
    }

    override func rightMouseDown(with event: NSEvent) { onSettings?() }

    override func scrollWheel(with event: NSEvent) {
        guard abs(event.scrollingDeltaY) > 0.1 || abs(event.scrollingDeltaX) > 0.1 else { return }
        let now = ProcessInfo.processInfo.systemUptime
        guard now - scrollTime > 0.22, event.momentumPhase == [] else { return }
        scrollTime = now
        let p = point(event)
        let delta = event.scrollingDeltaY != 0 ? event.scrollingDeltaY : event.scrollingDeltaX
        let direction = delta < 0 ? 1 : -1
        if hypot(p.x - RingGeometry.center.x, p.y - RingGeometry.center.y) >= RingGeometry.windowInner, showsWindowArc {
            changeWindowPage(direction)
        } else { changeAppPage(direction) }
    }

    func changeAppPage(_ direction: Int) {
        guard RingGeometry.pageCount(total: apps.count, size: appPageSize) > 1 else { return }
        cancelHover()
        appPage = RingGeometry.wrapped(appPage + direction, count: RingGeometry.pageCount(total: apps.count, size: appPageSize))
        selectedApp = nil; hoveredApp = nil; windows = []; hoveredWindow = nil
        loading = false
        onHoverWindow?(nil); message = L10n.text("悬停应用", "Point at an app")
        refresh()
    }

    func changeWindowPage(_ direction: Int) {
        guard windowPages > 1 else { return }
        windowPage = RingGeometry.wrapped(windowPage + direction, count: windowPages)
        setHoveredWindow(nil); refresh()
    }

    // Selection is intentionally mouse-only. Text, arrows and numeric keys do not alter it.
    override func keyDown(with event: NSEvent) {}

    func activateHovered() {
        if let window = currentWindow { onActivateWindow?(window) }
        else if let pid = hoveredApp, let app = apps.first(where: { $0.pid == pid }) {
            if selectedApp == pid, windows.count == 1 { onActivateWindow?(windows[0]) }
            else { onActivateApp?(app) }
        } else { onClose?() }
    }

    private var ink: NSColor { .labelColor }
    private var muted: NSColor { .secondaryLabelColor }
    private var accent: NSColor { .controlAccentColor }
    private var dark: Bool { effectiveAppearance.bestMatch(from: [.aqua, .darkAqua]) == .darkAqua }

    private func drawDisk() {
        for (index, app) in visibleApps.enumerated() {
            let active = app.pid == (hoveredApp ?? selectedApp)
            let p = RingGeometry.point(angle: RingGeometry.angle(index: index, count: visibleApps.count), radius: RingGeometry.appRadius)
            let size = appIconSize
            if active {
                let tileSize = min(48, size + 12)
                let tile = NSBezierPath(roundedRect: NSRect(x: p.x - tileSize / 2, y: p.y - tileSize / 2, width: tileSize, height: tileSize), xRadius: 11, yRadius: 11)
                NSColor.labelColor.withAlphaComponent(dark ? 0.16 : 0.07).setFill(); tile.fill()
            }
            app.icon.draw(in: NSRect(x: p.x - size / 2, y: p.y - size / 2, width: size, height: size), from: .zero, operation: .sourceOver, fraction: 1)
        }
        drawCenter()
    }

    private func drawWindows() {
        guard showsWindowArc else { return }
        for (index, win) in visibleWindows.enumerated() {
            let selected = win.id == hoveredWindow
            let p = windowPoint(index)
            if selected {
                let highlight = NSBezierPath(roundedRect: NSRect(x: p.x - 35, y: p.y - 29, width: 70, height: 58), xRadius: 13, yRadius: 13)
                NSGraphicsContext.saveGraphicsState()
                NSGraphicsContext.current?.cgContext.addPath(arcPath)
                NSGraphicsContext.current?.cgContext.clip()
                NSColor.labelColor.withAlphaComponent(dark ? 0.13 : 0.07).setFill(); highlight.fill()
                NSGraphicsContext.restoreGraphicsState()
            }
            let symbol = win.tab != nil ? "globe" : win.minimized ? "minus.rectangle" : (win.fullscreen ? "arrow.up.left.and.arrow.down.right" : "macwindow")
            drawSymbol(symbol, rect: NSRect(x: p.x - 9, y: p.y + 7, width: 18, height: 16), color: selected ? accent : muted)
            drawText(win.title, rect: NSRect(x: p.x - 36, y: p.y - 24, width: 72, height: 28), font: .systemFont(ofSize: 10, weight: selected ? .medium : .regular), color: ink, lines: 2)
        }
    }

    private func drawCenter() {
        let c = RingGeometry.center
        let app = apps.first { $0.pid == hoveredApp } ?? currentApp
        let name = app?.name ?? (apps.isEmpty ? L10n.text("暂无应用", "No apps") : L10n.text("应用", "Apps"))
        drawText(name, rect: NSRect(x: c.x - 49, y: c.y + 2, width: 98, height: 28), font: .systemFont(ofSize: 12, weight: .medium), color: ink, lines: 2)
        let subtitle = loading ? "" : (app == nil ? L10n.text("悬停选择", "Point to select") : message)
        drawText(subtitle, rect: NSRect(x: c.x - 50, y: c.y - 18, width: 100, height: 24), font: .systemFont(ofSize: 9), color: muted, lines: 2)
        if (showsWindowArc && windowPages > 1) || appPages > 1 {
            drawSymbol("chevron.left", rect: NSRect(x: c.x - 40, y: c.y - 39, width: 6, height: 9), color: muted)
            drawSymbol("chevron.right", rect: NSRect(x: c.x + 34, y: c.y - 39, width: 6, height: 9), color: muted)
            let page = showsWindowArc && windowPages > 1 ? "\(secondaryName) \(windowPage + 1)/\(windowPages)" : L10n.text("应用 \(appPage + 1)/\(appPages)", "Apps \(appPage + 1)/\(appPages)")
            drawText(page, rect: NSRect(x: c.x - 30, y: c.y - 41, width: 60, height: 13), font: .systemFont(ofSize: 8), color: muted)
        }
    }

    private func drawText(_ text: String, rect: NSRect, font: NSFont, color: NSColor, lines: Int = 1) {
        let paragraph = NSMutableParagraphStyle()
        paragraph.alignment = .center
        paragraph.lineBreakMode = lines > 1 ? .byWordWrapping : .byTruncatingTail
        paragraph.maximumLineHeight = font.pointSize + 3
        (text as NSString).draw(with: rect, options: [.usesLineFragmentOrigin, .truncatesLastVisibleLine], attributes: [.font: font, .foregroundColor: color, .paragraphStyle: paragraph])
    }

    private func drawSymbol(_ name: String, rect: NSRect, color: NSColor) {
        guard let image = NSImage(systemSymbolName: name, accessibilityDescription: nil)?.withSymbolConfiguration(.init(paletteColors: [color])) else { return }
        image.draw(in: rect)
    }

    private func rebuildAccessibility() {
        guard let window else { return }
        var items: [RingAccessibleItem] = []
        func add(_ label: String, help: String, rect: NSRect, action: @escaping () -> Void) {
            let item = RingAccessibleItem()
            item.setAccessibilityRole(.button)
            item.setAccessibilityEnabled(true)
            item.setAccessibilityLabel(label)
            item.setAccessibilityHelp(help)
            item.setAccessibilityParent(self)
            item.setAccessibilityFrame(window.convertToScreen(convert(rect, to: nil)))
            item.action = action; items.append(item)
        }
        for (i, app) in visibleApps.enumerated() {
            let p = RingGeometry.point(angle: RingGeometry.angle(index: i, count: visibleApps.count), radius: RingGeometry.appRadius)
            add(app.name, help: L10n.text("有多个\(secondaryName)时展开圆弧；松开呼出快捷键或点击即可切换。", "Show available windows or tabs. Click or release the invocation shortcut to switch."), rect: NSRect(x: p.x - 24, y: p.y - 24, width: 48, height: 48)) { [weak self] in self?.select(app) }
        }
        for (i, win) in visibleWindows.enumerated() {
            let p = windowPoint(i)
            add(win.title + (win.minimized ? L10n.text("，已最小化", ", minimized") : ""), help: L10n.text("切换到此\(secondaryName)", "Switch to this item"), rect: NSRect(x: p.x - 35, y: p.y - 29, width: 70, height: 58)) { [weak self] in self?.onActivateWindow?(win) }
        }
        let c = RingGeometry.center
        if showsWindowArc && windowPages > 1 {
            add(L10n.text("上一页\(secondaryName)", "Previous \(secondaryName.lowercased())"), help: L10n.text("圆弧滚动翻页", "Scroll over the arc to change pages"), rect: NSRect(x: c.x - 48, y: c.y - 47, width: 46, height: 24)) { [weak self] in self?.changeWindowPage(-1) }
            add(L10n.text("下一页\(secondaryName)", "Next \(secondaryName.lowercased())"), help: L10n.text("圆弧滚动翻页", "Scroll over the arc to change pages"), rect: NSRect(x: c.x + 2, y: c.y - 47, width: 46, height: 24)) { [weak self] in self?.changeWindowPage(1) }
        } else if appPages > 1 {
            add(L10n.text("上一页应用", "Previous apps"), help: L10n.text("滚动或点击翻页", "Scroll or click to change pages"), rect: NSRect(x: c.x - 48, y: c.y - 47, width: 46, height: 24)) { [weak self] in self?.changeAppPage(-1) }
            add(L10n.text("下一页应用", "Next apps"), help: L10n.text("滚动或点击翻页", "Scroll or click to change pages"), rect: NSRect(x: c.x + 2, y: c.y - 47, width: 46, height: 24)) { [weak self] in self?.changeAppPage(1) }
        }
        add(L10n.text("设置", "Settings"), help: L10n.text("右键圆盘打开设置", "Right-click the ring to open settings"), rect: NSRect(x: c.x - 35, y: c.y - 16, width: 70, height: 42)) { [weak self] in self?.onSettings?() }
        setAccessibilityElement(false)
        setAccessibilityChildren(items)
    }
}

final class RingAccessibleItem: NSAccessibilityElement {
    var action: (() -> Void)?
    override func accessibilityPerformPress() -> Bool { action?(); return true }
}
