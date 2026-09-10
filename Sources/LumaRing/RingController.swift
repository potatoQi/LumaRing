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
    private let quitter = ApplicationQuitter()
    private let launcherCatalog = LauncherCatalog()
    private let launcher = ApplicationLauncher()
    private let windowCreator = ApplicationWindowCreator()
    private let names = WindowNames()
    private let previews = PreviewService()
    private let previewCard = WindowPreview()
    private var openedByShortcut = false
    private var presentationID = UUID()
    private var closeRequests: Set<String> = []
    private var panel: RingPanel?
    private var clickMonitor: Any?
    private var localClickMonitor: Any?
    private var gate = RequestGate()
    private let logger = Logger(subsystem: "local.lumaring.app", category: "performance")
    var onSettings: (() -> Void)?
    var onError: ((String) -> Void)?
    var isVisible: Bool { panel?.isVisible == true }
    private var closing = false
    private var renameTicket: UUID?
    private(set) var styleEditor: WindowStyleEditor?

    init(catalog: ApplicationCatalog) {
        self.catalog = catalog
        super.init()
        view.onClose = { [weak self] in self?.dismiss() }
        view.onSettings = { [weak self] in self?.dismiss(); self?.onSettings?() }
        view.onVisibleAppsChanged = { [weak self] in self?.refreshCounts() }
        // Once the mouse takes over, releasing a held shortcut must not also switch.
        view.onPointerInteraction = { [weak self] in self?.openedByShortcut = false }
        view.onSelectApp = { [weak self] app in self?.loadSecondary(for: app) }
        view.onActivateApp = { [weak self] app in
            guard let self else { return }
            self.dismiss()
            self.activator.activate(pid: app.pid) { [weak self] success in
                if !success { self?.onError?(L10n.text("未能打开这个应用。它可能已退出，请重新呼出轮盘再试。", "Could not open this app. It may have quit. Reopen the ring and try again.")) }
            }
        }
        view.onActivateWindow = { [weak self] window in
            guard let self, !self.closeRequests.contains(window.id) else { return }
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
        view.onCloseWindow = { [weak self] window in self?.closeSecondary(window) }
        view.onQuitApp = { [weak self] app in
            guard let self else { return }
            self.dismiss()
            self.quitter.quit(.init(pid: app.pid, bundleID: app.bundleID)) { [weak self] outcome in
                if outcome == .rejected {
                    self?.onError?(L10n.text("未能退出这个应用，请在应用中重试。", "Could not quit this app. Try quitting from the app."))
                }
            }
        }

        view.onLaunchApp = { [weak self] app in
            guard let self else { return }
            self.dismiss()
            self.launcher.launch(app) { [weak self] success in
                if !success { self?.onError?(L10n.text("未能打开这个应用。请在设置中重新添加。", "Could not open this app. Add it again in Settings.")) }
            }
        }
        view.onLauncherModeEntered = { [weak self] in
            guard let self else { return }
            self.gate.invalidate()
            self.windows.cancelAndClear(); self.tabs.cancelAndClear()
            self.previews.cancelAndClear(); self.previewCard.dismiss()
        }
        view.makeAppMenu = { [weak self] app in
            guard let self else { return NSMenu() }
            return AppContextMenu.make(app: app, mode: self.view.options.contentMode(for: app.bundleID),
                discover: { self.windowCreator.discover(pid: app.pid, bundleID: app.bundleID, completion: $0) },
                newWindow: { [weak self] command in
                    guard let self else { return }
                    self.view.afterContextMenu = { [weak self] in
                        guard let self else { return }
                        self.dismiss()
                        self.windowCreator.perform(command) { [weak self] success in
                            if !success { self?.onError?(L10n.text("未能新建窗口。请确认辅助功能权限，或在应用管理中连接浏览器后重试。", "Could not create a window. Check Accessibility access, or connect the browser in App Management and retry.")) }
                        }
                    }
                },
                changeMode: { [weak self] mode in
                    Preferences.shared.options.appContentModes[app.bundleID] = mode
                    self?.view.changeContentMode(mode, for: app)
                },
                quit: { [weak self] in self?.view.onQuitApp?(app) })
        }

        view.makeWindowMenu = { [weak self] record in
            AppContextMenu.make(window: record,
                close: { [weak self] in self?.view.onCloseWindow?($0) },
                edit: { [weak self] record in
                    self?.view.afterContextMenu = { [weak self] in self?.edit(record) }
                })
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

    private func loadSecondary(for app: AppRecord, afterClosing closedID: String? = nil, attempt: Int = 0) {
        let ticket = gate.invalidate()
        let mode = view.options.contentMode(for: app.bundleID)
        let completion: (WindowResult) -> Void = { [weak self] result in
            guard let self, self.isVisible, self.gate.accepts(ticket), self.view.selectedApp == app.pid,
                  self.view.options.contentMode(for: app.bundleID) == mode else { return }
            // AXPress can return before the window disappears. Keep the accepted
            // removal on screen briefly, then reconcile with the actual app state.
            if let closedID, case .ready(let records, _) = result,
               records.contains(where: { $0.id == closedID }), attempt < 2 {
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.15) { [weak self] in
                    guard let self, self.isVisible, self.gate.accepts(ticket) else { return }
                    self.loadSecondary(for: app, afterClosing: closedID, attempt: attempt + 1)
                }
                return
            }
            let named = self.names.apply(result, pid: app.pid, isTab: mode == .tabs)
            if closedID != nil, case .unavailable(let message) = named {
                self.view.message = message; self.view.refresh()
            } else { self.view.setWindows(named, for: app.pid) }
        }
        windows.cancelAndClear(); tabs.cancelAndClear()
        if mode == .tabs { tabs.load(pid: app.pid, bundleID: app.bundleID, completion: completion) }
        else { windows.load(pid: app.pid, completion: completion) }
    }

    private func closeSecondary(_ window: WindowRecord) {
        guard isVisible, !view.isEditingName, !closeRequests.contains(window.id),
              let app = view.currentApp, app.pid == window.pid,
              view.windows.contains(where: { $0.id == window.id }) else { return }
        let session = presentationID, mode = view.options.contentMode(for: app.bundleID)
        openedByShortcut = false
        closeRequests.insert(window.id)
        view.closingWindowIDs.insert(window.id)
        view.cancelHover(); previews.cancelAndClear(); previewCard.dismiss()
        gate.invalidate(); windows.cancelAndClear(); tabs.cancelAndClear()
        view.refreshArtwork()
        let finish: (String?) -> Void = { [weak self] error in
            guard let self else { return }
            self.closeRequests.remove(window.id)
            guard self.isVisible, self.presentationID == session else { return }
            self.view.closingWindowIDs.remove(window.id)
            guard self.view.selectedApp == app.pid, !self.view.isEditingName,
                  self.view.options.contentMode(for: app.bundleID) == mode else { self.view.refreshArtwork(); return }
            if let error {
                self.view.message = error; self.view.refresh()
                return
            }
            self.view.removeClosedWindow(window)
            // Refresh only this selected app; preserve other apps' spatial order.
            self.loadSecondary(for: app, afterClosing: window.id)
        }
        if let tab = window.tab {
            tabs.close(tab, pid: window.pid) { result in
                if case .failure(let error) = result { finish(error.localizedDescription) }
                else { finish(nil) }
            }
        } else {
            windows.close(window) { success in
                finish(success ? nil : L10n.text("未能关闭这个窗口，应用可能需要确认。", "Could not close this window. The app may need confirmation."))
            }
        }
    }

    private func edit(_ record: WindowRecord) {
        guard isVisible, let panel, !view.isEditingName,
              let identity = names.identity(for: record.pid) else { return }
        openedByShortcut = false
        gate.invalidate(); windows.cancelAndClear(); tabs.cancelAndClear()
        previews.cancelAndClear(); previewCard.dismiss()
        view.cancelHover(); view.cancelPointerInteraction()
        view.isEditingName = true
        let ticket = UUID(); renameTicket = ticket
        let editor = WindowStyleEditor(record: record)
        // Retain and mark the editor before it takes key focus from the ring.
        styleEditor = editor
        editor.onSave = { [weak self] name, color in
            guard let self, self.renameTicket == ticket, self.isVisible,
                  self.names.update(name: name, color: color, for: record, expected: identity) else { return false }
            self.finishEditing()
            self.view.updateWindow(record.id, name: name, color: color)
            return true
        }
        editor.onCancel = { [weak self] in
            guard let self, self.renameTicket == ticket else { return }
            self.finishEditing()
        }
        editor.show(near: view.occupiedScreenFrame, screen: panel.screen?.visibleFrame ?? panel.frame)
    }

    private func finishEditing() {
        renameTicket = nil
        styleEditor?.dismiss(); styleEditor = nil
        view.isEditingName = false
        view.updateOption(pressed: NSEvent.modifierFlags.contains(.option), allowEntry: false)
        if isVisible { panel?.makeKey(); panel?.makeFirstResponder(view) }
    }

    func ownsInteractionWindow(_ window: NSWindow?) -> Bool {
        guard let window else { return false }
        return window === panel || window === styleEditor?.window
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

    func toggleFromTrackpad() {
        if isVisible { dismiss() } else { show(fromTrackpad: true) }
    }

    func show(fromTrackpad: Bool = false) {
        if isVisible { return }
        presentationID = UUID()
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
        if fromTrackpad { view.suppressInvocationClicks(at: ProcessInfo.processInfo.systemUptime) }
        view.launcherApps = launcherCatalog.snapshot(options.launcherApps)
        // The Option already held by the invocation shortcut must be released first.
        view.optionPressed = NSEvent.modifierFlags.contains(.option)
        panel.alphaValue = 1
        panel.makeKeyAndOrderFront(nil)
        panel.makeFirstResponder(view)
        view.refresh()
        refreshCounts()
        // Mouse monitors exist only while visible; the trackpad listener is separately opt-in.
        clickMonitor = NSEvent.addGlobalMonitorForEvents(matching: [.leftMouseDown, .rightMouseDown, .otherMouseDown]) { [weak self] event in
            DispatchQueue.main.async {
                guard let self, self.view.acceptsPointerEvent(event) else { return }
                if !self.view.isContextMenuOpen { self.dismiss() }
            }
        }
        localClickMonitor = NSEvent.addLocalMonitorForEvents(matching: [.leftMouseDown, .rightMouseDown]) { [weak self] event in
            if let self {
                guard self.view.acceptsPointerEvent(event) else { return nil }
                if !self.view.isContextMenuOpen, !self.ownsInteractionWindow(event.window) { self.dismiss() }
            }
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
        presentationID = UUID()
        closing = true
        renameTicket = nil
        styleEditor?.dismiss(); styleEditor = nil
        view.isEditingName = false; view.afterContextMenu = nil
        // Remove the visible surface before clearing snapshots or dispatching IPC.
        panel?.orderOut(nil)
        gate.invalidate()
        openedByShortcut = false
        previewCard.dismiss()
        view.cancelHover()
        windows.cancelAndClear()
        tabs.cancelAndClear()
        counts.cancelAndClear()
        previews.cancelAndClear()
        if let clickMonitor { NSEvent.removeMonitor(clickMonitor) }; clickMonitor = nil
        if let localClickMonitor { NSEvent.removeMonitor(localClickMonitor) }; localClickMonitor = nil
        // Release AX elements, image buffers and application snapshots when hidden.
        view.reset(apps: [], options: Preferences.shared.options)
        closing = false
    }

    func releaseShortcut() {
        if isVisible && openedByShortcut && Preferences.shared.options.holdToSelect {
            openedByShortcut = false
            view.activateHovered()
        }
    }

    func windowDidResignKey(_ notification: Notification) { if !view.isContextMenuOpen && !view.isEditingName { dismiss() } }

    func applicationsChanged() {
        names.pruneTerminated()
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
