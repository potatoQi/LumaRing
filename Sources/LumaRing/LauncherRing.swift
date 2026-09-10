import AppKit
import LumaRingCore

extension RingView {
    var launcherPages: Int { RingGeometry.pageCount(total: launcherApps.count, size: 12) }
    var visibleLauncherApps: [LauncherRecord] {
        Array(launcherApps[RingGeometry.pageRange(page: launcherPage, total: launcherApps.count, size: 12)])
    }
    func launcherPoint(_ index: Int) -> CGPoint {
        RingGeometry.point(angle: RingGeometry.angle(index: index, count: visibleLauncherApps.count), radius: RingGeometry.windowRadius)
    }
    func launcherTarget(at point: CGPoint) -> LauncherRecord? {
        guard showsLauncher, let index = RingGeometry.index(at: point, count: visibleLauncherApps.count,
            inner: RingGeometry.windowInner, outer: RingGeometry.windowOuter) else { return nil }
        return visibleLauncherApps[index]
    }
    func updateOption(pressed: Bool, allowEntry: Bool = true) {
        guard pressed != optionPressed else { return }
        optionPressed = pressed
        if !pressed { if showsLauncher && !launcherPinned { endLauncherMode() }; return }
        guard allowEntry, !isEditingName, !showsWindowArc, !isPointerDown, !isContextMenuOpen else { return }
        guard !showsLauncher else { return }
        enterLauncherMode(pinned: false)
    }
    private func enterLauncherMode(pinned: Bool) {
        centerClickWork?.cancel(); centerClickWork = nil
        onPointerInteraction?()
        onLauncherModeEntered?()
        clearSelection()
        launcherPinned = pinned
        showsLauncher = true; launcherPage = 0; hoveredLauncher = nil
        refresh()
    }
    @discardableResult func toggleLauncherFromCenter(at point: CGPoint) -> Bool {
        guard !isEditingName, !isContextMenuOpen, !isPointerDown, !showsWindowArc,
              hypot(point.x - RingGeometry.center.x, point.y - RingGeometry.center.y) < RingGeometry.appInner,
              !CGRect(x: 218, y: 208, width: 44, height: 14).contains(point) else { return false }
        centerClickWork?.cancel(); centerClickWork = nil
        if showsLauncher { onPointerInteraction?(); endLauncherMode() }
        else { enterLauncherMode(pinned: true) }
        return true
    }
    func scheduleCenterSettings() {
        // Leave the first click available for a double-click before opening settings.
        centerClickWork?.cancel()
        let work = DispatchWorkItem { [weak self] in
            guard let self, self.window?.isVisible == true, !self.showsLauncher,
                  !self.isEditingName, !self.isContextMenuOpen, !self.isPointerDown else { return }
            self.centerClickWork = nil
            self.onSettings?()
        }
        centerClickWork = work
        DispatchQueue.main.asyncAfter(deadline: .now() + NSEvent.doubleClickInterval, execute: work)
    }
    func endLauncherMode() {
        cancelPointerInteraction()
        launcherPinned = false
        showsLauncher = false; hoveredLauncher = nil
        clearSelection()
        refresh()
    }
    func changeLauncherPage(_ direction: Int) {
        guard showsLauncher, !isPointerDown else { return }
        launcherPage = RingGeometry.wrapped(launcherPage + direction, count: launcherPages)
        hoveredLauncher = nil
        refresh()
    }
    func activateLauncher(at point: CGPoint) {
        if let record = launcherTarget(at: point) {
            if record.available { onLaunchApp?(record.app) }
        } else if CGRect(x: 218, y: 208, width: 44, height: 14).contains(point), launcherPages > 1 {
            changeLauncherPage(point.x < RingGeometry.center.x ? -1 : 1)
        } else if hypot(point.x - RingGeometry.center.x, point.y - RingGeometry.center.y) > RingGeometry.windowOuter {
            onClose?()
        }
    }
    func changeContentMode(_ mode: AppContentMode, for app: AppRecord) {
        guard BrowserAdapters.supports(app.bundleID), !showsLauncher else { return }
        options.appContentModes[app.bundleID] = mode
        clearSelection()
        select(app)
        onVisibleAppsChanged?()
    }

    func drawLauncher() {
        let dark = effectiveAppearance.bestMatch(from: [.aqua, .darkAqua]) == .darkAqua
        let center = RingGeometry.center
        let disk = NSBezierPath(ovalIn: NSRect(x: center.x - 118, y: center.y - 118, width: 236, height: 236))
        (dark ? NSColor.darkGray : NSColor.lightGray).withAlphaComponent(0.85).setFill(); disk.fill()
        let paragraph = NSMutableParagraphStyle(); paragraph.alignment = .center; paragraph.lineBreakMode = .byTruncatingTail
        func text(_ value: String, rect: NSRect, size: CGFloat, color: NSColor = .labelColor) {
            (value as NSString).draw(in: rect, withAttributes: [.font: NSFont.systemFont(ofSize: size), .foregroundColor: color, .paragraphStyle: paragraph])
        }
        let title = visibleLauncherApps.first { $0.app.id == hoveredLauncher }?.app.name ?? L10n.text("快捷启动", "Quick Launch")
        text(title, rect: NSRect(x: 192, y: 242, width: 96, height: 26), size: 12)
        text(launcherApps.isEmpty ? L10n.text("在设置中添加应用", "Add apps in Settings") : (launcherPinned ? L10n.text("双击中心返回", "Double-click to return") : L10n.text("松开 ⌥ 返回", "Release ⌥ to return")),
             rect: NSRect(x: 190, y: 222, width: 100, height: 16), size: 9, color: .secondaryLabelColor)
        if launcherPages > 1 { text("‹   \(launcherPage + 1)/\(launcherPages)   ›", rect: NSRect(x: 215, y: 207, width: 50, height: 15), size: 10) }
        for (index, record) in visibleLauncherApps.enumerated() {
            if record.app.id == hoveredLauncher, let context = NSGraphicsContext.current?.cgContext {
                NSGraphicsContext.saveGraphicsState()
                NSColor.controlAccentColor.withAlphaComponent(dark ? 0.25 : 0.12).setFill()
                context.addPath(RingGeometry.sectorPath(index: index, count: visibleLauncherApps.count,
                    inner: RingGeometry.windowInner, outer: RingGeometry.windowOuter)); context.fillPath()
                NSGraphicsContext.restoreGraphicsState()
            }
            let p = launcherPoint(index)
            record.icon.draw(in: NSRect(x: p.x - 17, y: p.y - 12, width: 34, height: 34),
                from: .zero, operation: .sourceOver, fraction: record.available ? 1 : 0.25)
            text(record.app.name, rect: NSRect(x: p.x - 32, y: p.y - 29, width: 64, height: 13), size: 9,
                 color: record.available ? .labelColor : .tertiaryLabelColor)
        }
    }
}
