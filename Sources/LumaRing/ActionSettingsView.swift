import AppKit
import SwiftUI
import UniformTypeIdentifiers

struct ActionSettingsView: View {
    @Binding var profiles: [ActionProfile]
    let invocations: [Shortcut]
    @State private var selected: String?

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            HStack {
                Picker(L10n.text("应用", "App"), selection: $selected) {
                    Text(L10n.text("选择应用", "Choose an app")).tag(String?.none)
                    ForEach(profiles) { Text($0.app.name).tag(Optional($0.id)) }
                }
                Button(L10n.text("添加应用…", "Add App…")) { addApp() }.disabled(profiles.count >= 64)
            }
            if let index = profiles.firstIndex(where: { $0.id == selected }) {
                if profiles[index].actions.isEmpty {
                    Text(L10n.text("添加操作，设置名称与快捷键。", "Add an action, then set its name and shortcut."))
                        .foregroundStyle(.secondary)
                } else {
                    ActionProfileEditor(profile: $profiles[index], invocations: invocations)
                }
                HStack {
                    Button(L10n.text("添加操作", "Add Action")) { profiles[index].actions.append(AppAction()) }
                        .disabled(profiles[index].actions.count >= 48)
                    Spacer()
                    Button(L10n.text("移除应用", "Remove App")) {
                        profiles.removeAll { $0.id == selected }; selected = profiles.first?.id
                    }.help(L10n.text("删除此应用的全部快捷操作", "Remove all actions configured for this app"))
                }
            } else {
                Text(L10n.text("添加应用后，为操作命名并录入快捷键。", "Add an app, name each action and record its shortcut.")).foregroundStyle(.secondary)
            }
            Text(L10n.text("轮盘打开时，双击左 Option 切换模式。每个应用独立记忆。", "Double-tap left Option with the ring open to switch modes. Each app remembers its choice."))
                .font(.caption).foregroundStyle(.secondary)
        }.onAppear { if selected == nil { selected = profiles.first?.id } }
    }
    private func addApp() {
        let panel = NSOpenPanel()
        panel.allowedContentTypes = [.applicationBundle]
        panel.directoryURL = URL(fileURLWithPath: "/Applications")
        panel.canChooseDirectories = false
        panel.begin { result in
            guard result == .OK, let url = panel.url, let app = LauncherApp.read(url) else { return }
            if !profiles.contains(where: { $0.id == app.id }) { profiles.append(ActionProfile(app: app)) }
            selected = app.id
        }
    }
}

private struct ActionProfileEditor: View {
    @Binding var profile: ActionProfile
    let invocations: [Shortcut]
    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            ForEach($profile.actions) { $action in
                VStack(alignment: .leading, spacing: 4) {
                    HStack {
                        TextField(L10n.text("操作名称", "Action name"), text: $action.name).textFieldStyle(.roundedBorder)
                        ShortcutRecorder(shortcut: $action.shortcut).frame(width: 130, height: 28)
                        Button { profile.move(action.id, by: -1) } label: { Image(systemName: "arrow.up") }
                            .disabled(profile.actions.first?.id == action.id).help(L10n.text("上移", "Move up"))
                        Button { profile.move(action.id, by: 1) } label: { Image(systemName: "arrow.down") }
                            .disabled(profile.actions.last?.id == action.id).help(L10n.text("下移", "Move down"))
                        Button { profile.actions.removeAll { $0.id == action.id } } label: { Image(systemName: "minus.circle") }
                            .help(L10n.text("删除操作", "Remove action"))
                    }
                    if invocations.contains(where: { action.conflicts(with: $0) }) {
                        Text(L10n.text("与轮盘呼出快捷键冲突，请更换。", "Conflicts with the ring shortcut. Choose another combination."))
                            .font(.caption).foregroundStyle(.orange)
                    }
                }
            }
        }
    }
}
