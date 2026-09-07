import AppKit
import Carbon
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
                    Text("一个小圆盘，轻松切换。").font(.system(size: 13)).foregroundStyle(.secondary)
                }
                Spacer()
            }.padding(26)
            Picker("设置分类", selection: $selectedTab) {
                Text("通用").tag(0)
                Text("权限与性能").tag(1)
                Text("应用管理").tag(2)
                Text("使用指南").tag(3)
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
        .onAppear { refresh() }
        .onReceive(NotificationCenter.default.publisher(for: NSApplication.didBecomeActiveNotification)) { _ in refresh() }
    }

    private var general: some View {
        Group {
            card("软件更新", symbol: "arrow.triangle.2.circlepath") {
                HStack {
                    Text("当前版本 v\(UpdateService.version)")
                    Spacer()
                    Button("检查更新…") { updates.checkForUpdates() }.disabled(!updates.canCheck)
                }
                Toggle("自动检查更新", isOn: Binding(get: { updates.automaticChecks }, set: { updates.setAutomaticChecks($0) }))
                    .disabled(updates.configurationMessage != nil)
                Text("每天检查一次。有新版本时，你可以选择更新、忽略此版本或稍后提醒；不会自动安装。").font(.caption).foregroundStyle(.secondary)
                if let date = updates.lastChecked {
                    Text("上次检查：\(date.formatted(date: .abbreviated, time: .shortened))").font(.caption).foregroundStyle(.secondary)
                }
                if let message = updates.configurationMessage { Text(message).font(.caption).foregroundStyle(.secondary) }
            }
            card("唤起", symbol: "keyboard") {
                HStack {
                    VStack(alignment: .leading, spacing: 5) {
                        Text("全局快捷键")
                        Text("点击右侧，按下要使用的呼出组合键。").font(.caption).foregroundStyle(.secondary)
                    }
                    Spacer()
                    ShortcutRecorder(shortcut: $preferences.options.shortcut).frame(width: 155, height: 34)
                }
                if let error = preferences.shortcutError { Text(error).font(.caption).foregroundStyle(.orange) }
                Toggle("按住快捷键选择，松开立即切换", isOn: $preferences.options.holdToSelect)
                Text("关闭时：按一次打开轮盘，点击目标或再次按快捷键关闭。").font(.caption).foregroundStyle(.secondary)
                Divider()
                Toggle("登录时启动", isOn: $loginEnabled).onChange(of: loginEnabled) { _, value in
                    do {
                        if value { try SMAppService.mainApp.register() } else { try SMAppService.mainApp.unregister() }
                        loginError = nil
                    } catch { loginError = "无法更改登录项：\(error.localizedDescription)" }
                    loginEnabled = SMAppService.mainApp.status == .enabled
                }
                if let loginError { Text(loginError).font(.caption).foregroundStyle(.orange) }
            }
            card("轮盘", symbol: "circle.circle") {
                HStack {
                    Text("展开等待")
                    Slider(value: $preferences.options.hoverDelay, in: 0.08...0.5, step: 0.01)
                    Text("\(Int(preferences.options.hoverDelay * 1000)) ms").monospacedDigit().frame(width: 62)
                }
                HStack {
                    Text("圆盘直径")
                    Slider(value: $preferences.options.ringSize, in: 400...560, step: 20)
                    Text("\(Int(preferences.options.ringSize * 236 / 480)) pt").monospacedDigit().frame(width: 62)
                }
                Stepper(value: $preferences.options.appPageSize, in: 4...24) {
                    HStack {
                        Text("分区大小")
                        Spacer()
                        Text("每页 \(preferences.options.appPageSize) 个 App").monospacedDigit().foregroundStyle(.secondary)
                    }
                }
                Text("默认 12 个，可设为 6、8、16 等；图标随数量自动调整大小。").font(.caption).foregroundStyle(.secondary)
                HStack {
                    Text("预览大小")
                    Slider(value: $preferences.options.previewWidth, in: 400...960, step: 40)
                    Text("\(Int(preferences.options.previewWidth)) × \(Int(preferences.options.previewSize.height)) pt")
                        .monospacedDigit().frame(width: 108)
                }
                Text("默认 840 × 630 pt；空间不足时自动缩小，保持在圆盘旁。").font(.caption).foregroundStyle(.secondary)
                Toggle("包含已最小化的窗口", isOn: $preferences.options.includeMinimized)
                Toggle("按应用名称排序", isOn: $preferences.options.sortByName)
                Text("默认按名称排序；关闭后按最近使用排列。").font(.caption).foregroundStyle(.secondary)
            }
        }
    }

    private var permissions: some View {
        Group {
            card("辅助功能", symbol: "accessibility") {
                Text("读取各 App 的窗口标题，并将你选中的窗口置前。")
                HStack {
                    Label(preferences.accessibilityGranted ? "已授权" : "尚未授权", systemImage: preferences.accessibilityGranted ? "checkmark.circle.fill" : "lock.circle")
                        .foregroundStyle(preferences.accessibilityGranted ? Color.mint : Color.orange)
                    Spacer()
                    Button(preferences.accessibilityGranted ? "打开系统设置" : "授予辅助功能权限") {
                        preferences.requestAccessibility()
                    }
                }
                Text("在系统设置中打开 LumaRing 的开关，然后回到这里。无需重启电脑。").font(.caption).foregroundStyle(.secondary)
            }
            card("窗口预览", symbol: "macwindow") {
                Toggle("悬停窗口时展开大预览", isOn: $preferences.options.previews)
                Text("预览就近显示在圆弧旁，自动避让圆盘和屏幕边缘。").font(.caption).foregroundStyle(.secondary)
                HStack {
                    Label(preferences.screenCaptureGranted ? "已授权" : "尚未授权", systemImage: preferences.screenCaptureGranted ? "checkmark.circle.fill" : "lock.circle")
                        .foregroundStyle(preferences.screenCaptureGranted ? Color.mint : Color.orange)
                    Spacer()
                    Button(preferences.checkingCapture ? "正在检测…" : "检测预览权限") { preferences.requestCapture() }
                        .disabled(preferences.checkingCapture)
                }
                if let message = preferences.captureMessage {
                    Text(message).font(.caption).foregroundStyle(.secondary).textSelection(.enabled)
                }
                Button("打开屏幕录制设置") { preferences.openPrivacy("Privacy_ScreenCapture") }
                Text("若系统开关已开启但检测仍被拒绝，请在系统设置中移除旧的 LumaRing，再添加 Applications 中的当前版本，然后退出并重开应用。最小化窗口暂不提供图片预览。").font(.caption).foregroundStyle(.secondary)
            }
        }
    }

    private var appFilter: some View {
        card("轮盘中的应用", symbol: "square.grid.2x2") {
            Text("取消勾选即可隐藏。这里只列出正在运行的普通应用。").font(.caption).foregroundStyle(.secondary)
            Text("每个应用默认显示窗口。Edge 和 Chrome 可切换为标签页，其他应用暂未适配。").font(.caption).foregroundStyle(.secondary)
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
                        Picker("\(app.localizedName ?? identifier) 的切换内容", selection: Binding(
                            get: { preferences.options.contentMode(for: identifier) },
                            set: { preferences.options.appContentModes[identifier] = $0; browserTabs.refreshAuthorization(apps) }
                        )) {
                            Text("窗口").tag(AppContentMode.windows)
                            Text("标签页").tag(AppContentMode.tabs)
                        }.labelsHidden().pickerStyle(.segmented).frame(width: 150)
                            .disabled(!BrowserAdapters.supports(identifier))
                            .saturation(BrowserAdapters.supports(identifier) ? 1 : 0)
                            .help(BrowserAdapters.supports(identifier) ? "选择圆弧中显示的内容" : "此应用暂未适配标签页")
                    }
                    if preferences.options.contentMode(for: identifier) == .tabs {
                        HStack(alignment: .top) {
                            Label(browserTabs.messages[identifier] ?? "需要连接浏览器，允许读取和切换标签页。",
                                  systemImage: browserTabs.connected.contains(identifier) ? "checkmark.circle.fill" : "lock.circle")
                                .font(.caption)
                                .foregroundStyle(browserTabs.connected.contains(identifier) ? Color.mint : Color.orange)
                                .fixedSize(horizontal: false, vertical: true)
                            Spacer()
                            Button(browserTabs.connecting.contains(identifier) ? "连接中…" : "连接浏览器") { browserTabs.connect(app) }
                                .disabled(browserTabs.connecting.contains(identifier))
                        }.padding(.leading, 22)
                    }
                }
            }
            Text("标签页悬停显示标题与网址；图片预览用于窗口。连接只需首次授权，可在系统设置的“自动化”中管理。").font(.caption).foregroundStyle(.secondary)
            if apps.contains(where: { preferences.options.contentMode(for: $0.bundleIdentifier ?? "") == .tabs }) {
                Button("打开自动化设置") { preferences.openPrivacy("Privacy_Automation") }
            }
            HStack {
                Button("刷新应用列表") { refresh() }
                Spacer()
                Button("显示全部应用") { preferences.options.excludedBundleIDs = [] }
            }.padding(.top, 8)
        }
    }

    private var guide: some View {
        Group {
            card(preferences.options.holdToSelect ? "按住 · 移动 · 松开" : "呼出 · 移动 · 点击", symbol: "cursorarrow.motionlines") {
                Text(preferences.options.holdToSelect ? "1  按住 \(preferences.options.shortcut.display)，呼出圆盘。" : "1  按一次 \(preferences.options.shortcut.display)，呼出圆盘。")
                Text("2  把鼠标移到目标 App。有多个窗口或标签页时，会展开紧贴圆盘的圆弧。")
                Text(preferences.options.holdToSelect ? "3  指向 App 或具体窗口，松开呼出快捷键，立即切换。" : "3  点击 App 或具体窗口，立即切换。")
                Text(preferences.options.holdToSelect ? "没有选中目标时松开，只会关闭圆盘。" : "再次按呼出快捷键或点击圆盘外关闭。").font(.caption).foregroundStyle(.secondary)
            }
            card("用鼠标操作", symbol: "computermouse") {
                Text("也可以点击菜单栏图标呼出，然后点击 App 或窗口切换。")
                Text("在圆盘上滚动可翻应用页，在圆弧上滚动可翻窗口页；也可点击中心的左右箭头。")
                Text("悬停窗口可在旁边查看大预览。")
                Text("点击圆盘外关闭；右键圆盘或菜单栏图标打开设置。")
            }
            card("权限", symbol: "lock") {
                Text("窗口列表与切换需要辅助功能权限；窗口图片预览需要屏幕录制权限。")
                Text("默认显示窗口；在“应用管理”中可为 Edge 和 Chrome 选择标签页，并连接浏览器。标签页读取和切换需要该浏览器的自动化权限。").font(.caption).foregroundStyle(.secondary)
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
        recording = true; title = "按下组合键…"
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
        guard !flags.intersection([.command, .option, .control]).isEmpty else { title = "请加 ⌃ / ⌥ / ⌘"; return }
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
