import AppKit
import Carbon
import LumaRingCore
import ServiceManagement
import SwiftUI

struct SettingsView: View {
    @ObservedObject var preferences = Preferences.shared
    @ObservedObject var updates = UpdateService.shared
    @ObservedObject var browserTabs = BrowserTabService.shared
    @State private var selectedTab = 0
    @State private var loginEnabled = SMAppService.mainApp.status == .enabled
    @State private var loginError: String?
    @State private var apps: [NSRunningApplication] = []

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(spacing: 16) {
                Image(nsImage: NSApp.applicationIconImage).resizable().scaledToFit()
                    .frame(width: 44, height: 44)
                VStack(alignment: .leading, spacing: 5) {
                    Text("LumaRing").font(.system(size: 22, weight: .semibold, design: .rounded))
                    Text(L10n.text("一个小圆盘，轻松切换。", "A small ring. An easy switch.")).font(.system(size: 13)).foregroundStyle(.secondary)
                }
                Spacer()
            }.padding(26)
            Picker(L10n.text("设置分类", "Settings category"), selection: $selectedTab) {
                Text(L10n.text("通用", "General")).tag(0)
                Text(L10n.text("权限与性能", "Permissions")).tag(1)
                Text(L10n.text("应用管理", "App Management")).tag(2)
                Text(L10n.text("使用指南", "Guide")).tag(3)
            }.pickerStyle(.segmented).padding(.horizontal, 26).padding(.bottom, 18)
            Divider()
            ScrollView {
                VStack(alignment: .leading, spacing: 18) {
                    switch selectedTab {
                    case 0: general
                    case 1: permissions
                    case 2: appFilter
                    default: guide
                    }
                }.padding(26).frame(maxWidth: .infinity, alignment: .leading)
            }
            Divider()
            HStack {
                Spacer()
                Text("v\(UpdateService.version)")
            }.font(.system(size: 11)).foregroundStyle(.secondary).padding(.horizontal, 26).padding(.vertical, 14)
        }
        .frame(minWidth: 650, idealWidth: 680, minHeight: 620, idealHeight: 690)
        .environment(\.locale, preferences.language.locale)
        .onAppear { refresh() }
        .onChange(of: preferences.language) { _, _ in
            loginError = nil
            browserTabs.refreshLanguage()
            refresh()
        }
        .onReceive(NotificationCenter.default.publisher(for: NSApplication.didBecomeActiveNotification)) { _ in refresh() }
    }

    private var general: some View {
        Group {
            card(L10n.text("语言", "Language"), symbol: "globe") {
                Picker(L10n.text("界面语言", "Interface language"), selection: $preferences.language) {
                    ForEach(AppLanguage.allCases, id: \.self) { language in
                        Text(language.title).tag(language)
                    }
                }.pickerStyle(.segmented)
                Text(L10n.text("更改立即生效。", "Changes apply immediately."))
                    .font(.caption).foregroundStyle(.secondary)
            }
            card(L10n.text("软件更新", "Software Updates"), symbol: "arrow.triangle.2.circlepath") {
                HStack {
                    Text(L10n.text("当前版本 v\(UpdateService.version)", "Current version v\(UpdateService.version)"))
                    Spacer()
                    Button(L10n.text("检查更新…", "Check for Updates…")) { updates.checkForUpdates() }.disabled(!updates.canCheck)
                }
                Toggle(L10n.text("自动检查更新", "Automatically check for updates"), isOn: Binding(get: { updates.automaticChecks }, set: { updates.setAutomaticChecks($0) }))
                    .disabled(updates.configurationMessage != nil)
                Text(L10n.text("每天检查一次。有新版本时，你可以选择更新、忽略此版本或稍后提醒；不会自动安装。", "Checks daily. Choose to install an update, skip it, or be reminded later. Updates are never installed automatically.")).font(.caption).foregroundStyle(.secondary)
                if let date = updates.lastChecked {
                    Text(L10n.text("上次检查：\(date.formatted(.dateTime.year().month().day().hour().minute().locale(preferences.language.locale)))", "Last checked: \(date.formatted(.dateTime.year().month().day().hour().minute().locale(preferences.language.locale)))")).font(.caption).foregroundStyle(.secondary)
                }
                if let message = updates.configurationMessage { Text(message).font(.caption).foregroundStyle(.secondary) }
            }
            card(L10n.text("唤起", "Activation"), symbol: "keyboard") {
                HStack {
                    VStack(alignment: .leading, spacing: 5) {
                        Text(L10n.text("全局快捷键", "Global shortcut"))
                        Text(L10n.text("点击右侧，按下要使用的呼出组合键。", "Click the button, then press your preferred key combination.")).font(.caption).foregroundStyle(.secondary)
                    }
                    Spacer()
                    ShortcutRecorder(shortcut: $preferences.options.shortcut).frame(width: 155, height: 34)
                }
                if let error = preferences.shortcutError { Text(error).font(.caption).foregroundStyle(.orange) }
                Toggle(L10n.text("按住快捷键选择，松开立即切换", "Hold the shortcut to select; release to switch"), isOn: $preferences.options.holdToSelect)
                Text(L10n.text("关闭时：按一次打开轮盘，点击目标或再次按快捷键关闭。", "When off, press once to open the ring. Click a target to switch, or press again to close.")).font(.caption).foregroundStyle(.secondary)
                Divider()
                Toggle(L10n.text("登录时启动", "Launch at login"), isOn: $loginEnabled).onChange(of: loginEnabled) { _, value in
                    do {
                        if value { try SMAppService.mainApp.register() } else { try SMAppService.mainApp.unregister() }
                        loginError = nil
                    } catch { loginError = L10n.text("无法更改登录项：\(error.localizedDescription)", "Could not change the login item: \(error.localizedDescription)") }
                    loginEnabled = SMAppService.mainApp.status == .enabled
                }
                if let loginError { Text(loginError).font(.caption).foregroundStyle(.orange) }
            }
            card(L10n.text("轮盘", "Ring"), symbol: "circle.circle") {
                HStack {
                    Text(L10n.text("圆盘直径", "Ring diameter"))
                    Slider(value: $preferences.options.ringSize, in: 400...560, step: 20)
                    Text("\(Int(preferences.options.ringSize * 236 / 480)) pt").monospacedDigit().frame(width: 62)
                }
                Stepper(value: $preferences.options.appPageSize, in: 4...24) {
                    HStack {
                        Text(L10n.text("分区大小", "Apps per page"))
                        Spacer()
                        Text(L10n.text("每页 \(preferences.options.appPageSize) 个 App", "\(preferences.options.appPageSize) apps per page")).monospacedDigit().foregroundStyle(.secondary)
                    }
                }
                Text(L10n.text("默认 12 个，可设为 6、8、16 等；图标随数量自动调整大小。", "Defaults to 12. Choose 6, 8, 16, or another count; icons resize to fit.")).font(.caption).foregroundStyle(.secondary)
                Stepper(value: $preferences.options.windowPageSize, in: RingGeometry.windowPageSizeRange) {
                    HStack {
                        Text(L10n.text("二级轮盘每页数量", "Outer ring items per page"))
                        Spacer()
                        Text(L10n.text("每页 \(preferences.options.windowPageSize) 个", "\(preferences.options.windowPageSize) per page")).monospacedDigit().foregroundStyle(.secondary)
                    }
                }
                Text(L10n.text("默认 6 个，可设为 2–8 个；窗口和标签页模式均适用。", "Defaults to 6. Choose 2–8; applies to both windows and tabs.")).font(.caption).foregroundStyle(.secondary)
                HStack {
                    Text(L10n.text("预览大小", "Preview size"))
                    Slider(value: $preferences.options.previewWidth, in: 400...960, step: 40)
                    Text("\(Int(preferences.options.previewWidth)) × \(Int(preferences.options.previewSize.height)) pt")
                        .monospacedDigit().frame(width: 108)
                }
                Text(L10n.text("默认 840 × 630 pt；空间不足时自动缩小，保持在圆盘旁。", "Defaults to 840 × 630 pt. Previews shrink to fit beside the ring.")).font(.caption).foregroundStyle(.secondary)
                Toggle(L10n.text("包含已最小化的窗口", "Include minimized windows"), isOn: $preferences.options.includeMinimized)
                Toggle(L10n.text("按应用名称排序", "Sort apps by name"), isOn: $preferences.options.sortByName)
                Text(L10n.text("默认按名称排序；关闭后按最近使用排列。", "When off, apps are sorted by recent use.")).font(.caption).foregroundStyle(.secondary)
            }
        }
    }

    private var permissions: some View {
        Group {
            card(L10n.text("辅助功能", "Accessibility"), symbol: "accessibility") {
                Text(L10n.text("读取各 App 的窗口标题，并将你选中的窗口置前。", "Read window titles and bring the selected window to the front."))
                HStack {
                    Label(preferences.accessibilityGranted ? L10n.text("已授权", "Access granted") : L10n.text("尚未授权", "Access not granted"), systemImage: preferences.accessibilityGranted ? "checkmark.circle.fill" : "lock.circle")
                        .foregroundStyle(preferences.accessibilityGranted ? Color.mint : Color.orange)
                    Spacer()
                    Button(preferences.accessibilityGranted ? L10n.text("打开系统设置", "Open System Settings") : L10n.text("授予辅助功能权限", "Grant Accessibility Access")) {
                        preferences.requestAccessibility()
                    }
                }
                Text(L10n.text("在系统设置中打开 LumaRing 的开关，然后回到这里。无需重启电脑。", "Enable LumaRing in System Settings, then return here. No need to restart your Mac.")).font(.caption).foregroundStyle(.secondary)
            }
            card(L10n.text("窗口预览", "Window Previews"), symbol: "macwindow") {
                Toggle(L10n.text("悬停窗口时展开大预览", "Show a large preview when hovering over a window"), isOn: $preferences.options.previews)
                Text(L10n.text("预览就近显示在圆弧旁，自动避让圆盘和屏幕边缘。", "Previews appear beside the arc and adjust to the ring and screen edges.")).font(.caption).foregroundStyle(.secondary)
                HStack {
                    Label(preferences.screenCaptureGranted ? L10n.text("已授权", "Access granted") : L10n.text("尚未授权", "Access not granted"), systemImage: preferences.screenCaptureGranted ? "checkmark.circle.fill" : "lock.circle")
                        .foregroundStyle(preferences.screenCaptureGranted ? Color.mint : Color.orange)
                    Spacer()
                    Button(preferences.checkingCapture ? L10n.text("正在检测…", "Checking…") : L10n.text("检测预览权限", "Check Preview Access")) { preferences.requestCapture() }
                        .disabled(preferences.checkingCapture)
                }
                if let message = preferences.captureMessage {
                    Text(message).font(.caption).foregroundStyle(.secondary).textSelection(.enabled)
                }
                Button(L10n.text("打开屏幕录制设置", "Open Screen Recording Settings")) { preferences.openPrivacy("Privacy_ScreenCapture") }
                Text(L10n.text("若系统开关已开启但检测仍被拒绝，请在系统设置中移除旧的 LumaRing，再添加 Applications 中的当前版本，然后退出并重开应用。最小化窗口暂不提供图片预览。", "If access is denied despite being enabled, remove the old LumaRing entry in System Settings, add the current app from Applications, then quit and reopen it. Minimized windows do not have image previews.")).font(.caption).foregroundStyle(.secondary)
            }
        }
    }

    private var appFilter: some View {
        card(L10n.text("轮盘中的应用", "Apps in the Ring"), symbol: "square.grid.2x2") {
            Text(L10n.text("取消勾选即可隐藏。这里只列出正在运行的普通应用。", "Uncheck an app to hide it. Only currently running regular apps are listed.")).font(.caption).foregroundStyle(.secondary)
            Text(L10n.text("每个应用默认显示窗口。Edge 和 Chrome 可切换为标签页，其他应用暂未适配。", "Apps show windows by default. Edge and Chrome also support tabs.")).font(.caption).foregroundStyle(.secondary)
            ForEach(apps.filter { $0.bundleIdentifier != nil }, id: \.processIdentifier) { app in
                let identifier = app.bundleIdentifier ?? ""
                VStack(alignment: .leading, spacing: 7) {
                    HStack {
                        Toggle(isOn: Binding(get: { !preferences.options.excludedBundleIDs.contains(identifier) }, set: { visible in
                            preferences.options.excludedBundleIDs.removeAll { $0 == identifier }
                            if !visible { preferences.options.excludedBundleIDs.append(identifier) }
                        })) {
                            HStack {
                                if let icon = app.icon { Image(nsImage: icon).resizable().frame(width: 22, height: 22) }
                                Text(app.localizedName ?? identifier)
                            }
                        }
                        Spacer(minLength: 12)
                        Picker(L10n.text("\(app.localizedName ?? identifier) 的切换内容", "Content for \(app.localizedName ?? identifier)"), selection: Binding(
                            get: { preferences.options.contentMode(for: identifier) },
                            set: { preferences.options.appContentModes[identifier] = $0; browserTabs.refreshAuthorization(apps) }
                        )) {
                            Text(L10n.text("窗口", "Windows")).tag(AppContentMode.windows)
                            Text(L10n.text("标签页", "Tabs")).tag(AppContentMode.tabs)
                        }.labelsHidden().pickerStyle(.segmented).frame(width: 150)
                            .disabled(!BrowserAdapters.supports(identifier))
                            .saturation(BrowserAdapters.supports(identifier) ? 1 : 0)
                            .help(BrowserAdapters.supports(identifier) ? L10n.text("选择圆弧中显示的内容", "Choose what appears in the arc") : L10n.text("此应用暂未适配标签页", "Tabs are not supported for this app"))
                    }
                    if preferences.options.contentMode(for: identifier) == .tabs {
                        HStack(alignment: .top) {
                            Label(browserTabs.messages[identifier] ?? L10n.text("需要连接浏览器，允许读取和切换标签页。", "Connect the browser to allow reading and switching tabs."),
                                  systemImage: browserTabs.connected.contains(identifier) ? "checkmark.circle.fill" : "lock.circle")
                                .font(.caption)
                                .foregroundStyle(browserTabs.connected.contains(identifier) ? Color.mint : Color.orange)
                                .fixedSize(horizontal: false, vertical: true)
                            Spacer()
                            Button(browserTabs.connecting.contains(identifier) ? L10n.text("连接中…", "Connecting…") : L10n.text("连接浏览器", "Connect Browser")) { browserTabs.connect(app) }
                                .disabled(browserTabs.connecting.contains(identifier))
                        }.padding(.leading, 22)
                    }
                }
            }
            Text(L10n.text("标签页悬停显示标题与网址；图片预览用于窗口。连接只需首次授权，可在系统设置的“自动化”中管理。", "Tab previews show titles and URLs; window previews show images. Authorize the browser once, then manage access under Automation in System Settings.")).font(.caption).foregroundStyle(.secondary)
            if apps.contains(where: { preferences.options.contentMode(for: $0.bundleIdentifier ?? "") == .tabs }) {
                Button(L10n.text("打开自动化设置", "Open Automation Settings")) { preferences.openPrivacy("Privacy_Automation") }
            }
            HStack {
                Button(L10n.text("刷新应用列表", "Refresh App List")) { refresh() }
                Spacer()
                Button(L10n.text("显示全部应用", "Show All Apps")) { preferences.options.excludedBundleIDs = [] }
            }.padding(.top, 8)
        }
    }

    private var guide: some View {
        Group {
            card(preferences.options.holdToSelect ? L10n.text("按住 · 移动 · 松开", "Hold · Point · Release") : L10n.text("呼出 · 移动 · 点击", "Open · Point · Click"), symbol: "cursorarrow.motionlines") {
                Text(preferences.options.holdToSelect ? L10n.text("1  按住 \(preferences.options.shortcut.display)，呼出圆盘。", "1  Hold \(preferences.options.shortcut.display) to open the ring.") : L10n.text("1  按一次 \(preferences.options.shortcut.display)，呼出圆盘。", "1  Press \(preferences.options.shortcut.display) to open the ring."))
                Text(L10n.text("2  把鼠标移到目标 App。有多个窗口或标签页时，会展开紧贴圆盘的圆弧。", "2  Point at an app. An attached arc opens when it has multiple windows or tabs."))
                Text(preferences.options.holdToSelect ? L10n.text("3  指向 App 或具体窗口，松开呼出快捷键，立即切换。", "3  Point at an app or window, then release the shortcut to switch.") : L10n.text("3  点击 App 或具体窗口，立即切换。", "3  Click an app or window to switch."))
                Text(preferences.options.holdToSelect ? L10n.text("没有选中目标时松开，只会关闭圆盘。", "Releasing without a target closes the ring.") : L10n.text("再次按呼出快捷键或点击圆盘外关闭。", "Press the shortcut again or click outside the ring to close it.")).font(.caption).foregroundStyle(.secondary)
            }
            card(L10n.text("用鼠标操作", "Mouse Controls"), symbol: "computermouse") {
                Text(L10n.text("也可以点击菜单栏图标呼出，然后点击 App 或窗口切换。", "You can also click the menu bar icon, then click an app or window to switch."))
                Text(L10n.text("在圆盘上滚动可翻应用页，在圆弧上滚动可翻窗口页；也可点击中心的左右箭头。", "Scroll over the ring to page through apps, or over the arc to page through windows. You can also click the center arrows."))
                Text(L10n.text("悬停窗口可在旁边查看大预览。", "Hover over a window to see a large preview beside it."))
                Text(L10n.text("点击圆盘外关闭；右键圆盘或菜单栏图标打开设置。", "Click outside to close. Right-click the ring or menu bar icon to open settings."))
            }
            card(L10n.text("权限", "Permissions"), symbol: "lock") {
                Text(L10n.text("窗口列表与切换需要辅助功能权限；窗口图片预览需要屏幕录制权限。", "Window lists and switching require Accessibility access. Image previews require Screen Recording access."))
                Text(L10n.text("默认显示窗口；在“应用管理”中可为 Edge 和 Chrome 选择标签页，并连接浏览器。标签页读取和切换需要该浏览器的自动化权限。", "Windows are shown by default. In App Management, select Tabs for Edge or Chrome and connect the browser. Reading and switching tabs requires Automation access.")).font(.caption).foregroundStyle(.secondary)
            }
        }
    }

    private func refresh() {
        preferences.refreshPermissions()
        loginEnabled = SMAppService.mainApp.status == .enabled
        apps = NSWorkspace.shared.runningApplications.filter { $0.activationPolicy == .regular && $0.processIdentifier != getpid() }
            .sorted { ($0.localizedName ?? "") < ($1.localizedName ?? "") }
        browserTabs.refreshAuthorization(apps)
    }

    private func card<Content: View>(_ title: String, symbol: String, @ViewBuilder content: () -> Content) -> some View {
        VStack(alignment: .leading, spacing: 13) {
            Label(title, systemImage: symbol).font(.system(size: 14, weight: .semibold)).padding(.bottom, 3)
            content().font(.system(size: 12))
        }.padding(19).frame(maxWidth: .infinity, alignment: .leading)
            .background(Color.primary.opacity(0.035), in: RoundedRectangle(cornerRadius: 14))
            .overlay(RoundedRectangle(cornerRadius: 14).stroke(Color.primary.opacity(0.07)))
    }
}

struct ShortcutRecorder: NSViewRepresentable {
    @Binding var shortcut: Shortcut
    func makeNSView(context: Context) -> RecorderButton {
        let button = RecorderButton()
        button.bezelStyle = .rounded
        button.onRecord = { shortcut = $0 }
        button.title = shortcut.display
        return button
    }
    func updateNSView(_ nsView: RecorderButton, context: Context) {
        nsView.onRecord = { shortcut = $0 }
        if !nsView.recording { nsView.title = shortcut.display }
        nsView.savedTitle = shortcut.display
    }
}

final class RecorderButton: NSButton {
    var onRecord: ((Shortcut) -> Void)?
    var recording = false
    var savedTitle = ""
    override var acceptsFirstResponder: Bool { true }
    override func mouseDown(with event: NSEvent) {
        beginRecording()
    }
    override func accessibilityPerformPress() -> Bool {
        beginRecording()
        return true
    }
    override func performClick(_ sender: Any?) {
        beginRecording()
    }
    private func beginRecording() {
        recording = true; title = L10n.text("按下组合键…", "Press a shortcut…")
        window?.makeFirstResponder(self)
    }
    override func resignFirstResponder() -> Bool {
        recording = false; title = savedTitle
        return super.resignFirstResponder()
    }
    override func keyDown(with event: NSEvent) {
        guard recording else { super.keyDown(with: event); return }
        if event.keyCode == 53 { recording = false; title = savedTitle; return }
        let flags = event.modifierFlags.intersection(.deviceIndependentFlagsMask)
        guard !flags.intersection([.command, .option, .control]).isEmpty else { title = L10n.text("请加 ⌃ / ⌥ / ⌘", "Include ⌃ / ⌥ / ⌘"); return }
        var modifiers: UInt32 = 0
        if flags.contains(.command) { modifiers |= UInt32(cmdKey) }
        if flags.contains(.option) { modifiers |= UInt32(optionKey) }
        if flags.contains(.control) { modifiers |= UInt32(controlKey) }
        if flags.contains(.shift) { modifiers |= UInt32(shiftKey) }
        let special: [UInt16: String] = [49: "Space", 48: "Tab", 36: "Return", 123: "←", 124: "→", 125: "↓", 126: "↑"]
        let name = special[event.keyCode] ?? event.charactersIgnoringModifiers?.uppercased() ?? "Key \(event.keyCode)"
        recording = false
        let shortcut = Shortcut(keyCode: UInt32(event.keyCode), modifiers: modifiers, label: name)
        title = shortcut.display; savedTitle = title
        onRecord?(shortcut)
    }
    override func performKeyEquivalent(with event: NSEvent) -> Bool {
        if recording { keyDown(with: event); return true }
        return super.performKeyEquivalent(with: event)
    }
}
