import AppKit
import LumaRingCore

@MainActor final class RingView: NSView {
    var apps: [AppRecord] = []
    var windows: [WindowRecord] = []
    var appPage = 0
    var windowPage = 0
    var closingWindowIDs: Set<String> = []
    var keepsSingleWindowArc = false
    var selectedApp: pid_t?
    var hoveredWindow: String?
    var message = L10n.text("悬停应用", "Point at an app")
    var loading = false
    var options = Options()
    var onSelectApp: ((AppRecord) -> Void)?
    var onActivateApp: ((AppRecord) -> Void)?
    var onActivateWindow: ((WindowRecord) -> Void)?
    var onCloseWindow: ((WindowRecord) -> Void)?
    var launcherApps: [LauncherRecord] = []
    var launcherPage = 0
    var hoveredLauncher: String?
    var showsLauncher = false
    var optionPressed = false
    var launcherPinned = false
    var launcherInnerArtwork: ((Bool) -> Void)?
    var centerClickWork: DispatchWorkItem?
    private(set) var invocationClickDeadline: TimeInterval = 0
    var isContextMenuOpen = false
    var isEditingName = false
    var afterContextMenu: (() -> Void)?
    var makeWindowMenu: ((WindowRecord) -> NSMenu)?
    var onLaunchApp: ((LauncherApp) -> Void)?
    var onLauncherModeEntered: (() -> Void)?
    var makeAppMenu: ((AppRecord) -> NSMenu)?
    var onQuitApp: ((AppRecord) -> Void)?
    var onPointerInteraction: (() -> Void)?
    var onHoverWindow: ((WindowRecord?) -> Void)?
    var onClose: (() -> Void)?
    var onSettings: (() -> Void)?
    var onVisibleAppsChanged: (() -> Void)?
    private(set) var itemCounts: [pid_t: AppItemCount] = [:]
    private var countsFromSelection: Set<pid_t> = []
    private var hoveredApp: pid_t?
    private var collapseWork: DispatchWorkItem?
    private enum PressTarget {
        case app(AppRecord, WindowRecord?, draggable: Bool)
        case window(WindowRecord)
        case close(WindowRecord)
        case background
        case launcher(LauncherRecord)
        case inactive
    }
    private var pressTarget: PressTarget?
    private var pressPoint = CGPoint.zero
    private var dragPoint = CGPoint.zero
    private(set) var isDraggingApp = false
    private var hoveredClose: String?
    var isPointerDown: Bool { pressTarget != nil }
    var dragWillQuit: Bool {
        isDraggingApp && hypot(dragPoint.x - RingGeometry.center.x, dragPoint.y - RingGeometry.center.y) > RingGeometry.appOuter + 18
    }
    private var draggedApp: AppRecord? {
        guard isDraggingApp, case .app(let app, _, _) = pressTarget else { return nil }
        return app
    }
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

    var showsWindowArc: Bool { !showsLauncher && !isDraggingApp && selectedApp != nil && (windows.count > 1 || (keepsSingleWindowArc && !windows.isEmpty)) }
    var arcAnchor: Double {
        let index = visibleApps.firstIndex { $0.pid == selectedApp } ?? 0
        return RingGeometry.angle(index: index, count: visibleApps.count)
    }
    var surfacePath: CGPath {
        if showsLauncher {
            return CGPath(ellipseIn: CGRect(x: 42, y: 42, width: 396, height: 396), transform: nil)
        }
        return RingGeometry.surfacePath(windowCount: showsWindowArc ? visibleWindows.count : 0, anchor: arcAnchor)
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
        guard showsWindowArc,
              hypot(point.x - RingGeometry.center.x, point.y - RingGeometry.center.y) > RingGeometry.appOuter else { return nil }
        return RingGeometry.arcIndex(at: point, count: visibleWindows.count, anchor: arcAnchor)
    }

    func closeButtonRect(at index: Int) -> CGRect {
        let p = windowPoint(index)
        return CGRect(x: p.x + 16, y: p.y + 10, width: 18, height: 18)
    }

    private func closeTarget(at point: CGPoint) -> WindowRecord? {
        visibleWindows.enumerated().first { closeButtonRect(at: $0.offset).contains(point) }?.element
    }

    private func appTarget(at point: CGPoint) -> AppRecord? {
        guard let index = RingGeometry.appIndex(at: point, count: visibleApps.count) else { return nil }
        return visibleApps[index]
    }

    private var pageControlsRect: CGRect {
        CGRect(x: RingGeometry.center.x - 22, y: RingGeometry.center.y - 32, width: 44, height: 14)
    }
    var highlightedApp: pid_t? {
        hoveredApp ?? ((hoveredWindow != nil || hoveredClose != nil) ? selectedApp : nil)
    }

    private var tracking: NSTrackingArea?
    private var scrollTime = 0.0

    override var acceptsFirstResponder: Bool { !(window is ActionPanel) }
    override var needsPanelToBecomeKey: Bool { window is ActionPanel ? false : super.needsPanelToBecomeKey }
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool {
        window is ActionPanel || super.acceptsFirstMouse(for: event)
    }
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
        invocationClickDeadline = 0
        keepsSingleWindowArc = false; closingWindowIDs.removeAll()
        centerClickWork?.cancel(); centerClickWork = nil
        launcherPinned = false
        cancelHover()
        cancelPointerInteraction()
        onHoverWindow?(nil)
        self.apps = apps; self.options = options
        showsLauncher = false; optionPressed = false; launcherApps = []; launcherPage = 0; hoveredLauncher = nil
        itemCounts.removeAll()
        countsFromSelection.removeAll()
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
        guard !showsLauncher, !isEditingName else { return }
        cancelHover()
        if hoveredApp != app.pid { hoveredApp = app.pid; refreshArtwork() }
        guard selectedApp != app.pid else { return }
        keepsSingleWindowArc = false
        selectedApp = app.pid; windows = []; windowPage = 0
        hoveredWindow = nil
        loading = true; message = ""
        onHoverWindow?(nil)
        onSelectApp?(app)
        refresh()
    }

    func setWindows(_ result: WindowResult, for pid: pid_t) {
        guard !showsLauncher, !isEditingName, selectedApp == pid else { return }
        // A direct hover query takes precedence over a potentially older page-count response.
        countsFromSelection.insert(pid)
        itemCounts[pid] = AppItemCount(result, includeMinimized: options.includeMinimized)
        loading = false
        switch result {
        case .ready(let all, let limited):
            windows = WindowRecord.sortedByName(all.filter { options.includeMinimized || !$0.minimized })
            windowPage = min(windowPage, max(0, windowPages - 1))
            if let hoveredWindow, !windows.contains(where: { $0.id == hoveredWindow }) { setHoveredWindow(nil) }
            if let hoveredClose, !windows.contains(where: { $0.id == hoveredClose }) { self.hoveredClose = nil }
            message = limited ? L10n.text("已载入 \(windows.count) 个\(secondaryName) · 应用响应较慢，请重新呼出刷新", "Loaded \(windows.count) \(secondaryName.lowercased()) · Reopen to refresh") : (windows.count > 1 ? L10n.text("\(windows.count) 个\(secondaryName)", "\(windows.count) \(secondaryName.lowercased())") : L10n.text("点击切换", "Click to switch"))
            if windows.isEmpty { message = L10n.text("没有可用的窗口或标签页", "No windows or tabs available") }
        case .permissionRequired:
            windows = []; message = L10n.text("点击中心授权", "Click center for access")
        case .unavailable(let text):
            windows = []; message = text
        }
        refresh()
    }

    func removeClosedWindow(_ record: WindowRecord) {
        guard selectedApp == record.pid, windows.contains(where: { $0.id == record.id }) else { return }
        cancelHover()
        switch pressTarget {
        case .window(let pressed), .close(let pressed):
            if pressed.id == record.id { cancelPointerInteraction() }
        case .app(_, let single, _):
            if single?.id == record.id { cancelPointerInteraction() }
        default: break
        }
        setHoveredWindow(nil)
        windows.removeAll { $0.id == record.id }
        keepsSingleWindowArc = true
        windowPage = min(windowPage, max(0, windowPages - 1))
        countsFromSelection.insert(record.pid)
        itemCounts[record.pid] = AppItemCount(.ready(windows), includeMinimized: options.includeMinimized)
        message = windows.isEmpty ? L10n.text("没有可用的窗口或标签页", "No windows or tabs available") : "\(windows.count) \(secondaryName)"
        refresh()
    }

    func setItemCount(_ count: AppItemCount?, for pid: pid_t) {
        guard visibleApps.contains(where: { $0.pid == pid }), !countsFromSelection.contains(pid) else { return }
        guard itemCounts[pid] != count else { return }
        itemCounts[pid] = count
        refreshArtwork()
        rebuildAccessibility()
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
        if hypot(p.x - RingGeometry.center.x, p.y - RingGeometry.center.y) >= RingGeometry.appInner {
            centerClickWork?.cancel(); centerClickWork = nil
        }
        guard !isPointerDown, !isContextMenuOpen, !isEditingName else { return }
        if showsLauncher {
            let id = launcherTarget(at: p)?.app.id
            if id != hoveredLauncher { hoveredLauncher = id; refreshArtwork() }
            return
        }
        let close = closeTarget(at: p)
        if hoveredClose != close?.id { hoveredClose = close?.id; refreshArtwork() }
        if close != nil {
            cancelHover()
            setHoveredWindow(nil)
            return
        }
        if let index = RingGeometry.appIndex(at: p, count: visibleApps.count) {
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
                if radius < RingGeometry.appInner {
                    if hoveredApp != nil { hoveredApp = nil; refreshArtwork() }
                    setHoveredWindow(nil)
                }
                let pageControl = showsWindowArc && windowPages > 1 && pageControlsRect.contains(p)
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
        guard !isEditingName else { return }
        cancelHover()
        keepsSingleWindowArc = false
        selectedApp = nil; hoveredApp = nil; windows = []; hoveredWindow = nil; hoveredClose = nil
        loading = false; message = L10n.text("悬停应用", "Point at an app")
        onHoverWindow?(nil)
        refresh()
    }

    override func mouseExited(with event: NSEvent) {
        if showsLauncher { hoveredLauncher = nil; refreshArtwork() }
        else if !isPointerDown && !isContextMenuOpen && !isEditingName { clearSelection() }
    }

    private func setHoveredWindow(_ window: WindowRecord?) {
        guard hoveredWindow != window?.id else { return }
        hoveredWindow = window?.id
        onHoverWindow?(window)
        refreshArtwork()
    }

    func suppressInvocationClicks(at time: TimeInterval) {
        // Trackpad release can enqueue a synthetic secondary click after the ring
        // appears. Its timestamp, not its eventual delivery time, fences it out.
        invocationClickDeadline = time + 0.22
        centerClickWork?.cancel(); centerClickWork = nil
        cancelPointerInteraction()
    }

    func acceptsPointerEvent(_ event: NSEvent) -> Bool {
        invocationClickDeadline == 0 || event.timestamp > invocationClickDeadline
    }

    override func mouseDown(with event: NSEvent) {
        guard acceptsPointerEvent(event) else { return }
        beginPointer(at: point(event), clickCount: event.clickCount)
    }
    override func mouseDragged(with event: NSEvent) { movePointer(to: point(event)) }
    override func mouseUp(with event: NSEvent) {
        guard acceptsPointerEvent(event) else { return }
        endPointer(at: point(event))
    }

    func beginPointer(at p: CGPoint, clickCount: Int = 1) {
        guard !isEditingName else { return }
        centerClickWork?.cancel(); centerClickWork = nil
        // AppKit keeps counting rapid clicks at the same location (3, 4, ...).
        // Treat each completed pair as a double-click without requiring motion.
        if clickCount > 0, clickCount.isMultiple(of: 2), toggleLauncherFromCenter(at: p) { return }
        onPointerInteraction?()
        cancelPointerInteraction()
        cancelHover()
        pressPoint = p; dragPoint = p
        if showsLauncher {
            pressTarget = launcherTarget(at: p).map { .launcher($0) } ?? .inactive
            return
        }
        if let target = closeTarget(at: p) { pressTarget = .close(target) }
        else if let index = windowIndex(at: p) { pressTarget = .window(visibleWindows[index]) }
        else if let app = appTarget(at: p), let index = visibleApps.firstIndex(where: { $0.pid == app.pid }) {
            let center = RingGeometry.point(angle: RingGeometry.angle(index: index, count: visibleApps.count), radius: RingGeometry.appRadius)
            let hitSize = appIconSize + 12
            let icon = CGRect(x: center.x - hitSize / 2, y: center.y - hitSize / 2, width: hitSize, height: hitSize)
            let target = selectedApp == app.pid && windows.count == 1 ? windows[0] : nil
            pressTarget = .app(app, target, draggable: icon.contains(p))
        } else { pressTarget = .background }
        refreshArtwork()
    }

    func movePointer(to p: CGPoint) {
        guard case .app(_, _, let draggable) = pressTarget, draggable else { return }
        dragPoint = p
        if !isDraggingApp && hypot(p.x - pressPoint.x, p.y - pressPoint.y) >= 6 {
            isDraggingApp = true
            cancelHover()
            hoveredClose = nil
            setHoveredWindow(nil)
            refresh()
        }
        if isDraggingApp { refreshArtwork() }
    }

    func endPointer(at p: CGPoint) {
        guard let target = pressTarget else { return }
        movePointer(to: p)
        let dragged = isDraggingApp, quit = dragWillQuit
        if dragged, quit, case .app(let app, _, _) = target,
           apps.contains(where: { $0.pid == app.pid }), let onQuitApp {
            // Hand the drop straight to dismissal; don't restore/rebuild the arc
            // for one frame before the panel disappears.
            cancelPointerInteraction()
            onQuitApp(app)
            return
        }
        cancelPointerInteraction()
        refresh()
        switch target {
        case .app(let app, let singleWindow, _):
            guard apps.contains(where: { $0.pid == app.pid }) else { return }
            if dragged {
                if quit { onQuitApp?(app) }
                else { updateHover(at: p) }
            } else if appTarget(at: p)?.pid == app.pid {
                if let singleWindow { onActivateWindow?(singleWindow) }
                else { onActivateApp?(app) }
            }
        case .close(let record):
            if closeTarget(at: p)?.id == record.id { onCloseWindow?(record) }
        case .window(let record):
            if closeTarget(at: p) == nil, let index = windowIndex(at: p), visibleWindows[index].id == record.id {
                onActivateWindow?(record)
            }
        case .launcher(let record):
            if showsLauncher, record.available, launcherTarget(at: p)?.app.id == record.app.id { onLaunchApp?(record.app) }
        case .inactive:
            if showsLauncher, launcherTarget(at: p) == nil, hypot(p.x - pressPoint.x, p.y - pressPoint.y) < 6 { activateLauncher(at: p) }
        case .background:
            // A late hover response must not turn a background press into a new target.
            if hypot(p.x - pressPoint.x, p.y - pressPoint.y) < 6,
               closeTarget(at: pressPoint) == nil, windowIndex(at: pressPoint) == nil, appTarget(at: pressPoint) == nil {
                activate(at: pressPoint)
            }
        }
    }

    func cancelPointerInteraction() {
        pressTarget = nil
        isDraggingApp = false
        hoveredClose = nil
    }

    func activate(at p: CGPoint) {
        if showsLauncher { activateLauncher(at: p); return }
        if let target = closeTarget(at: p) { onCloseWindow?(target); return }
        if let index = windowIndex(at: p) {
            onActivateWindow?(visibleWindows[index]); return
        }
        if let index = RingGeometry.appIndex(at: p, count: visibleApps.count) {
            let app = visibleApps[index]
            if selectedApp == app.pid, windows.count == 1 { onActivateWindow?(windows[0]) }
            else { onActivateApp?(app) }
            return
        }
        let radius = hypot(p.x - RingGeometry.center.x, p.y - RingGeometry.center.y)
        if radius < RingGeometry.appInner {
            if pageControlsRect.contains(p) {
                if showsWindowArc && windowPages > 1 { changeWindowPage(p.x < RingGeometry.center.x ? -1 : 1) }
                else if appPages > 1 { changeAppPage(p.x < RingGeometry.center.x ? -1 : 1) }
            } else if !AXIsProcessTrusted() { scheduleCenterSettings() }
            return
        }
        onClose?()
    }

    func contextMenu(at p: CGPoint) -> NSMenu? {
        guard !showsLauncher, !isPointerDown, !isEditingName else { return nil }
        if let record = closeTarget(at: p) { return makeWindowMenu?(record) }
        if let index = windowIndex(at: p) { return makeWindowMenu?(visibleWindows[index]) }
        if let app = appTarget(at: p) { return makeAppMenu?(app) }
        return nil
    }

    func updateWindow(_ id: String, name: String, color: SectorColor?) {
        guard let index = windows.firstIndex(where: { $0.id == id }) else { return }
        cancelHover(); cancelPointerInteraction()
        setHoveredWindow(nil)
        windows[index].customName = WindowRecord.normalizedName(name)
        windows[index].customColor = color
        windows = WindowRecord.sortedByName(windows)
        if let position = windows.firstIndex(where: { $0.id == id }) { windowPage = position / windowPageSize }
        refresh()
    }

    override func rightMouseDown(with event: NSEvent) {
        guard acceptsPointerEvent(event) else { return }
        guard !showsLauncher, !isPointerDown, !isEditingName else { return }
        guard let menu = contextMenu(at: point(event)) else { onSettings?(); return }
        onPointerInteraction?()
        cancelHover()
        onHoverWindow?(nil)
        isContextMenuOpen = true
        NSMenu.popUpContextMenu(menu, with: event, for: self)
        isContextMenuOpen = false
        let action = afterContextMenu; afterContextMenu = nil
        action?()
        if isEditingName { return }
        // Modifier events can be consumed by menu tracking; reconcile once it ends.
        updateOption(pressed: NSEvent.modifierFlags.contains(.option), allowEntry: false)
        if window?.isVisible == true {
            // Do not steal focus back when menu cancellation came from another app.
            if window?.isKeyWindow == true { window?.makeFirstResponder(self) }
            else { onClose?() }
        }
    }

    override func flagsChanged(with event: NSEvent) {
        updateOption(pressed: event.modifierFlags.contains(.option))
    }

    override func scrollWheel(with event: NSEvent) {
        guard !isPointerDown, !isContextMenuOpen, !isEditingName else { return }
        guard abs(event.scrollingDeltaY) > 0.1 || abs(event.scrollingDeltaX) > 0.1 else { return }
        let now = ProcessInfo.processInfo.systemUptime
        guard now - scrollTime > 0.22, event.momentumPhase == [] else { return }
        scrollTime = now
        let p = point(event)
        let delta = event.scrollingDeltaY != 0 ? event.scrollingDeltaY : event.scrollingDeltaX
        let direction = delta < 0 ? 1 : -1
        if showsLauncher { changeLauncherPage(direction); return }
        if hypot(p.x - RingGeometry.center.x, p.y - RingGeometry.center.y) >= RingGeometry.windowInner, showsWindowArc {
            changeWindowPage(direction)
        } else { changeAppPage(direction) }
    }

    func changeAppPage(_ direction: Int) {
        guard !showsLauncher else { return }
        cancelPointerInteraction()
        guard RingGeometry.pageCount(total: apps.count, size: appPageSize) > 1 else { return }
        cancelHover()
        appPage = RingGeometry.wrapped(appPage + direction, count: RingGeometry.pageCount(total: apps.count, size: appPageSize))
        countsFromSelection.removeAll()
        keepsSingleWindowArc = false
        selectedApp = nil; hoveredApp = nil; windows = []; hoveredWindow = nil
        loading = false
        onHoverWindow?(nil); message = L10n.text("悬停应用", "Point at an app")
        refresh()
        onVisibleAppsChanged?()
    }

    func changeWindowPage(_ direction: Int) {
        cancelPointerInteraction()
        guard windowPages > 1 else { return }
        windowPage = RingGeometry.wrapped(windowPage + direction, count: windowPages)
        setHoveredWindow(nil); refresh()
    }

    // Selection stays mouse-only; Escape only cancels an in-progress pointer gesture.
    override func keyDown(with event: NSEvent) {
        if event.keyCode == 53, showsLauncher {
            endLauncherMode(); return
        }
        if event.keyCode == 53, isPointerDown {
            cancelPointerInteraction()
            refresh()
        }
    }

    func activateHovered() {
        guard !isEditingName, !showsLauncher, !isContextMenuOpen, !isPointerDown, hoveredClose == nil else { return }
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
        if showsLauncher, launcherInnerArtwork != nil { drawLauncher(); return }
        if !isDraggingApp, let pid = highlightedApp, let index = visibleApps.firstIndex(where: { $0.pid == pid }),
           let context = NSGraphicsContext.current?.cgContext {
            NSGraphicsContext.saveGraphicsState()
            context.addPath(RingGeometry.appSectorPath(index: index, count: visibleApps.count))
            NSColor.labelColor.withAlphaComponent(dark ? 0.16 : 0.07).setFill()
            context.fillPath()
            NSGraphicsContext.restoreGraphicsState()
        }
        var badges: [(String, NSRect)] = []
        for (index, app) in visibleApps.enumerated() {
            let p = RingGeometry.point(angle: RingGeometry.angle(index: index, count: visibleApps.count), radius: RingGeometry.appRadius)
            let size = appIconSize
            let iconRect = NSRect(x: p.x - size / 2, y: p.y - size / 2, width: size, height: size)
            app.icon.draw(in: iconRect, from: .zero, operation: .sourceOver, fraction: draggedApp?.pid == app.pid ? 0.25 : 1)
            if let badge = itemCounts[app.pid]?.badge { badges.append((badge, iconRect)) }
        }
        // Dense app pages must not let a later icon paint over an earlier badge.
        for (text, rect) in badges { drawBadge(text, on: rect) }
        if showsLauncher { drawLauncher(); return }
        drawCenter()
        if let app = draggedApp {
            let size = appIconSize
            let point = CGPoint(x: min(max(dragPoint.x, size), bounds.maxX - size), y: min(max(dragPoint.y, size), bounds.maxY - size))
            app.icon.draw(in: NSRect(x: point.x - size / 2, y: point.y - size / 2, width: size, height: size))
            if dragWillQuit {
                let outline = NSBezierPath(ovalIn: NSRect(x: RingGeometry.center.x - RingGeometry.appOuter - 3,
                    y: RingGeometry.center.y - RingGeometry.appOuter - 3, width: (RingGeometry.appOuter + 3) * 2, height: (RingGeometry.appOuter + 3) * 2))
                NSColor.systemRed.withAlphaComponent(0.65).setStroke(); outline.lineWidth = 2; outline.stroke()
                let badge = NSRect(x: point.x + size / 2 - 8, y: point.y + size / 2 - 8, width: 16, height: 16)
                NSColor.systemRed.setFill(); NSBezierPath(ovalIn: badge).fill()
                drawSymbol("xmark", rect: badge.insetBy(dx: 4, dy: 4), color: .white)
            }
        }
    }

    private func drawBadge(_ text: String, on icon: NSRect) {
        let height = min(14, max(10, icon.width * 0.45))
        let font = NSFont.monospacedDigitSystemFont(ofSize: height * 0.7, weight: .semibold)
        let attributes: [NSAttributedString.Key: Any] = [
            .font: font, .foregroundColor: dark ? NSColor.black : NSColor.white
        ]
        let size = (text as NSString).size(withAttributes: attributes)
        let width = max(height, size.width + 5)
        let rect = NSRect(x: icon.maxX - width + 3, y: icon.minY - 3, width: width, height: height)
        let outline = NSBezierPath(roundedRect: rect.insetBy(dx: -1, dy: -1), xRadius: height / 2 + 1, yRadius: height / 2 + 1)
        (dark ? NSColor.black : NSColor.white).setFill(); outline.fill()
        let badge = NSBezierPath(roundedRect: rect, xRadius: height / 2, yRadius: height / 2)
        (dark ? NSColor.white : NSColor.black).setFill(); badge.fill()
        (text as NSString).draw(at: NSPoint(x: rect.midX - size.width / 2, y: rect.midY - size.height / 2), withAttributes: attributes)
    }

    private func drawWindows() {
        guard showsWindowArc else { return }
        for (index, win) in visibleWindows.enumerated() {
            let selected = win.id == hoveredWindow
            let p = windowPoint(index)
            if let color = win.customColor {
                NSGraphicsContext.saveGraphicsState()
                color.color.withAlphaComponent(dark ? 0.30 : 0.18).setFill()
                if let context = NSGraphicsContext.current?.cgContext {
                    context.addPath(RingGeometry.windowSectorPath(index: index, count: visibleWindows.count, anchor: arcAnchor))
                    context.fillPath()
                }
                NSGraphicsContext.restoreGraphicsState()
            }
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
            drawText(win.displayTitle, rect: NSRect(x: p.x - 36, y: p.y - 24, width: 72, height: 28), font: .systemFont(ofSize: 10, weight: selected ? .medium : .regular), color: ink, lines: 2)
            let close = closeButtonRect(at: index)
            let pending = closingWindowIDs.contains(win.id)
            let highlighted = !pending && hoveredClose == win.id
            let background = NSBezierPath(ovalIn: close)
            (highlighted ? NSColor.systemRed : NSColor.labelColor.withAlphaComponent(dark ? 0.16 : 0.07)).setFill()
            background.fill()
            drawSymbol(pending ? "ellipsis" : "xmark", rect: close.insetBy(dx: 5, dy: 5), color: highlighted ? .white : muted)
        }
    }

    private func drawCenter() {
        let c = RingGeometry.center
        if let app = draggedApp {
            RingCenterLabel.draw(title: app.name,
                detail: dragWillQuit ? L10n.text("松开退出应用", "Release to quit") : L10n.text("拖出轮盘退出", "Drag out to quit"),
                titleColor: ink, detailColor: dragWillQuit ? .systemRed : muted)
            return
        }
        let app = apps.first { $0.pid == hoveredApp } ?? currentApp
        let name = app?.name ?? (apps.isEmpty ? L10n.text("暂无应用", "No apps") : L10n.text("应用", "Apps"))
        let paging = (showsWindowArc && windowPages > 1) || appPages > 1
        RingCenterLabel.draw(title: name, detail: app == nil || loading ? "" : message,
                             paging: paging, titleColor: ink, detailColor: muted)
        if paging {
            drawSymbol("chevron.left", rect: NSRect(x: c.x - 20, y: c.y - 29, width: 5, height: 8), color: muted)
            drawSymbol("chevron.right", rect: NSRect(x: c.x + 15, y: c.y - 29, width: 5, height: 8), color: muted)
            let page = showsWindowArc && windowPages > 1 ? "\(windowPage + 1)/\(windowPages)" : "\(appPage + 1)/\(appPages)"
            RingCenterLabel.page(page, in: NSRect(x: c.x - 14, y: c.y - 32, width: 28, height: 14), color: muted)
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
        if showsLauncher {
            for (i, record) in visibleLauncherApps.enumerated() {
                let p = launcherPoint(i)
                add(record.app.name, help: L10n.text("打开应用", "Open app"),
                    rect: NSRect(x: p.x - 22, y: p.y - 22, width: 44, height: 44)) { [weak self] in
                    guard let self, self.showsLauncher, record.available else { return }
                    self.onLaunchApp?(record.app)
                }
                items.last?.setAccessibilityEnabled(record.available)
            }
            if launcherPages > 1 {
                for direction in [-1, 1] {
                    add(direction < 0 ? L10n.text("上一页", "Previous page") : L10n.text("下一页", "Next page"), help: "",
                        rect: NSRect(x: direction < 0 ? 218 : 240, y: 208, width: 22, height: 14)) { [weak self] in self?.changeLauncherPage(direction) }
                }
            }
            setAccessibilityElement(false); setAccessibilityChildren(items)
            return
        }
        for (i, app) in visibleApps.enumerated() {
            let p = RingGeometry.point(angle: RingGeometry.angle(index: i, count: visibleApps.count), radius: RingGeometry.appRadius)
            let mode = options.contentMode(for: app.bundleID).title
            let label = itemCounts[app.pid]?.badge.map { "\(app.name), \($0) \(mode)" } ?? app.name
            add(label, help: L10n.text("有多个\(mode)时展开圆弧；点击切换，拖出轮盘退出应用。", "Show windows or tabs. Click to switch; drag the app outside the ring to quit."), rect: NSRect(x: p.x - 24, y: p.y - 24, width: 48, height: 48)) { [weak self] in self?.select(app) }
        }
        for (i, win) in visibleWindows.enumerated() {
            let p = windowPoint(i)
            add(win.displayTitle + (win.minimized ? L10n.text("，已最小化", ", minimized") : ""), help: L10n.text("切换到此\(secondaryName)", "Switch to this item"), rect: NSRect(x: p.x - 35, y: p.y - 29, width: 70, height: 58)) { [weak self] in self?.onActivateWindow?(win) }
            add(L10n.text("关闭 \(win.displayTitle)", "Close \(win.displayTitle)"), help: L10n.text("关闭此窗口或标签页", "Close this window or tab"), rect: closeButtonRect(at: i)) { [weak self] in self?.onCloseWindow?(win) }
        }
        let c = RingGeometry.center
        if showsWindowArc && windowPages > 1 {
            add(L10n.text("上一页\(secondaryName)", "Previous \(secondaryName.lowercased())"), help: L10n.text("圆弧滚动翻页", "Scroll over the arc to change pages"), rect: NSRect(x: pageControlsRect.minX, y: pageControlsRect.minY, width: 22, height: 14)) { [weak self] in self?.changeWindowPage(-1) }
            add(L10n.text("下一页\(secondaryName)", "Next \(secondaryName.lowercased())"), help: L10n.text("圆弧滚动翻页", "Scroll over the arc to change pages"), rect: NSRect(x: c.x, y: pageControlsRect.minY, width: 22, height: 14)) { [weak self] in self?.changeWindowPage(1) }
        } else if appPages > 1 {
            add(L10n.text("上一页应用", "Previous apps"), help: L10n.text("滚动或点击翻页", "Scroll or click to change pages"), rect: NSRect(x: pageControlsRect.minX, y: pageControlsRect.minY, width: 22, height: 14)) { [weak self] in self?.changeAppPage(-1) }
            add(L10n.text("下一页应用", "Next apps"), help: L10n.text("滚动或点击翻页", "Scroll or click to change pages"), rect: NSRect(x: c.x, y: pageControlsRect.minY, width: 22, height: 14)) { [weak self] in self?.changeAppPage(1) }
        }
        add(L10n.text("设置", "Settings"), help: L10n.text("右键圆盘打开设置", "Right-click the ring to open settings"), rect: NSRect(x: c.x - 30, y: c.y - 15, width: 60, height: 38)) { [weak self] in self?.onSettings?() }
        setAccessibilityElement(false)
        setAccessibilityChildren(items)
    }
}

final class RingAccessibleItem: NSAccessibilityElement {
    var action: (() -> Void)?
    override func accessibilityPerformPress() -> Bool { action?(); return true }
}
