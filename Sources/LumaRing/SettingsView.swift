import AppKit
import Carbon
import LumaRingCore
import ServiceManagement
import SwiftUI
import UniformTypeIdentifiers

struct SettingsView: View {
    @ObservedObject var preferences = Preferences.shared
    @ObservedObject var updates = UpdateService.shared
    @ObservedObject var browserTabs = BrowserTabService.shared
    @ObservedObject var trackpad = TrackpadGesture.shared
    @State private var selectedTab = 0
    @State private var loginEnabled = SMAppService.mainApp.status == .enabled
    @State private var loginError: String?
    @State private var apps: [NSRunningApplication] = []
    @State private var logStatus = AppLog.Status(bytes: 0, writeFailed: false, dropped: 0)
    @State private var logBusy = false

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
                Text(L10n.text("快捷操作", "Actions")).tag(4)
                Text(L10n.text("使用指南", "Guide")).tag(3)
            }.pickerStyle(.segmented).padding(.horizontal, 26).padding(.bottom, 18)
            Divider()
            ScrollView {
                VStack(alignment: .leading, spacing: 18) {
                    switch selectedTab {
                    case 0: general
                    case 1: permissions
                    case 2: launcherSettings; appFilter
                    case 4: ActionSettingsView(profiles: $preferences.options.actionProfiles, invocations: preferences.options.invocationShortcuts)
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
            card(L10n.text("外观", "Appearance"), symbol: "circle.lefthalf.filled") {
                Picker(L10n.text("主题", "Theme"), selection: $preferences.options.theme) {
                    ForEach(AppTheme.allCases, id: \.self) { theme in
                        Text(theme.title).tag(theme)
                    }
                }.pickerStyle(.segmented)
                Picker(L10n.text("轮盘材质", "Ring material"), selection: $preferences.options.ringMaterial) {
                    ForEach(RingMaterialStyle.allCases, id: \.self) { style in
                        Text(style.title).tag(style).disabled(!style.isAvailable)
                    }
                }.pickerStyle(.menu)
                Stepper(value: $preferences.options.centerTitleSize, in: Options.centerTitleSizeRange) {
                    HStack {
                        Text(L10n.text("轮盘中央标题字号", "Ring center title size"))
                        Spacer()
                        Text("\(preferences.options.centerTitleSize) pt").monospacedDigit().foregroundStyle(.secondary)
                    }
                }
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
                        Text(L10n.text("支持单键或组合键。单键会占用该键的全局输入。", "Use a single key or a key combination. A single key is reserved system-wide.")).font(.caption).foregroundStyle(.secondary)
                    }
                    Spacer()
                    ShortcutRecorder(shortcut: $preferences.options.shortcut).frame(width: 155, height: 34)
                }
                if let error = preferences.shortcutError { Text(error).font(.caption).foregroundStyle(.orange) }
                HStack {
                    Text(L10n.text("应用内轮盘快捷键", "App action ring shortcut"))
                    Spacer()
                    ShortcutRecorder(shortcut: $preferences.options.actionShortcut).frame(width: 155, height: 34)
                    if preferences.options.actionShortcut != nil {
                        Button(L10n.text("清除", "Clear")) { preferences.options.actionShortcut = nil }
                    }
                }
                Text(L10n.text("直接呼出当前应用的快捷操作；仍可双击左 Option 切换模式。", "Open actions for the current app directly. Double-tap left Option still switches modes."))
                    .font(.caption).foregroundStyle(.secondary)
                if preferences.options.invocationConflict {
                    Text(L10n.text("两个轮盘快捷键不能相同。", "The two ring shortcuts must be different.")).font(.caption).foregroundStyle(.orange)
                } else if let error = preferences.actionShortcutError { Text(error).font(.caption).foregroundStyle(.orange) }
                Toggle(L10n.text("按住快捷键选择，松开立即切换", "Hold the shortcut to select; release to switch"), isOn: $preferences.options.holdToSelect)
                Text(L10n.text("关闭时：按一次打开轮盘，点击目标或再次按快捷键关闭。", "When off, press once to open the ring. Click a target to switch, or press again to close.")).font(.caption).foregroundStyle(.secondary)
                Divider()
                Picker(L10n.text("触控板呼出轮盘", "Open the ring with trackpad"), selection: $preferences.options.trackpadTap) {
                    ForEach(TrackpadTap.allCases, id: \.self) { Text($0.label).tag($0) }
                }
                Text(L10n.text("轻点后抬起手指，再移动鼠标选择；再次轻点关闭。", "Tap and lift your fingers, then move the pointer to choose. Tap again to close.")).font(.caption).foregroundStyle(.secondary)
                if preferences.options.trackpadTap == .threeFingers {
                    Text(L10n.text("为避免与系统查词冲突，请在系统设置 → 触控板 → 光标与点按中，将“查找与数据检测器”改为单指用力点按或关闭。", "To avoid triggering Look Up, go to System Settings → Trackpad → Point & Click and set Look up & data detectors to Force Click with One Finger or Off.")).font(.caption).foregroundStyle(.secondary)
                }
                Toggle(L10n.text("三指捏合最小化窗口", "Three-finger pinch to minimize the window"), isOn: $preferences.options.threeFingerPinch)
                Text(L10n.text("三指向内捏合后抬起，最小化当前窗口；在 LumaRing 设置中则关闭设置窗口。需要辅助功能权限，默认关闭。", "Pinch inward with three fingers and lift to minimize the current window, or close LumaRing Settings. Requires Accessibility permission; off by default.")).font(.caption).foregroundStyle(.secondary)
                if let message = trackpad.message {
                    HStack(alignment: .top) {
                        Text(message).font(.caption).foregroundStyle(.orange)
                        Spacer()
                        Button(L10n.text("重试", "Retry")) { trackpad.retry() }
                    }
                }
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
            logSettings
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

    private var logSettings: some View {
        card(L10n.text("本地日志", "Local Logs"), symbol: "doc.text") {
            Toggle(L10n.text("记录运行日志", "Record application logs"), isOn: $preferences.options.loggingEnabled)
            Text(L10n.text("用于排查问题，仅保存在本机。不记录窗口标题、网址、自定义名称或文档内容。", "For troubleshooting, stored only on this Mac. Window titles, URLs, custom names and document contents are not recorded."))
                .font(.caption).foregroundStyle(.secondary)
            Text(L10n.text("最多保留 10 MB，超限自动删除最旧日志。关闭后停止记录，已有日志可手动清理。", "Keeps up to 10 MB and removes the oldest logs automatically. Turning logging off stops recording; existing logs can be cleared below."))
                .font(.caption).foregroundStyle(.secondary)
            HStack {
                Text(L10n.text("已用 \(ByteCountFormatter.string(fromByteCount: Int64(logStatus.bytes), countStyle: .file))", "Used: \(ByteCountFormatter.string(fromByteCount: Int64(logStatus.bytes), countStyle: .file))"))
                    .font(.caption).foregroundStyle(.secondary)
                Spacer()
                Button(L10n.text("打开日志文件夹", "Open Log Folder")) {
                    logBusy = true
                    Task { @MainActor in
                        if let folder = await AppLog.shared.folder() { NSWorkspace.shared.open(folder) }
                        logStatus = await AppLog.shared.status()
                        logBusy = false
                    }
                }
                Button(L10n.text("清理日志", "Clear Logs")) {
                    logBusy = true
                    Task { @MainActor in
                        _ = await AppLog.shared.clear()
                        logStatus = await AppLog.shared.status()
                        logBusy = false
                    }
                }
            }.disabled(logBusy)
            if logStatus.writeFailed {
                Text(L10n.text("日志文件暂时无法访问，请检查文件夹权限或剩余磁盘空间。", "Log files could not be accessed. Check folder permissions or available disk space."))
                    .font(.caption).foregroundStyle(.orange)
            }
        }
        .task { logStatus = await AppLog.shared.status() }
        .onReceive(NotificationCenter.default.publisher(for: NSApplication.didBecomeActiveNotification)) { _ in
            Task { @MainActor in logStatus = await AppLog.shared.status() }
        }
    }

    private var launcherSettings: some View {
        card(L10n.text("快捷启动", "Quick Launch"), symbol: "option") {
            Text(L10n.text("应用内轮盘中，或全局轮盘未展开二级轮盘时，按住 Option 显示这些应用，松开返回。全局轮盘也可双击中心展开或收起。", "In the action ring, or the global ring with no secondary ring open, hold Option for these apps and release to return. Double-clicking the global ring's center also toggles favorites."))
                .font(.caption).foregroundStyle(.secondary)
            if preferences.options.launcherApps.isEmpty {
                Text(L10n.text("添加常用应用，即使尚未运行也能启动。", "Add your favorite apps, including ones that are not running.")).foregroundStyle(.secondary)
            }
            ForEach(preferences.options.launcherApps) { app in
                HStack {
                    Image(nsImage: NSWorkspace.shared.icon(forFile: app.path)).resizable().frame(width: 24, height: 24)
                    Text(app.name)
                    Spacer()
                    Button(L10n.text("移除", "Remove")) { preferences.options.launcherApps.removeAll { $0.id == app.id } }
                }
            }
            Button(L10n.text("添加应用…", "Add Apps…")) {
                let panel = NSOpenPanel()
                panel.title = L10n.text("添加快捷启动应用", "Add Quick Launch Apps")
                panel.prompt = L10n.text("添加", "Add")
                panel.allowedContentTypes = [.applicationBundle]
                panel.allowsMultipleSelection = true
                panel.canChooseDirectories = false
                panel.directoryURL = URL(fileURLWithPath: "/Applications", isDirectory: true)
                panel.begin { result in
                    guard result == .OK else { return }
                    let added = panel.urls.compactMap(LauncherApp.read)
                    preferences.options.launcherApps = LauncherApp.unique(preferences.options.launcherApps + added)
                }
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
                        if BrowserAdapters.supports(identifier) {
                            Picker(L10n.text("\(app.localizedName ?? identifier) 的切换内容", "Content for \(app.localizedName ?? identifier)"), selection: Binding(
                                get: { preferences.options.contentMode(for: identifier) },
                                set: { preferences.options.appContentModes[identifier] = $0; browserTabs.refreshAuthorization(apps) }
                            )) {
                                Text(L10n.text("窗口", "Windows")).tag(AppContentMode.windows)
                                Text(L10n.text("标签页", "Tabs")).tag(AppContentMode.tabs)
                            }.labelsHidden().pickerStyle(.segmented).frame(width: 150)
                                .help(L10n.text("选择圆弧中显示的内容", "Choose what appears in the arc"))
                        } else {
                            Text(L10n.text("窗口", "Windows")).foregroundStyle(.secondary)
                        }
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
                Text(L10n.text("点击菜单栏图标打开设置；使用快捷键或触控板手势呼出轮盘。", "Click the menu bar icon to open settings. Use the shortcut or a trackpad gesture to open the ring."))
                Text(L10n.text("在圆盘上滚动可翻应用页，在圆弧上滚动可翻窗口页；也可点击中心的左右箭头。", "Scroll over the ring to page through apps, or over the arc to page through windows. You can also click the center arrows."))
                Text(L10n.text("窗口和标签页按名称排序；悬停窗口可查看预览。右键窗口或标签页可关闭，或通过“修改”设置名称和扇形颜色；留空名称恢复原标题。", "Windows and tabs are sorted by name. Hover over a window to preview it; right-click a window or tab to close it or edit its name and sector color. Leave the name empty to restore its original title."))
                Text(L10n.text("右键应用可新建窗口、选择二级轮盘显示内容或退出应用。", "Right-click an app to create a window, choose secondary ring content, or quit."))
                Text(L10n.text("应用内轮盘中，或全局轮盘未展开二级轮盘时，按住 Option 显示常用应用，松开返回。在“应用管理”中添加应用。", "Hold Option for favorites in the action ring or the global ring with no secondary ring open; release to return. Add apps in App Management."))
            }
            card(L10n.text("当前应用的快捷操作", "Actions for the Current App"), symbol: "keyboard") {
                Text(L10n.text("在“快捷操作”中为应用添加命名的快捷键，使用上下箭头调整顺序。", "In Actions, add named shortcuts for each app and use the arrows to reorder them."))
                Text(L10n.text("轮盘打开时，双击左 Option 切换模式，再点击操作。操作模式不抢焦点；仅提供窗口信息的应用使用窗口级校验。", "With the ring open, double-tap left Option to switch modes, then click an action. Actions do not take focus; apps exposing only window focus use window-level verification."))
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
    @Binding var shortcut: Shortcut?
    init(shortcut: Binding<Shortcut?>) { _shortcut = shortcut }
    init(shortcut: Binding<Shortcut>) {
        _shortcut = Binding(get: { shortcut.wrappedValue }, set: { if let value = $0 { shortcut.wrappedValue = value } })
    }
    func makeNSView(context: Context) -> RecorderButton {
        let button = RecorderButton()
        button.bezelStyle = .rounded
        button.contentTintColor = .labelColor
        button.font = .systemFont(ofSize: 13, weight: .medium)
        button.onRecord = { shortcut = $0 }
        button.title = shortcut?.display ?? L10n.text("录入快捷键", "Record shortcut")
        return button
    }
    func updateNSView(_ nsView: RecorderButton, context: Context) {
        nsView.onRecord = { shortcut = $0 }
        nsView.savedTitle = shortcut?.display ?? L10n.text("录入快捷键", "Record shortcut")
        if !nsView.recording { nsView.title = nsView.savedTitle }
    }
}

final class RecorderButton: NSButton {
    static let recordingDidChange = Notification.Name("LumaRing.shortcutRecordingDidChange")
    private var resignToken: NSObjectProtocol?
    var onRecord: ((Shortcut) -> Void)?
    var recording = false {
        didSet {
            guard recording != oldValue else { return }
            if recording, let window {
                resignToken = NotificationCenter.default.addObserver(forName: NSWindow.didResignKeyNotification, object: window, queue: .main) { [weak self] _ in
                    self?.cancelRecording()
                }
            } else if let resignToken {
                NotificationCenter.default.removeObserver(resignToken); self.resignToken = nil
            }
            NotificationCenter.default.post(name: Self.recordingDidChange, object: recording)
        }
    }
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
        window?.makeFirstResponder(self)
        recording = true; title = L10n.text("按下快捷键…", "Press a shortcut…")
    }
    private func cancelRecording() { recording = false; title = savedTitle }
    override func viewWillMove(toWindow newWindow: NSWindow?) {
        if newWindow == nil { cancelRecording() }
        super.viewWillMove(toWindow: newWindow)
    }
    override func resignFirstResponder() -> Bool {
        cancelRecording()
        return super.resignFirstResponder()
    }
    override func keyDown(with event: NSEvent) {
        guard recording else { super.keyDown(with: event); return }
        if event.keyCode == 53 { recording = false; title = savedTitle; return }
        let flags = event.modifierFlags.intersection(.deviceIndependentFlagsMask)
        var modifiers: UInt32 = 0
        if flags.contains(.command) { modifiers |= UInt32(cmdKey) }
        if flags.contains(.option) { modifiers |= UInt32(optionKey) }
        if flags.contains(.control) { modifiers |= UInt32(controlKey) }
        if flags.contains(.shift) { modifiers |= UInt32(shiftKey) }
        let special: [UInt16: String] = [49: "Space", 48: "Tab", 36: "Return", 51: "⌫", 117: "⌦", 123: "←", 124: "→", 125: "↓", 126: "↑",
            122: "F1", 120: "F2", 99: "F3", 118: "F4", 96: "F5", 97: "F6", 98: "F7", 100: "F8", 101: "F9", 109: "F10", 103: "F11", 111: "F12",
            105: "F13", 107: "F14", 113: "F15", 106: "F16", 64: "F17", 79: "F18", 80: "F19", 90: "F20"]
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
