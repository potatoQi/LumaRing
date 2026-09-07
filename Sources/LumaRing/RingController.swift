import AppKit
import LumaRingCore
import os

final class RingPanel: NSPanel {
    override var canBecomeKey: Bool { true }
    override var canBecomeMain: Bool { false }
}

@MainActor final class RingController: NSObject, NSWindowDelegate {
    let view = RingView(frame: NSRect(x: 0, y: 0, width: RingGeometry.canvas, height: RingGeometry.canvas))
    private let catalog: ApplicationCatalog
    private let windows = WindowService()
    private let counts = AppCountService()
    private let tabs = BrowserTabService.shared
    private let activator = ApplicationActivator()
    private let previews = PreviewService()
    private let previewCard = WindowPreview()
    private var openedByShortcut = false
    private var panel: RingPanel?
    private var clickMonitor: Any?
    private var localClickMonitor: Any?
    private var gate = RequestGate()
    private let logger = Logger(subsystem: "local.lumaring.app", category: "performance")
    var onSettings: (() -> Void)?
    var onError: ((String) -> Void)?
    var isVisible: Bool { panel?.isVisible == true }
    private var closing = false

    init(catalog: ApplicationCatalog) {
        self.catalog = catalog
        super.init()
        view.onClose = { [weak self] in self?.dismiss() }
        view.onSettings = { [weak self] in self?.dismiss(); self?.onSettings?() }
        view.onVisibleAppsChanged = { [weak self] in self?.refreshCounts() }
        view.onSelectApp = { [weak self] app in
            guard let self else { return }
            let ticket = self.gate.invalidate()
            let completion: (WindowResult) -> Void = { [weak self] result in
                guard let self, self.isVisible, self.gate.accepts(ticket) else { return }
                self.view.setWindows(result, for: app.pid)
            }
            self.windows.cancelAndClear()
            self.tabs.cancelAndClear()
            if self.view.options.contentMode(for: app.bundleID) == .tabs {
                self.tabs.load(pid: app.pid, bundleID: app.bundleID, completion: completion)
            } else { self.windows.load(pid: app.pid, completion: completion) }
        }
        view.onActivateApp = { [weak self] app in
            guard let self else { return }
            self.dismiss()
            self.activator.activate(pid: app.pid) { [weak self] success in
                if !success { self?.onError?(L10n.text("未能打开这个应用。它可能已退出，请重新呼出轮盘再试。", "Could not open this app. It may have quit. Reopen the ring and try again.")) }
            }
        }
        view.onActivateWindow = { [weak self] window in
            guard let self else { return }
            let allowAppFallback = self.view.selectedApp == window.pid && self.view.windows.count == 1
            self.dismiss()
            if let tab = window.tab {
                self.tabs.activate(tab, pid: window.pid) { [weak self] result in
                    if case .failure(let error) = result { self?.onError?(error.localizedDescription) }
                }
                return
            }
            self.windows.activate(window, allowAppFallback: allowAppFallback) { [weak self] success in
                if !success { self?.onError?(L10n.text("未能置前这个窗口。它可能已经关闭，或位于受系统限制的全屏桌面。", "Could not bring this window forward. It may be closed or on a restricted full-screen desktop.")) }
            }
        }
        view.onHoverWindow = { [weak self] window in
            guard let self else { return }
            self.previews.cancelPending()
            self.previewCard.dismiss()
            guard let window, Preferences.shared.options.previews,
                  self.isVisible, self.view.hoveredWindow == window.id else { return }
            self.presentPreview(window, image: nil)
            guard window.tab == nil else { return }
            self.previews.load(window, pixelSize: self.previewCard.capturePixelSize) { [weak self] result in
                guard let self, self.isVisible, self.view.hoveredWindow == window.id else { return }
                switch result {
                case .success(let image): self.presentPreview(window, image: image)
                case .failure(let failure): self.presentPreview(window, image: nil, failure: failure)
                }
            }
        }
    }

    private func presentPreview(_ record: WindowRecord, image: NSImage?, failure: PreviewFailure? = nil) {
        guard let anchor = view.windowScreenFrame(record.id), let screen = panel?.screen else { return }
        let message = record.tab.map { L10n.text("\($0.url)\n\n点击切换到此标签页 · 后台标签页不提供图片预览", "\($0.url)\n\nClick to switch to this tab. Background tabs have no image preview.") } ?? failure?.message ?? (record.minimized ? PreviewFailure.minimized.message : L10n.text("正在载入预览…", "Loading preview…"))
        previewCard.show(window: record, image: image, message: message, anchor: anchor,
                         occupied: view.occupiedScreenFrame, screen: screen.visibleFrame, preferredSize: Preferences.shared.options.previewSize)
    }

    private func refreshCounts() {
        guard isVisible else { return }
        counts.refresh(apps: view.visibleApps, options: view.options) { [weak self] pid, count in
            guard let self, self.isVisible else { return }
            self.view.setItemCount(count, for: pid)
        }
    }

    func pressShortcut() {
        if Preferences.shared.options.holdToSelect {
            if !isVisible { show() }
            openedByShortcut = true
        } else { toggle() }
    }

    func toggle() { if isVisible { dismiss() } else { show() } }

    func show() {
        if isVisible { return }
        closing = false
        openedByShortcut = false
        let start = ProcessInfo.processInfo.systemUptime
        Preferences.shared.refreshPermissions()
        let options = Preferences.shared.options
        let pointer = NSEvent.mouseLocation
        guard let screen = NSScreen.screens.first(where: { $0.frame.contains(pointer) }) ?? NSScreen.main else { return }
        let frame = RingGeometry.panelFrame(pointer: pointer, visibleFrame: screen.visibleFrame, preferredSize: options.ringSize)
        if panel == nil {
            let created = RingPanel(contentRect: frame, styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false)
            created.level = .popUpMenu
            created.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .ignoresCycle, .stationary]
            created.isOpaque = false; created.backgroundColor = .clear; created.hasShadow = false
            created.hidesOnDeactivate = false; created.isFloatingPanel = true
            created.isReleasedWhenClosed = false
            created.acceptsMouseMovedEvents = true
            created.animationBehavior = .none
            created.delegate = self
            created.contentView = view
            panel = created
        }
        guard let panel else { return }
        panel.setFrame(frame, display: false)
        view.frame = NSRect(origin: .zero, size: frame.size)
        view.bounds = NSRect(x: 0, y: 0, width: RingGeometry.canvas, height: RingGeometry.canvas)
        view.reset(apps: catalog.snapshot(options: options), options: options)
        panel.alphaValue = 1
        panel.makeKeyAndOrderFront(nil)
        panel.makeFirstResponder(view)
        view.refresh()
        refreshCounts()
        // Event monitors exist only while the ring is visible; no global input tap.
        clickMonitor = NSEvent.addGlobalMonitorForEvents(matching: [.leftMouseDown, .rightMouseDown, .otherMouseDown]) { [weak self] _ in
            DispatchQueue.main.async { self?.dismiss() }
        }
        localClickMonitor = NSEvent.addLocalMonitorForEvents(matching: [.leftMouseDown, .rightMouseDown]) { [weak self] event in
            if let self, event.window !== self.panel { self.dismiss() }
            return event
        }
        let elapsed = (ProcessInfo.processInfo.systemUptime - start) * 1000
        logger.debug("Ring presentation scheduled in \(elapsed, privacy: .public) ms")
        if !NSWorkspace.shared.accessibilityDisplayShouldReduceMotion {
            panel.alphaValue = 0
            NSAnimationContext.runAnimationGroup { context in
                context.duration = 0.09
                panel.animator().alphaValue = 1
            }
        }
    }

    func dismiss() {
        guard isVisible, !closing else { return }
        closing = true
        gate.invalidate()
        openedByShortcut = false
        previewCard.dismiss()
        view.cancelHover()
        windows.cancelAndClear()
        tabs.cancelAndClear()
        counts.cancelAndClear()
        previews.cancelAndClear()
        panel?.orderOut(nil)
        if let clickMonitor { NSEvent.removeMonitor(clickMonitor) }; clickMonitor = nil
        if let localClickMonitor { NSEvent.removeMonitor(localClickMonitor) }; localClickMonitor = nil
        // Release AX elements, image buffers and application snapshots when hidden.
        view.reset(apps: [], options: Preferences.shared.options)
        closing = false
    }

    func releaseShortcut() {
        if isVisible && openedByShortcut && Preferences.shared.options.holdToSelect { view.activateHovered() }
    }

    func windowDidResignKey(_ notification: Notification) { dismiss() }

    func applicationsChanged() {
        // Keep spatial order stable while selecting. Drop terminated apps only.
        guard isVisible else { return }
        let live = Set(NSWorkspace.shared.runningApplications.filter { !$0.isTerminated }.map(\.processIdentifier))
        guard view.apps.contains(where: { !live.contains($0.pid) }) else { return }
        view.apps.removeAll { !live.contains($0.pid) }
        if let selected = view.selectedApp, !live.contains(selected) {
            gate.invalidate(); windows.cancelAndClear()
            view.clearSelection()
            view.message = L10n.text("应用已退出 · 请选择其他应用", "App closed · Choose another app")
        }
        view.appPage = min(view.appPage, RingGeometry.pageCount(total: view.apps.count, size: view.appPageSize) - 1)
        view.refresh()
        refreshCounts()
    }
}
