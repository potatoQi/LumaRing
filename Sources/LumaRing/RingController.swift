import AppKit
import Carbon
import LumaRingCore

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
    private var actionPanel: ActionPanel?
    let actionView = ActionRingView(frame: NSRect(x: 0, y: 0, width: RingGeometry.canvas, height: RingGeometry.canvas))
    private let actionExecutor = ActionExecutor()
    private var actionMode = false
    private var originApp: NSRunningApplication?
    private var keyboardMonitor: RingKeyboardMonitor?
    private var optionTap = LeftOptionDoubleTap()
    private var optionHold: DispatchWorkItem?
    private var switchingMode = false
    private var clickMonitor: Any?
    private var localClickMonitor: Any?
    private var gate = RequestGate()
    var onSettings: (() -> Void)?
    var onError: ((String) -> Void)?
    var isVisible: Bool { panel?.isVisible == true || actionPanel?.isVisible == true }
    private var closing = false
    private var renameTicket: UUID?
    private(set) var styleEditor: WindowStyleEditor?

    init(catalog: ApplicationCatalog) {
        self.catalog = catalog
        super.init()
        actionView.onClose = { [weak self] in self?.dismiss() }
        actionView.onSettings = { [weak self] in self?.dismiss(); self?.onSettings?() }
        actionView.onAction = { [weak self] action in
            guard let self, self.actionMode, self.isVisible, !self.view.showsLauncher, let target = self.actionExecutor.focus else { return }
            guard !Preferences.shared.options.invocationShortcuts.contains(where: { action.conflicts(with: $0) }) else { return }
            let invocation = Preferences.shared.options.shortcut
            self.dismiss()
            self.actionExecutor.execute(action, target: target, invocation: invocation) { [weak self] success in
                if !success { self?.onError?(L10n.text("原输入焦点无法确认，或修饰键尚未松开，未发送快捷键。请松开按键并回到原窗口后重试。", "The original focus could not be verified, or modifier keys are still held. No shortcut was sent. Release the keys, return to the window and retry.")) }
            }
        }
        view.onClose = { [weak self] in self?.dismiss() }
        view.onSettings = { [weak self] in self?.dismiss(); self?.onSettings?() }
        view.onVisibleAppsChanged = { [weak self] in self?.refreshCounts() }
        // Once the mouse takes over, releasing a held shortcut must not also switch.
        view.onPointerInteraction = { [weak self] in
            self?.openedByShortcut = false
            self?.optionTap.reset(); self?.optionHold?.cancel(); self?.optionHold = nil
        }
        actionView.onPointerInteraction = view.onPointerInteraction
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
            self.openedByShortcut = false
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
            let named = self.names.apply(result, pid: app.pid)
            if case .ready = result { self.counts.markResolved(app.pid) }
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
        return window === panel || window === actionPanel || window === styleEditor?.window
    }

    private func presentPreview(_ record: WindowRecord, image: NSImage?, failure: PreviewFailure? = nil) {
        guard let anchor = view.windowScreenFrame(record.id), let screen = panel?.screen else { return }
        let message = record.tab.map { L10n.text("\($0.url)\n\n点击切换到此标签页 · 后台标签页不提供图片预览", "\($0.url)\n\nClick to switch to this tab. Background tabs have no image preview.") } ?? failure?.message ?? (record.minimized ? PreviewFailure.minimized.message : L10n.text("正在载入预览…", "Loading preview…"))
        previewCard.show(window: record, image: image, message: message, anchor: anchor,
                         occupied: view.occupiedScreenFrame, screen: screen.visibleFrame, preferredSize: Preferences.shared.options.previewSize)
    }

    private func refreshCounts() {
        guard isVisible, !actionMode else { return }
        counts.refresh(apps: view.visibleApps, options: view.options) { [weak self] pid, count in
            guard let self, self.isVisible else { return }
            self.view.setItemCount(count, for: pid)
        }
    }

    func pressShortcut() {
        if Preferences.shared.options.holdToSelect {
            if !isVisible { show() }
            openedByShortcut = !actionMode
        } else { toggle() }
    }

    func toggle() { if isVisible { dismiss() } else { show() } }

    func pressActionShortcut() {
        if isVisible {
            if actionMode { dismiss() } else { switchMode() }
        } else { show(actionMode: true) }
    }

    func toggleFromTrackpad() {
        if isVisible { dismiss() } else { show(fromTrackpad: true) }
    }

    func show(fromTrackpad: Bool = false, actionMode requestedMode: Bool? = nil) {
        if isVisible { return }
        actionExecutor.cancel()
        originApp = NSWorkspace.shared.frontmostApplication
        actionMode = requestedMode ?? Preferences.shared.options.usesActionRing(for: originApp?.bundleIdentifier)
        if requestedMode != nil { Preferences.shared.options.rememberActionRing(actionMode, for: originApp?.bundleIdentifier) }
        optionTap.reset()
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
        // Capture the original AX focus before the app ring takes key focus.
        // The surface is already visible; slow AX providers do not block rendering.
        if actionMode { presentActions(frame: frame) }
        else { panel.orderFrontRegardless(); view.refresh(); refreshCounts() }
        let session = presentationID
        if let originApp, originApp.processIdentifier != ProcessInfo.processInfo.processIdentifier,
           options.actionProfiles.contains(where: { $0.id == originApp.bundleIdentifier && $0.actions.contains(where: { $0.configured }) }) {
            actionExecutor.prepare(pid: originApp.processIdentifier) { [weak self] available in
                guard let self, self.isVisible, self.presentationID == session else { return }
                guard NSWorkspace.shared.frontmostApplication?.processIdentifier == self.originApp?.processIdentifier else { self.dismiss(); return }
                self.actionView.ready = available
                self.actionView.message = self.actionMessage(available: available)
                self.actionView.refresh()
                if !self.actionMode, !self.view.isContextMenuOpen, !self.view.isEditingName {
                    self.panel?.makeKey(); self.panel?.makeFirstResponder(self.view)
                }
            }
        } else {
            actionView.ready = false; actionView.message = actionMessage(available: false); actionView.refresh()
            if !actionMode { panel.makeKey(); panel.makeFirstResponder(view) }
        }
        keyboardMonitor = RingKeyboardMonitor { [weak self] event, canNavigate in
            self?.handleKeyboard(event, canNavigate: canNavigate) ?? false
        }
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
        AppLog.shared.record("presentation_scheduled", category: .ring, level: .debug, fields: ["milliseconds": String(elapsed)])
        if !actionMode, !NSWorkspace.shared.accessibilityDisplayShouldReduceMotion {
            panel.alphaValue = 0
            NSAnimationContext.runAnimationGroup { context in
                context.duration = 0.09
                panel.animator().alphaValue = 1
            }
        }
    }

    func dismiss() {
        guard !switchingMode else { return }
        actionExecutor.cancel()
        guard isVisible, !closing else { return }
        optionHold?.cancel(); optionHold = nil; optionTap.reset()
        keyboardMonitor?.stop(); keyboardMonitor = nil
        presentationID = UUID()
        closing = true
        renameTicket = nil
        styleEditor?.dismiss(); styleEditor = nil
        view.isEditingName = false; view.afterContextMenu = nil
        // Remove the visible surface before clearing snapshots or dispatching IPC.
        panel?.orderOut(nil); actionPanel?.orderOut(nil)
        setActionLauncherSurface(false)
        actionView.actions = []; actionView.ready = false; actionView.reset()
        actionView.icon = nil; actionView.appName = ""; actionView.message = ""
        originApp = nil
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
        if !actionMode && isVisible && openedByShortcut && Preferences.shared.options.holdToSelect {
            openedByShortcut = false
            view.activateHovered()
        }
    }

    func windowDidResignKey(_ notification: Notification) {
        if !switchingMode && !actionMode && !view.isContextMenuOpen && !view.isEditingName { dismiss() }
    }

    private func actionMessage(available: Bool) -> String {
        if actionView.actions.isEmpty { return L10n.text("点击此处配置", "Click to configure") }
        return available ? "" : L10n.text("无法确认焦点", "No input focus")
    }

    private func presentActions(frame: NSRect) {
        if actionPanel == nil {
            let created = ActionPanel(contentRect: frame, styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false)
            created.level = .popUpMenu
            created.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .ignoresCycle, .stationary]
            created.isOpaque = false; created.backgroundColor = .clear; created.hasShadow = false
            created.hidesOnDeactivate = false; created.isFloatingPanel = true; created.becomesKeyOnlyIfNeeded = true
            created.isReleasedWhenClosed = false; created.acceptsMouseMovedEvents = true; created.animationBehavior = .none
            created.contentView = actionView
            actionPanel = created
        }
        let options = Preferences.shared.options
        actionView.actions = options.actionProfiles.first(where: { $0.id == originApp?.bundleIdentifier })?.actions.filter {
            $0.configured && !options.invocationShortcuts.contains(where: $0.conflicts)
        } ?? []
        actionView.appName = originApp?.localizedName ?? L10n.text("当前应用", "Current App")
        actionView.icon = originApp?.icon
        actionView.ready = actionExecutor.focus != nil
        actionView.message = actionMessage(available: actionView.ready)
        actionView.acceptsPointerEvent = { [weak self] in self?.view.acceptsPointerEvent($0) == true }
        actionPanel?.setFrame(frame, display: false)
        actionView.frame = NSRect(origin: .zero, size: frame.size)
        actionView.bounds = NSRect(x: 0, y: 0, width: RingGeometry.canvas, height: RingGeometry.canvas)
        actionPanel?.orderFrontRegardless()
        actionView.reset()
    }

    private func switchMode() {
        guard isVisible, !view.isContextMenuOpen, !view.isEditingName, !view.isPointerDown, !actionView.isPointerDown else { return }
        switchingMode = true
        defer { switchingMode = false }
        optionHold?.cancel(); optionHold = nil; optionTap.reset(); openedByShortcut = false
        gate.invalidate(); windows.cancelAndClear(); tabs.cancelAndClear(); counts.cancelAndClear()
        previews.cancelAndClear(); previewCard.dismiss(); view.cancelHover()
        let frame = actionMode ? actionPanel!.frame : panel!.frame
        setActionLauncherSurface(false)
        view.updateOption(pressed: false, allowEntry: false)
        if view.showsLauncher { view.endLauncherMode() }
        view.clearSelection()
        actionMode.toggle()
        Preferences.shared.options.rememberActionRing(actionMode, for: originApp?.bundleIdentifier)
        if actionMode {
            panel?.orderOut(nil)
            presentActions(frame: frame)
        } else {
            actionPanel?.orderOut(nil)
            let options = Preferences.shared.options
            view.reset(apps: catalog.snapshot(options: options), options: options)
            view.launcherApps = launcherCatalog.snapshot(options.launcherApps)
            panel?.makeKeyAndOrderFront(nil); panel?.makeFirstResponder(view)
            view.refresh(); refreshCounts()
        }
        AppLog.shared.record("mode_changed", category: .actions, fields: ["actions": String(actionMode)])
    }

    private func updateLauncherOption(pressed: Bool, allowEntry: Bool = true) {
        view.updateOption(pressed: pressed, allowEntry: allowEntry)
        if actionMode { setActionLauncherSurface(view.showsLauncher) }
    }

    private func setActionLauncherSurface(_ show: Bool) {
        actionPanel?.setLauncherVisible(show, launcher: view, actions: actionView, restoreTo: panel)
    }

    private func handleKeyboard(_ event: NSEvent, canNavigate: Bool = true) -> Bool {
        guard isVisible else { return false }
        // Releases must retract the hold overlay even during a mouse press.
        // Clearing that press prevents mouse-up from selecting the underlying ring.
        if event.type == .flagsChanged, !event.modifierFlags.contains(.option) {
            updateLauncherOption(pressed: false, allowEntry: false)
        }
        guard !view.isContextMenuOpen, !view.isEditingName, !view.isPointerDown, !actionView.isPointerDown else {
            optionTap.reset(); optionHold?.cancel(); optionHold = nil
            return false
        }
        if event.type == .keyDown {
            optionTap.reset(); optionHold?.cancel(); optionHold = nil
            let shortcuts = Preferences.shared.options.invocationShortcuts
            if canNavigate, let command = RingNavigation.command(for: event, reserving: shortcuts) {
                openedByShortcut = false
                if !event.isARepeat || command.repeats {
                    if actionMode, !view.showsLauncher { actionView.navigate(command) }
                    else { view.navigate(command) }
                }
                return true
            }
            // Carbon owns invocation, including Option-Tab while the ring is open.
            if actionMode, !shortcuts.contains(where: { $0.matches(event) }) { dismiss() }
            return false
        }
        // Device-dependent left/right bits from IOLLEvent.h. Aggregate .option
        // cannot distinguish releasing one Option while the other is still down.
        let leftDown = event.modifierFlags.rawValue & 0x20 != 0
        let rightDown = event.modifierFlags.rawValue & 0x40 != 0
        let other = !event.modifierFlags.intersection([.command, .control, .shift, .function]).isEmpty || rightDown
        if optionTap.update(left: event.keyCode == 58, pressed: leftDown, otherModifiers: other, time: event.timestamp) {
            switchMode(); return true
        }
        optionHold?.cancel(); optionHold = nil
        if event.keyCode == 58 {
            if !leftDown { updateLauncherOption(pressed: rightDown, allowEntry: false) }
            else if !other, optionTap.isDown {
                let work = DispatchWorkItem { [weak self] in
                    guard let self, self.isVisible, self.optionTap.isDown,
                          CGEventSource.keyState(.combinedSessionState, key: 58),
                          !self.view.isPointerDown, !self.actionView.isPointerDown,
                          !self.view.isContextMenuOpen, !self.view.isEditingName else { return }
                    self.optionHold = nil
                    self.optionTap.reset() // This press is a hold, not part of a double-tap.
                    self.updateLauncherOption(pressed: true)
                }
                optionHold = work
                DispatchQueue.main.asyncAfter(deadline: .now() + LeftOptionDoubleTap.holdDelay, execute: work)
            }
        } else {
            updateLauncherOption(pressed: event.modifierFlags.contains(.option), allowEntry: event.keyCode == 61)
        }
        return true
    }

    func applicationsChanged() {
        names.pruneTerminated()
        if actionMode, isVisible {
            if originApp?.isTerminated != false || NSWorkspace.shared.frontmostApplication?.processIdentifier != originApp?.processIdentifier { dismiss() }
            return
        }
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
