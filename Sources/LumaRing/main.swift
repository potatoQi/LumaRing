import AppKit
import Combine
import SwiftUI

@MainActor final class AppDelegate: NSObject, NSApplicationDelegate, NSMenuDelegate {
    private var statusItem: NSStatusItem!
    private var settingsWindow: NSWindow?
    private let catalog = ApplicationCatalog()
    private lazy var ring = RingController(catalog: catalog)
    private let hotKey = HotKey()
    private var subscriptions = Set<AnyCancellable>()
    private var tokens: [NSObjectProtocol] = []
    private var registeredShortcut: Shortcut?
    private var errorPopover: NSPopover?

    func applicationDidFinishLaunching(_ notification: Notification) {
        NSApp.setActivationPolicy(.accessory)
        if let iconURL = Bundle.main.url(forResource: "LumaRingIcon-1.3", withExtension: "icns"),
           let icon = NSImage(contentsOf: iconURL) { NSApp.applicationIconImage = icon }
        UpdateService.shared.start()
        let mainMenu = NSMenu()
        let applicationItem = NSMenuItem()
        let applicationMenu = NSMenu()
        applicationMenu.addItem(withTitle: "设置…", action: #selector(settingsAction), keyEquivalent: "").target = self
        applicationMenu.addItem(withTitle: "检查更新…", action: #selector(UpdateService.checkForUpdates(_:)), keyEquivalent: "").target = UpdateService.shared
        applicationMenu.addItem(withTitle: "退出 LumaRing", action: #selector(quit), keyEquivalent: "").target = self
        applicationItem.submenu = applicationMenu
        mainMenu.addItem(applicationItem)
        let windowItem = NSMenuItem(title: "窗口", action: nil, keyEquivalent: "")
        let windowMenu = NSMenu(title: "窗口")
        windowMenu.addItem(withTitle: "关闭", action: #selector(NSWindow.performClose(_:)), keyEquivalent: "")
        windowItem.submenu = windowMenu; mainMenu.addItem(windowItem)
        NSApp.mainMenu = mainMenu
        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.squareLength)
        statusItem.button?.image = NSImage(systemSymbolName: "circle.hexagongrid", accessibilityDescription: "LumaRing 应用与窗口轮盘")
        statusItem.button?.image?.isTemplate = true
        statusItem.button?.toolTip = "LumaRing · 点击呼出轮盘，右键打开菜单"
        statusItem.button?.target = self
        statusItem.button?.action = #selector(statusClicked)
        statusItem.button?.sendAction(on: [.leftMouseUp, .rightMouseUp])
        hotKey.onPress = { [weak self] in self?.ring.pressShortcut() }
        hotKey.onRelease = { [weak self] in self?.ring.releaseShortcut() }
        ring.onSettings = { [weak self] in self?.showSettings() }
        ring.onError = { [weak self] text in self?.showError(text) }
        catalog.onChange = { [weak self] in self?.ring.applicationsChanged() }
        Preferences.shared.$options.sink { [weak self] options in
            guard let self, self.registeredShortcut != options.shortcut else { return }
            let success = self.hotKey.register(options.shortcut)
            self.registeredShortcut = success ? options.shortcut : nil
            // Published changes must not recursively mutate SwiftUI during an update.
            DispatchQueue.main.async {
                Preferences.shared.shortcutError = success ? nil : "快捷键被占用，请换一个组合。菜单栏入口仍可使用。"
            }
        }.store(in: &subscriptions)
        for name in [NSWorkspace.willSleepNotification, NSWorkspace.screensDidSleepNotification, NSWorkspace.sessionDidResignActiveNotification] {
            tokens.append(NSWorkspace.shared.notificationCenter.addObserver(forName: name, object: nil, queue: .main) { [weak self] _ in DispatchQueue.main.async { self?.ring.dismiss() } })
        }
        tokens.append(NotificationCenter.default.addObserver(forName: NSApplication.didChangeScreenParametersNotification, object: nil, queue: .main) { [weak self] _ in DispatchQueue.main.async { self?.ring.dismiss() } })
        let arguments = ProcessInfo.processInfo.arguments
        if arguments.contains("--show-ring") {
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.3) { [weak self] in self?.ring.show() }
        } else if arguments.contains("--settings") || !UserDefaults.standard.bool(forKey: "hasLaunched.v1") {
            showSettings()
        }
        UserDefaults.standard.set(true, forKey: "hasLaunched.v1")
    }

    @objc private func statusClicked() {
        if NSApp.currentEvent?.type == .rightMouseUp { showMenu() }
        else { ring.toggle() }
    }

    private func showMenu() {
        let menu = NSMenu()
        menu.delegate = self
        menu.addItem(withTitle: "设置…", action: #selector(settingsAction), keyEquivalent: "")
        menu.addItem(.separator())
        menu.addItem(withTitle: "退出 LumaRing", action: #selector(quit), keyEquivalent: "")
        menu.items.forEach { $0.target = self }
        let updateItem = NSMenuItem(title: "检查更新…", action: #selector(UpdateService.checkForUpdates(_:)), keyEquivalent: "")
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
            let host = NSHostingController(rootView: SettingsView { [weak self] in
                self?.settingsWindow?.orderOut(nil)
                DispatchQueue.main.async { self?.ring.show() }
            })
            let window = NSWindow(contentViewController: host)
            window.title = "LumaRing 设置"
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
                Label("未能切换", systemImage: "arrow.left.arrow.right").font(.headline)
                Text(text).font(.callout)
                Button("打开设置") { [weak self] in self?.errorPopover?.close(); self?.showSettings() }
            }.padding(20).frame(width: 300))
        errorPopover = popover
        popover.show(relativeTo: button.bounds, of: button, preferredEdge: .minY)
    }

    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool { showSettings(); return true }
    func applicationWillTerminate(_ notification: Notification) { ring.dismiss() }
}

if CommandLine.arguments.contains("--diagnostics") {
    let report: [String: Any] = [
        "version": Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "开发版", "os": ProcessInfo.processInfo.operatingSystemVersionString,
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
