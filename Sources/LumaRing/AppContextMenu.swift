import AppKit

@MainActor final class AppContextMenu {
    private final class Action: NSObject {
        let run: () -> Void
        init(_ run: @escaping () -> Void) { self.run = run }
        @objc func invoke(_ sender: NSMenuItem) { run() }
    }

    private static func item(_ title: String, _ run: @escaping () -> Void) -> NSMenuItem {
        let action = Action(run)
        let item = NSMenuItem(title: title, action: #selector(Action.invoke(_:)), keyEquivalent: "")
        item.target = action; item.representedObject = action
        return item
    }

    static func make(window: WindowRecord, close: @escaping (WindowRecord) -> Void,
                     edit: @escaping (WindowRecord) -> Void) -> NSMenu {
        let menu = NSMenu()
        menu.autoenablesItems = false
        menu.addItem(item(L10n.text("关闭", "Close")) { close(window) })
        menu.addItem(item(L10n.text("修改…", "Edit…")) { edit(window) })
        return menu
    }

    static func make(app: AppRecord, mode: AppContentMode,
                     discover: (@escaping (ApplicationWindowCreator.Command?) -> Void) -> Void,
                     newWindow: @escaping (ApplicationWindowCreator.Command) -> Void,
                     changeMode: @escaping (AppContentMode) -> Void,
                     quit: @escaping () -> Void) -> NSMenu {
        let menu = NSMenu()
        menu.autoenablesItems = false
        var command: ApplicationWindowCreator.Command?
        let create = item(L10n.text("新建窗口", "New Window")) { if let command { newWindow(command) } }
        create.isEnabled = false
        create.isHidden = true
        menu.addItem(create)
        let supportsModes = BrowserAdapters.supports(app.bundleID)
        if supportsModes {
            let parent = NSMenuItem(title: L10n.text("二级轮盘显示", "Secondary Ring Shows"), action: nil, keyEquivalent: "")
            let submenu = NSMenu(); submenu.autoenablesItems = false
            for value in [AppContentMode.windows, .tabs] {
                let choice = item(value.title) { changeMode(value) }
                choice.state = value == mode ? .on : .off
                submenu.addItem(choice)
            }
            parent.submenu = submenu; menu.addItem(parent)
        }
        let separator = NSMenuItem.separator()
        separator.isHidden = !supportsModes
        menu.addItem(separator)
        menu.addItem(item(L10n.text("退出应用", "Quit App"), quit))
        discover { [weak create, weak separator] found in
            command = found
            create?.isEnabled = found != nil
            create?.isHidden = found == nil
            separator?.isHidden = found == nil && !supportsModes
        }
        return menu
    }
}
