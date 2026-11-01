import AppKit
import Carbon
import LumaRingCore
import ServiceManagement
import SwiftUI
import UniformTypeIdentifiers

enum SettingsSection: CaseIterable, Identifiable {
    case general, appearance, apps, actions, permissions, about, guide
    var id: Self { self }
    var title: String {
        switch self {
        case .general: return L10n.text("通用", "General")
        case .appearance: return L10n.text("外观", "Appearance")
        case .apps: return L10n.text("应用", "Apps")
        case .actions: return L10n.text("快捷操作", "Actions")
        case .permissions: return L10n.text("权限", "Permissions")
        case .about: return L10n.text("关于", "About")
        case .guide: return L10n.text("使用指南", "Quick Guide")
        }
    }
    var symbol: String {
        switch self {
        case .general: return "keyboard"
        case .appearance: return "circle.lefthalf.filled"
        case .apps: return "square.grid.2x2"
        case .actions: return "bolt"
        case .permissions: return "lock.shield"
        case .about: return "info.circle"
        case .guide: return "questionmark.circle"
        }
    }
}

struct SettingsView: View {
    @ObservedObject var preferences = Preferences.shared
    @ObservedObject var updates = UpdateService.shared
    @ObservedObject var browserTabs = BrowserTabService.shared
    @ObservedObject var trackpad = TrackpadGesture.shared
    @State private var selectedSection: SettingsSection
    @State private var loginEnabled = SMAppService.mainApp.status == .enabled
    @State private var loginError: String?
    @State private var apps: [NSRunningApplication] = []
    @State private var logStatus = AppLog.Status(bytes: 0, writeFailed: false, dropped: 0)
    @State private var logBusy = false

    init(section: SettingsSection = .general) {
        _selectedSection = State(initialValue: section)
    }

    var body: some View {
        HStack(spacing: 0) {
            VStack(alignment: .leading, spacing: 6) {
                HStack(spacing: 9) {
                    Image(nsImage: NSApp.applicationIconImage).resizable().scaledToFit().frame(width: 28, height: 28)
                    Text("LumaRing").font(.system(size: 15, weight: .semibold, design: .rounded))
                }.padding(.horizontal, 8).padding(.top, 12).padding(.bottom, 22)
                ForEach(SettingsSection.allCases.filter { $0 != .guide }) { section in
                    navigationButton(section)
                }
                Spacer()
                navigationButton(.guide)
            }.padding(12).frame(width: 170)
                .background(Color.primary.opacity(0.035))
            Divider()
            VStack(alignment: .leading, spacing: 0) {
                Text(selectedSection.title).font(.system(size: 22, weight: .semibold))
                    .padding(.horizontal, 24).padding(.top, 26).padding(.bottom, 20)
                ScrollView {
                    VStack(alignment: .leading, spacing: 22) {
                        switch selectedSection {
                        case .general: general
                        case .appearance: appearance
                        case .apps: appFilter; launcherSettings
                        case .actions:
                            card(L10n.text("应用内的常用操作", "Shortcuts for each app")) {
                                ActionSettingsView(profiles: $preferences.options.actionProfiles,
                                    invocations: preferences.options.invocationShortcuts)
                            }
                        case .permissions: permissions
                        case .about: about
                        case .guide: guide
                        }
                    }.padding(.horizontal, 24).padding(.bottom, 24).frame(maxWidth: .infinity, alignment: .leading)
                }.id(selectedSection)
            }.frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        }
        .background(Color(nsColor: .windowBackgroundColor))
        .frame(minWidth: 680, idealWidth: 680, minHeight: 620, idealHeight: 690)
        .environment(\.locale, preferences.language.locale)
        .onAppear { refresh() }
        .onChange(of: preferences.language) { _, _ in
            loginError = nil
            browserTabs.refreshLanguage()
            refresh()
        }
        .onReceive(NotificationCenter.default.publisher(for: NSApplication.didBecomeActiveNotification)) { _ in refresh() }
    }

    private func navigationButton(_ section: SettingsSection) -> some View {
        Button { selectedSection = section } label: {
            HStack(spacing: 9) {
                Image(systemName: section.symbol).frame(width: 18)
                Text(section.title).lineLimit(1)
                Spacer(minLength: 0)
            }.font(.system(size: 13, weight: selectedSection == section ? .medium : .regular))
                .padding(.horizontal, 10).padding(.vertical, 9)
                .contentShape(Rectangle())
                .foregroundStyle(selectedSection == section ? Color.accentColor : Color.primary)
                .background(selectedSection == section ? Color.accentColor.opacity(0.12) : .clear,
                            in: RoundedRectangle(cornerRadius: 7))
        }.buttonStyle(.plain)
            .accessibilityAddTraits(selectedSection == section ? .isSelected : [])
    }

    private var general: some View {
        Group {
            card(L10n.text("打开轮盘", "Open the ring")) {
                HStack {
                    Text(L10n.text("切换应用", "App switcher"))
                    Spacer()
                    ShortcutRecorder(shortcut: $preferences.options.shortcut).frame(width: 145, height: 30)
                        .help(L10n.text("点击录入快捷键。单键会占用该键的全局输入。", "Click to record a shortcut. A single key is reserved system-wide."))
                }
                if let error = preferences.shortcutError { warning(error) }
                HStack {
                    Text(L10n.text("快捷操作", "App actions"))
                    Spacer()
                    ShortcutRecorder(shortcut: $preferences.options.actionShortcut).frame(width: 145, height: 30)
                    if preferences.options.actionShortcut != nil {
                        Button { preferences.options.actionShortcut = nil } label: { Image(systemName: "xmark.circle.fill") }
                            .buttonStyle(.plain).foregroundStyle(.secondary)
                            .help(L10n.text("清除快捷键", "Clear shortcut"))
                            .accessibilityLabel(L10n.text("清除快捷操作快捷键", "Clear app actions shortcut"))
                    }
                }
                if preferences.options.invocationConflict {
                    warning(L10n.text("两个轮盘不能使用相同快捷键。", "The two rings need different shortcuts."))
                } else if let error = preferences.actionShortcutError { warning(error) }
                Divider()
                Toggle(L10n.text("登录时启动", "Launch at login"), isOn: $loginEnabled).onChange(of: loginEnabled) { _, value in
                    do {
                        if value { try SMAppService.mainApp.register() } else { try SMAppService.mainApp.unregister() }
                        loginError = nil
                    } catch { loginError = L10n.text("无法更改登录项：\(error.localizedDescription)", "Could not change the login item: \(error.localizedDescription)") }
                    loginEnabled = SMAppService.mainApp.status == .enabled
                }
                if let loginError { warning(loginError) }
            }
            card(L10n.text("如何切换", "Choose how to switch")) {
                Picker(L10n.text("切换方式", "Selection mode"), selection: $preferences.options.holdToSelect) {
                    Text(L10n.text("点击切换", "Click to switch")).tag(false)
                    Text(L10n.text("松手切换", "Release to switch")).tag(true)
                }.pickerStyle(.segmented).labelsHidden()
                hint(preferences.options.holdToSelect
                    ? L10n.text("按住快捷键 → 指向目标 → 松手切换。移出轮盘也可选择。", "Hold the shortcut → point at a target → release. You can move beyond the ring.")
                    : L10n.text("按快捷键打开轮盘，点击应用、窗口或标签页切换。", "Open the ring, then click an app, window or tab."))
                HStack {
                    Text("Esc").fontWeight(.medium)
                    Text(L10n.text("取消选择", "Cancel selection")).foregroundStyle(.secondary)
                }.font(.caption)
            }
            card(L10n.text("触控板", "Trackpad")) {
                Picker(L10n.text("轻点打开轮盘", "Tap to open"), selection: $preferences.options.trackpadTap) {
                    ForEach(TrackpadTap.allCases, id: \.self) { Text($0.label).tag($0) }
                }
                if preferences.options.trackpadTap != .disabled {
                    hint(L10n.text("轻点后抬手，再移动鼠标选择。", "Tap, lift your fingers, then move the pointer."))
                }
                if preferences.options.trackpadTap == .threeFingers {
                    DisclosureGroup(L10n.text("与系统查词冲突？", "Look Up opens too?")) {
                        hint(L10n.text("系统设置 → 触控板 → 光标与点按：将“查找与数据检测器”改为单指用力点按或关闭。", "In System Settings → Trackpad → Point & Click, set Look up & data detectors to Force Click with One Finger or Off."))
                    }.font(.caption)
                }
                Toggle(L10n.text("三指捏合最小化窗口", "Three-finger pinch to minimize"), isOn: $preferences.options.threeFingerPinch)
                    .help(L10n.text("向内捏合后抬手；在 LumaRing 中关闭设置窗口。需要辅助功能权限。", "Pinch inward and lift. In LumaRing, this closes Settings. Requires Accessibility access."))
                if let message = trackpad.message {
                    HStack(alignment: .top) {
                        warning(message)
                        Spacer()
                        Button(L10n.text("重试", "Retry")) { trackpad.retry() }
                    }
                }
            }
        }
    }

    private var appearance: some View {
        Group {
            card(L10n.text("显示", "Display")) {
                Picker(L10n.text("语言", "Language"), selection: $preferences.language) {
                    ForEach(AppLanguage.allCases, id: \.self) { Text($0.title).tag($0) }
                }
                Picker(L10n.text("主题", "Theme"), selection: $preferences.options.theme) {
                    ForEach(AppTheme.allCases, id: \.self) { Text($0.title).tag($0) }
                }
                Picker(L10n.text("材质", "Material"), selection: $preferences.options.ringMaterial) {
                    ForEach(RingMaterialStyle.allCases, id: \.self) { Text($0.title).tag($0).disabled(!$0.isAvailable) }
                }
            }
            card(L10n.text("轮盘", "Ring")) {
                HStack {
                    Text(L10n.text("直径", "Diameter")).frame(width: 72, alignment: .leading)
                    Slider(value: $preferences.options.ringSize, in: 400...560, step: 20)
                    Text("\(Int(preferences.options.ringSize * 236 / 480)) pt").monospacedDigit().frame(width: 58, alignment: .trailing)
                }
                Stepper(value: $preferences.options.centerTitleSize, in: Options.centerTitleSizeRange) {
                    valueLabel(L10n.text("中央文字", "Center text"), "\(preferences.options.centerTitleSize) pt")
                }
                Divider()
                Stepper(value: $preferences.options.appPageSize, in: 4...24) {
                    valueLabel(L10n.text("每页应用", "Apps per page"), "\(preferences.options.appPageSize)")
                }
                Stepper(value: $preferences.options.windowPageSize, in: RingGeometry.windowPageSizeRange) {
                    valueLabel(L10n.text("每页窗口 / 标签页", "Windows / tabs per page"), "\(preferences.options.windowPageSize)")
                }
            }
            card(L10n.text("窗口预览", "Window previews")) {
                Toggle(L10n.text("悬停时显示预览", "Show previews on hover"), isOn: $preferences.options.previews)
                HStack {
                    Text(L10n.text("大小", "Size")).frame(width: 72, alignment: .leading)
                    Slider(value: $preferences.options.previewWidth, in: 400...960, step: 40)
                    Text("\(Int(preferences.options.previewWidth)) pt").monospacedDigit().frame(width: 58, alignment: .trailing)
                }.disabled(!preferences.options.previews)
                    .help(L10n.text("预览会自动缩小以适应屏幕。最小化窗口不提供图片预览。", "Previews shrink to fit the screen. Minimized windows have no image preview."))
                if preferences.options.previews && !preferences.screenCaptureGranted {
                    Button(L10n.text("设置屏幕录制权限…", "Set up Screen Recording access…")) { selectedSection = .permissions }
                        .font(.caption)
                }
            }
        }
    }

    private var permissions: some View {
        Group {
            card(L10n.text("辅助功能", "Accessibility")) {
                hint(L10n.text("用于切换窗口和使用捏合手势。", "Switch windows and use the pinch gesture."))
                HStack {
                    permissionStatus(preferences.accessibilityGranted)
                    Spacer()
                    Button(preferences.accessibilityGranted ? L10n.text("系统设置…", "System Settings…") : L10n.text("授权…", "Grant access…")) {
                        preferences.requestAccessibility()
                    }
                }
                if !preferences.accessibilityGranted {
                    hint(L10n.text("在系统设置中开启 LumaRing，然后返回这里。", "Enable LumaRing in System Settings, then return here."))
                }
            }
            card(L10n.text("屏幕录制", "Screen Recording")) {
                hint(L10n.text("仅用于窗口图片预览。", "Used for window image previews."))
                HStack {
                    permissionStatus(preferences.screenCaptureGranted)
                    Spacer()
                    Button(preferences.checkingCapture ? L10n.text("检测中…", "Checking…") : L10n.text("检测权限", "Check access")) { preferences.requestCapture() }
                        .disabled(preferences.checkingCapture)
                    Button(L10n.text("系统设置…", "System Settings…")) { preferences.openPrivacy("Privacy_ScreenCapture") }
                }
                if let message = preferences.captureMessage {
                    Text(message).font(.caption).foregroundStyle(.secondary).textSelection(.enabled)
                }
            }
            DisclosureGroup(L10n.text("已授权，仍无法使用？", "Access enabled but not working?")) {
                hint(L10n.text("在系统设置中移除旧的 LumaRing，重新添加 Applications 中的当前版本，再退出并重开应用。", "Remove the old LumaRing entry in System Settings, add the current app from Applications, then quit and reopen it."))
                    .padding(.top, 6)
            }.font(.system(size: 12))
        }
    }

    private func permissionStatus(_ granted: Bool) -> some View {
        Label(granted ? L10n.text("已授权", "Allowed") : L10n.text("未授权", "Not allowed"),
              systemImage: granted ? "checkmark.circle.fill" : "lock.circle")
            .foregroundStyle(granted ? Color.green : Color.orange)
    }

    private var about: some View {
        Group {
            card("LumaRing") {
                HStack {
                    Text("v\(UpdateService.version)").monospacedDigit()
                    Spacer()
                    Button(L10n.text("检查更新…", "Check for updates…")) { updates.checkForUpdates() }.disabled(!updates.canCheck)
                }
                Divider()
                Toggle(L10n.text("自动检查更新", "Check for updates automatically"), isOn: Binding(get: { updates.automaticChecks }, set: { updates.setAutomaticChecks($0) }))
                    .disabled(updates.configurationMessage != nil)
                hint(L10n.text("每天检查，由你确认安装。", "Checks daily. You choose when to install."))
                if let date = updates.lastChecked {
                    hint(L10n.text("上次检查：\(date.formatted(.dateTime.month().day().hour().minute().locale(preferences.language.locale)))", "Last checked: \(date.formatted(.dateTime.month().day().hour().minute().locale(preferences.language.locale)))"))
                }
                if let message = updates.configurationMessage { warning(message) }
            }
            logSettings
        }
    }

    private var logSettings: some View {
        card(L10n.text("诊断", "Diagnostics")) {
            DisclosureGroup(L10n.text("本地日志", "Local logs")) {
                VStack(alignment: .leading, spacing: 12) {
                    Toggle(L10n.text("记录运行日志", "Record application logs"), isOn: $preferences.options.loggingEnabled)
                    hint(L10n.text("仅保存在本机，最多 10 MB；不记录窗口标题、网址或文档内容。", "Stored on this Mac, up to 10 MB. No window titles, URLs or document contents."))
                    HStack {
                        Text(ByteCountFormatter.string(fromByteCount: Int64(logStatus.bytes), countStyle: .file))
                            .font(.caption).foregroundStyle(.secondary)
                        Spacer()
                        Button(L10n.text("打开文件夹", "Open folder")) {
                            logBusy = true
                            Task { @MainActor in
                                if let folder = await AppLog.shared.folder() { NSWorkspace.shared.open(folder) }
                                logStatus = await AppLog.shared.status()
                                logBusy = false
                            }
                        }
                        Button(L10n.text("清理", "Clear")) {
                            logBusy = true
                            Task { @MainActor in
                                _ = await AppLog.shared.clear()
                                logStatus = await AppLog.shared.status()
                                logBusy = false
                            }
                        }.accessibilityLabel(L10n.text("清理日志", "Clear logs"))
                    }.disabled(logBusy)
                    if logStatus.writeFailed {
                        warning(L10n.text("无法访问日志，请检查文件夹权限或磁盘空间。", "Cannot access logs. Check folder permissions or disk space."))
                    }
                }.padding(.top, 12)
            }
        }
        .task { logStatus = await AppLog.shared.status() }
        .onReceive(NotificationCenter.default.publisher(for: NSApplication.didBecomeActiveNotification)) { _ in
            Task { @MainActor in logStatus = await AppLog.shared.status() }
        }
    }

    private var launcherSettings: some View {
        card(L10n.text("常用应用", "Favorites")) {
            hint(L10n.text("在轮盘中按住 Option 显示，未运行的应用也能打开。", "Hold Option in the ring to show favorites, including apps that aren’t running."))
                .help(L10n.text("全局轮盘未展开二级轮盘时可用；也可双击中心展开或收起。", "Available when the app ring has no secondary arc open. You can also double-click its center to toggle favorites."))
            ForEach(preferences.options.launcherApps) { app in
                HStack {
                    Image(nsImage: NSWorkspace.shared.icon(forFile: app.path)).resizable().frame(width: 24, height: 24)
                    Text(app.name)
                    Spacer()
                    Button(L10n.text("移除", "Remove")) { preferences.options.launcherApps.removeAll { $0.id == app.id } }
                }
            }
            Button(L10n.text("添加应用…", "Add apps…")) {
                let panel = NSOpenPanel()
                panel.title = L10n.text("添加常用应用", "Add favorites")
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
        card(L10n.text("轮盘中的应用", "Apps in the ring")) {
            Picker(L10n.text("排列顺序", "Sort by"), selection: $preferences.options.sortByName) {
                Text(L10n.text("应用名称", "Name")).tag(true)
                Text(L10n.text("最近使用", "Recent use")).tag(false)
            }
            Toggle(L10n.text("包含最小化窗口", "Include minimized windows"), isOn: $preferences.options.includeMinimized)
            Divider()
            hint(L10n.text("取消勾选即可隐藏应用。", "Uncheck an app to hide it."))
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
                            }.labelsHidden().pickerStyle(.segmented).frame(width: 140)
                        }
                    }
                    if preferences.options.contentMode(for: identifier) == .tabs {
                        HStack(alignment: .top) {
                            if browserTabs.connected.contains(identifier) {
                                Label(L10n.text("已连接", "Connected"), systemImage: "checkmark.circle.fill")
                                    .font(.caption).foregroundStyle(.green)
                            } else {
                                warning(browserTabs.messages[identifier] ?? L10n.text("连接浏览器以切换标签页。", "Connect to switch tabs."))
                                Spacer()
                                Button(browserTabs.connecting.contains(identifier) ? L10n.text("连接中…", "Connecting…") : L10n.text("连接", "Connect")) { browserTabs.connect(app) }
                                    .disabled(browserTabs.connecting.contains(identifier))
                            }
                        }.padding(.leading, 22)
                    }
                }
            }
            HStack {
                Button(L10n.text("刷新", "Refresh")) { refresh() }
                Spacer()
                Button(L10n.text("显示全部", "Show all")) { preferences.options.excludedBundleIDs = [] }
            }
        }
    }

    private var guide: some View {
        Group {
            card(L10n.text("开始使用", "Start here")) {
                guideRow(preferences.options.shortcut.display, L10n.text("打开轮盘", "Open the ring"))
                guideRow(L10n.text("移动鼠标", "Move the pointer"), L10n.text("选择应用或窗口", "Choose an app or window"))
                guideRow(preferences.options.holdToSelect ? L10n.text("松开快捷键", "Release the shortcut") : L10n.text("点击目标", "Click the target"), L10n.text("切换过去", "Switch to it"))
                guideRow("Esc", L10n.text("取消选择", "Cancel"))
                if preferences.options.holdToSelect {
                    hint(L10n.text("选区向外延伸；二级轮盘内选窗口或标签页，越过侧边界选其他应用。", "Selection extends outward. Stay within the secondary arc to choose a window or tab; cross its sides to choose another app."))
                }
            }
            card(L10n.text("键盘选择", "Keyboard navigation")) {
                guideRow("Tab / Shift + Tab", L10n.text("下一个 / 上一个", "Next / previous"))
                guideRow("` / ~", L10n.text("进入 / 返回二级轮盘", "Enter / leave the secondary ring"))
                guideRow(L10n.text("回车", "Return"), L10n.text("确认选择", "Confirm"))
            }
            card(L10n.text("更多操作", "More controls")) {
                DisclosureGroup(L10n.text("手势与常用应用", "Gestures and favorites")) {
                    VStack(spacing: 12) {
                        guideRow(L10n.text("轻点后抬手", "Tap and lift"), L10n.text("打开 / 关闭轮盘", "Open / dismiss the ring"))
                        guideRow(L10n.text("按住 Option", "Hold Option"), L10n.text("显示常用应用", "Show favorites"))
                        guideRow(L10n.text("双击中心", "Double-click the center"), L10n.text("展开 / 收起常用应用", "Toggle favorites"))
                        hint(L10n.text("常用应用在无二级轮盘时显示。", "Favorites appear when no secondary arc is open."))
                        guideRow(L10n.text("双击左 Option", "Double-tap left Option"), L10n.text("应用 / 快捷操作", "Apps / app actions"))
                        guideRow(L10n.text("三指向内捏合后抬手", "Pinch inward, then lift"), L10n.text("最小化窗口", "Minimize the window"))
                        guideRow(L10n.text("滚动", "Scroll"), L10n.text("翻页", "Change pages"))
                    }.padding(.top, 12)
                }
                Divider()
                DisclosureGroup(L10n.text("管理窗口和应用", "Manage windows and apps")) {
                    VStack(spacing: 12) {
                        guideRow(L10n.text("点击 ×", "Click ×"), L10n.text("关闭窗口或标签页", "Close a window or tab"))
                        guideRow(L10n.text("拖出应用图标", "Drag an app icon out"), L10n.text("退出应用", "Quit the app"))
                        guideRow(L10n.text("右键应用", "Right-click an app"), L10n.text("新建窗口、切换标签页模式", "New window, tab mode"))
                        guideRow(L10n.text("右键窗口 → 修改", "Right-click a window → Edit"), L10n.text("修改名称和颜色", "Rename or recolor"))
                    }.padding(.top, 12)
                }
            }
        }
    }

    private func guideRow(_ action: String, _ result: String) -> some View {
        HStack(alignment: .top, spacing: 16) {
            Text(action).fontWeight(.medium).frame(maxWidth: .infinity, alignment: .leading)
            Text(result).foregroundStyle(.secondary).frame(maxWidth: .infinity, alignment: .trailing)
                .multilineTextAlignment(.trailing)
        }.fixedSize(horizontal: false, vertical: true)
    }

    private func valueLabel(_ label: String, _ value: String) -> some View {
        HStack { Text(label); Spacer(); Text(value).monospacedDigit().foregroundStyle(.secondary) }
    }

    private func hint(_ text: String) -> some View {
        Text(text).font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
    }

    private func warning(_ text: String) -> some View {
        Text(text).font(.caption).foregroundStyle(.orange).fixedSize(horizontal: false, vertical: true)
    }

    private func refresh() {
        preferences.refreshPermissions()
        loginEnabled = SMAppService.mainApp.status == .enabled
        apps = NSWorkspace.shared.runningApplications.filter { $0.activationPolicy == .regular && $0.processIdentifier != getpid() }
            .sorted { ($0.localizedName ?? "") < ($1.localizedName ?? "") }
        browserTabs.refreshAuthorization(apps)
    }

    private func card<Content: View>(_ title: String, @ViewBuilder content: () -> Content) -> some View {
        VStack(alignment: .leading, spacing: 9) {
            Text(title).font(.system(size: 12, weight: .medium)).foregroundStyle(.secondary).padding(.leading, 2)
            VStack(alignment: .leading, spacing: 13) {
                content().font(.system(size: 13))
            }.padding(16).frame(maxWidth: .infinity, alignment: .leading)
                .background(Color(nsColor: .controlBackgroundColor), in: RoundedRectangle(cornerRadius: 10))
                .overlay(RoundedRectangle(cornerRadius: 10).stroke(Color.primary.opacity(0.06)))
        }
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
