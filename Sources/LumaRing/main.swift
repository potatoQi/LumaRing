import AppKit
import Combine
import SwiftUI

@MainActor final class AppDelegate: NSObject, NSApplicationDelegate, NSMenuDelegate {
    private var statusItem: NSStatusItem!
    private var settingsWindow: SettingsWindow?
    private let catalog = ApplicationCatalog()
    private lazy var ring = RingController(catalog: catalog)
    private let hotKey = HotKey()
    private let actionHotKey = HotKey()
    private var recordingShortcut = false
    private let trackpad = TrackpadGesture.shared
    private lazy var pinchMinimizer = PinchMinimizer(allowed: { [weak self] in
        guard let self else { return false }
        return Preferences.shared.options.threeFingerPinch && !self.ring.isVisible
    })
    private var subscriptions = Set<AnyCancellable>()
    private var tokens: [NSObjectProtocol] = []
    private var errorPopover: NSPopover?

    func applicationDidFinishLaunching(_ notification: Notification) {
        NSApp.setActivationPolicy(.accessory)
        Preferences.shared.$options.map(\.loggingEnabled).removeDuplicates()
            .sink { AppLog.shared.setEnabled($0) }.store(in: &subscriptions)
        AppLog.shared.record("started", category: .app, fields: ["version": UpdateService.version,
            "pid": String(getpid()), "os": ProcessInfo.processInfo.operatingSystemVersionString])
        Preferences.shared.options.theme.apply()
        Preferences.shared.$options.map(\.theme).removeDuplicates().dropFirst()
            .receive(on: RunLoop.main).sink { $0.apply() }.store(in: &subscriptions)
        if let iconURL = Bundle.main.url(forResource: "LumaRingIcon-1.3", withExtension: "icns"),
           let icon = NSImage(contentsOf: iconURL) { NSApp.applicationIconImage = icon }
        UpdateService.shared.start()
        configureMainMenu()
        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.squareLength)
        statusItem.button?.image = NSImage(systemSymbolName: "circle.hexagongrid", accessibilityDescription: L10n.text("LumaRing 应用与窗口轮盘", "LumaRing app and window switcher"))
        statusItem.button?.image?.isTemplate = true
        statusItem.button?.toolTip = L10n.text("LumaRing · 点击打开设置，右键打开菜单", "LumaRing · Click to open settings; right-click for the menu")
        statusItem.button?.target = self
        statusItem.button?.action = #selector(statusClicked)
        statusItem.button?.sendAction(on: [.leftMouseUp, .rightMouseUp])
        hotKey.onPress = { [weak self] in self?.ring.pressShortcut() }
        hotKey.onRelease = { [weak self] in self?.ring.releaseShortcut() }
        actionHotKey.onPress = { [weak self] in self?.ring.pressActionShortcut() }
        trackpad.onTap = { [weak self] in
            guard Preferences.shared.options.trackpadTap != .disabled else { return }
            self?.ring.toggleFromTrackpad()
        }
        trackpad.onPinchBegin = { [weak self] in
            guard let self else { return }
            self.settingsWindow?.cancelPinch()
            self.pinchMinimizer.cancel()
            guard Preferences.shared.options.threeFingerPinch, !self.ring.isVisible else { return }
            if let window = self.settingsWindow, window.canCloseWithPinch {
                window.beginPinch()
            } else {
                self.pinchMinimizer.begin()
            }
        }
        trackpad.onPinchComplete = { [weak self] in
            guard let self else { return }
            if Preferences.shared.options.threeFingerPinch && !self.ring.isVisible {
                self.settingsWindow?.completePinch()
                self.pinchMinimizer.complete()
            } else {
                self.settingsWindow?.cancelPinch()
                self.pinchMinimizer.cancel()
            }
        }
        trackpad.onPinchCancel = { [weak self] in
            self?.settingsWindow?.cancelPinch()
            self?.pinchMinimizer.cancel()
        }
        ring.onSettings = { [weak self] in self?.showSettings() }
        ring.onError = { [weak self] text in self?.showError(text) }
        catalog.onChange = { [weak self] in self?.ring.applicationsChanged() }
        Preferences.shared.$options.map(\.invocationShortcuts).removeDuplicates().sink { [weak self] _ in
            DispatchQueue.main.async { self?.registerShortcuts() }
        }.store(in: &subscriptions)
        tokens.append(NotificationCenter.default.addObserver(forName: RecorderButton.recordingDidChange, object: nil, queue: .main) { [weak self] notification in
            MainActor.assumeIsolated {
                guard let self else { return }
                self.recordingShortcut = notification.object as? Bool ?? false
                if self.recordingShortcut {
                    self.hotKey.unregister(); self.actionHotKey.unregister()
                } else {
                    DispatchQueue.main.async { self.registerShortcuts() }
                }
            }
        })
        Preferences.shared.$options.map { TrackpadGesture.Configuration(tap: $0.trackpadTap, pinch: $0.threeFingerPinch) }
            .removeDuplicates().sink { [weak self] gestures in
            // Options publishes before SwiftUI finishes updating its binding.
            DispatchQueue.main.async { self?.trackpad.configure(gesture: gestures.tap, pinch: gestures.pinch) }
        }.store(in: &subscriptions)
        tokens.append(NotificationCenter.default.addObserver(forName: NSApplication.didResignActiveNotification, object: nil, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated { self?.settingsWindow?.cancelPinch() }
        })
        let sleepEvents: [(Notification.Name, TrackpadGesture.Suspension)] = [
            (NSWorkspace.willSleepNotification, .sleep), (NSWorkspace.screensDidSleepNotification, .display),
            (NSWorkspace.sessionDidResignActiveNotification, .session)
        ]
        for (name, reason) in sleepEvents {
            tokens.append(NSWorkspace.shared.notificationCenter.addObserver(forName: name, object: nil, queue: .main) { [weak self] _ in
                AppLog.shared.record("suspend", category: .lifecycle, fields: ["notification": name.rawValue])
                DispatchQueue.main.async { self?.ring.dismiss(); self?.trackpad.suspend(reason) }
            })
        }
        let wakeEvents: [(Notification.Name, TrackpadGesture.Suspension)] = [
            (NSWorkspace.didWakeNotification, .sleep), (NSWorkspace.screensDidWakeNotification, .display),
            (NSWorkspace.sessionDidBecomeActiveNotification, .session)
        ]
        for (name, reason) in wakeEvents {
            tokens.append(NSWorkspace.shared.notificationCenter.addObserver(forName: name, object: nil, queue: .main) { [weak self] _ in
                AppLog.shared.record("resume", category: .lifecycle, fields: ["notification": name.rawValue])
                DispatchQueue.main.async { self?.trackpad.resume(reason) }
            })
        }
        for (name, locked) in [("com.apple.screenIsLocked", true), ("com.apple.screenIsUnlocked", false)] {
            tokens.append(DistributedNotificationCenter.default().addObserver(forName: Notification.Name(name), object: nil, queue: .main) { [weak self] _ in
                AppLog.shared.record("screen_lock", category: .lifecycle, fields: ["locked": String(locked)])
                MainActor.assumeIsolated {
                    if locked { self?.ring.dismiss(); self?.trackpad.suspend(.screenLock) }
                    else { self?.trackpad.resume(.screenLock) }
                }
            })
        }
        tokens.append(NotificationCenter.default.addObserver(forName: NSApplication.didChangeScreenParametersNotification, object: nil, queue: .main) { [weak self] _ in DispatchQueue.main.async { self?.ring.dismiss() } })
        tokens.append(NotificationCenter.default.addObserver(forName: .lumaRingLanguageDidChange, object: nil, queue: .main) { [weak self] _ in
            DispatchQueue.main.async { self?.refreshLanguage() }
        })
        let arguments = ProcessInfo.processInfo.arguments
        if arguments.contains("--show-ring") {
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.3) { [weak self] in self?.ring.show() }
        } else if arguments.contains("--settings") || !UserDefaults.standard.bool(forKey: "hasLaunched.v1") {
            showSettings()
        }
        UserDefaults.standard.set(true, forKey: "hasLaunched.v1")
    }

    private func registerShortcuts() {
        guard !recordingShortcut else { return }
        let preferences = Preferences.shared, options = preferences.options
        // Release both first so changing one binding to the other's old key works.
        hotKey.unregister(); actionHotKey.unregister()
        preferences.shortcutError = hotKey.register(options.shortcut) ? nil : L10n.text(
            "快捷键被占用，请换一个按键。", "This shortcut is in use. Choose another key.")
        preferences.actionShortcutError = nil
        if let shortcut = options.actionShortcut, !options.invocationConflict, !actionHotKey.register(shortcut) {
            preferences.actionShortcutError = L10n.text("快捷键被占用，请换一个按键。", "This shortcut is in use. Choose another key.")
        }
    }

    private func configureMainMenu() {
        let mainMenu = NSMenu()
        let applicationItem = NSMenuItem()
        let applicationMenu = NSMenu()
        applicationMenu.addItem(withTitle: L10n.text("设置…", "Settings…"), action: #selector(settingsAction), keyEquivalent: "").target = self
        applicationMenu.addItem(withTitle: L10n.text("检查更新…", "Check for Updates…"), action: #selector(UpdateService.checkForUpdates(_:)), keyEquivalent: "").target = UpdateService.shared
        applicationMenu.addItem(withTitle: L10n.text("退出 LumaRing", "Quit LumaRing"), action: #selector(quit), keyEquivalent: "").target = self
        applicationItem.submenu = applicationMenu
        mainMenu.addItem(applicationItem)
        let windowItem = NSMenuItem(title: L10n.text("窗口", "Windows"), action: nil, keyEquivalent: "")
        let windowMenu = NSMenu(title: L10n.text("窗口", "Windows"))
        windowMenu.addItem(withTitle: L10n.text("关闭", "Close"), action: #selector(NSWindow.performClose(_:)), keyEquivalent: "w")
            .keyEquivalentModifierMask = [.command]
        windowItem.submenu = windowMenu; mainMenu.addItem(windowItem)
        NSApp.mainMenu = mainMenu
    }

    private func refreshLanguage() {
        configureMainMenu()
        settingsWindow?.title = L10n.text("LumaRing 设置", "LumaRing Settings")
        statusItem.button?.toolTip = L10n.text("LumaRing · 点击打开设置，右键打开菜单", "LumaRing · Click to open settings; right-click for the menu")
        statusItem.button?.setAccessibilityLabel(L10n.text("LumaRing 应用与窗口轮盘", "LumaRing app and window switcher"))
        errorPopover?.close()
        ring.dismiss()
    }

    @objc private func statusClicked() {
        if NSApp.currentEvent?.type == .rightMouseUp { showMenu() }
        else { showSettings() }
    }

    private func showMenu() {
        let menu = NSMenu()
        menu.delegate = self
        menu.addItem(withTitle: L10n.text("设置…", "Settings…"), action: #selector(settingsAction), keyEquivalent: "")
        menu.addItem(.separator())
        menu.addItem(withTitle: L10n.text("退出 LumaRing", "Quit LumaRing"), action: #selector(quit), keyEquivalent: "")
        menu.items.forEach { $0.target = self }
        let updateItem = NSMenuItem(title: L10n.text("检查更新…", "Check for Updates…"), action: #selector(UpdateService.checkForUpdates(_:)), keyEquivalent: "")
        updateItem.target = UpdateService.shared
        menu.insertItem(updateItem, at: 1)
        statusItem.menu = menu
        statusItem.button?.performClick(nil)
    }

    func menuDidClose(_ menu: NSMenu) { statusItem.menu = nil }
    @objc private func settingsAction() { showSettings() }
    @objc private func quit() { ring.dismiss(); NSApp.terminate(nil) }

    func showSettings() {
        ring.dismiss()
        Preferences.shared.refreshPermissions()
        if settingsWindow == nil {
            let host = NSHostingController(rootView: SettingsView())
            let window = SettingsWindow(contentViewController: host)
            window.title = L10n.text("LumaRing 设置", "LumaRing Settings")
            window.styleMask = [.titled, .closable, .miniaturizable]
            window.setContentSize(NSSize(width: 680, height: 690))
            window.isReleasedWhenClosed = false
            window.center()
            settingsWindow = window
        }
        NSApp.activate(ignoringOtherApps: true)
        settingsWindow?.makeKeyAndOrderFront(nil)
    }

    private func showError(_ text: String) {
        guard let button = statusItem.button else { return }
        let popover = NSPopover()
        popover.behavior = .transient
        popover.contentViewController = NSHostingController(rootView:
            VStack(alignment: .leading, spacing: 10) {
                Label(L10n.text("未能切换", "Could Not Switch"), systemImage: "arrow.left.arrow.right").font(.headline)
                Text(text).font(.callout)
                Button(L10n.text("打开设置", "Open Settings")) { [weak self] in self?.errorPopover?.close(); self?.showSettings() }
            }.padding(20).frame(width: 300))
        errorPopover = popover
        popover.show(relativeTo: button.bounds, of: button, preferredEdge: .minY)
    }

    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool { showSettings(); return true }
    func applicationWillTerminate(_ notification: Notification) {
        trackpad.shutdown(); ring.dismiss()
        AppLog.shared.record("stopping", category: .app)
        AppLog.shared.finish()
    }
}

if CommandLine.arguments.contains("--diagnostics") {
    let report: [String: Any] = [
        "version": Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? L10n.text("开发版", "Development"), "os": ProcessInfo.processInfo.operatingSystemVersionString,
        "accessibility": AXIsProcessTrusted(), "screenCapture": CGPreflightScreenCaptureAccess(),
        "captureMode": "on-demand-still", "backgroundWindowPolling": false,
        "updateChecks": "daily-when-running", "automaticInstallation": false,
        "architecture": "native-swift-appkit", "pid": getpid()
    ]
    if let data = try? JSONSerialization.data(withJSONObject: report, options: [.prettyPrinted, .sortedKeys]) {
        print(String(decoding: data, as: UTF8.self))
    }
} else {
    MainActor.assumeIsolated {
        let application = NSApplication.shared
        let delegate = AppDelegate()
        application.delegate = delegate
        application.run()
    }
}
