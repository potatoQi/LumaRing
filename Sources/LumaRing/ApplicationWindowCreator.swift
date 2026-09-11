import AppKit

/// Discover the application's actual New Window command without sending keystrokes.
final class ApplicationWindowCreator {
    enum Strategy { case menu, browser }
    struct MenuItem {
        let element: AXUIElement
        let title: String
    }
    struct Command {
        let pid: pid_t
        let bundleID: String
        var strategy: Strategy = .menu
        var menuItem: MenuItem? = nil
    }
    typealias Read = (AXUIElement, String) -> CFTypeRef?
    private let queue = DispatchQueue(label: "local.lumaring.new-window", qos: .userInitiated,
                                      attributes: .concurrent, autoreleaseFrequency: .workItem)

    static func read(_ element: AXUIElement, _ name: String) -> CFTypeRef? {
        AXUIElementSetMessagingTimeout(element, 0.08)
        var value: CFTypeRef?
        return AXUIElementCopyAttributeValue(element, name as CFString, &value) == .success ? value : nil
    }

    private static let menuAttributes = [kAXChildrenAttribute, kAXRoleAttribute, kAXTitleAttribute,
        kAXEnabledAttribute, kAXMenuItemCmdCharAttribute, kAXMenuItemCmdModifiersAttribute]

    static func readMenuAttributes(_ element: AXUIElement) -> [String: Any]? {
        AXUIElementSetMessagingTimeout(element, 0.08)
        var raw: CFArray?
        let status = AXUIElementCopyMultipleAttributeValues(element, menuAttributes as CFArray, [], &raw)
        if status == .notImplemented || status == .attributeUnsupported { return nil }
        // A hung or destroyed node must not trigger another round of individual
        // requests. Only unsupported bulk access needs the compatibility path.
        guard status == .success, let values = raw as? [Any], values.count == menuAttributes.count else { return [:] }
        return Dictionary(uniqueKeysWithValues: zip(menuAttributes, values))
    }

    /// One IPC per visited node instead of separate children/role/title/enabled
    /// requests. Keep only the current node, for this search or validation.
    static func menuReader(batch: @escaping (AXUIElement) -> [String: Any]? = readMenuAttributes,
                           fallback: @escaping Read = read) -> Read {
        var previous: AXUIElement?
        var attributes: [String: Any]?
        return { element, key in
            if previous !== element {
                previous = element
                attributes = batch(element)
            }
            guard let attributes else { return fallback(element, key) }
            return attributes[key].map { $0 as CFTypeRef }
        }
    }

    static func isNewWindowTitle(_ title: String) -> Bool {
        let title = title.trimmingCharacters(in: .whitespacesAndNewlines)
            .replacingOccurrences(of: "…", with: "").trimmingCharacters(in: CharacterSet(charactersIn: "."))
            .lowercased()
        return ["new window", "new finder window", "新建窗口", "新建访达窗口", "新窗口",
                "新增視窗", "新增 finder 視窗", "新建視窗"].contains(title)
    }

    static func find(in root: AXUIElement, pid: pid_t, read: Read? = nil) -> AXUIElement? {
        let read = read ?? menuReader()
        let deadline = ProcessInfo.processInfo.systemUptime + 1.2
        // Search level by level so About/Recent Items submenus cannot consume the
        // entire budget before reaching File > New Window.
        var pending: [(AXUIElement, Int)] = [(root, 0)], index = 0
        while index < pending.count, index < 300, ProcessInfo.processInfo.systemUptime < deadline {
            let (node, depth) = pending[index]; index += 1
            guard depth <= 5 else { continue }
            var owner: pid_t = 0
            guard AXUIElementGetPid(node, &owner) == .success, owner == pid else { continue }
            let children = read(node, kAXChildrenAttribute) as? [AXUIElement] ?? []
            if read(node, kAXRoleAttribute) as? String == kAXMenuItemRole,
               isNewWindowTitle(read(node, kAXTitleAttribute) as? String ?? ""),
               (read(node, kAXEnabledAttribute) as? NSNumber)?.boolValue == true {
                if children.isEmpty { return node }
                for menu in children.prefix(64) {
                    guard ProcessInfo.processInfo.systemUptime < deadline else { return nil }
                    for item in (read(menu, kAXChildrenAttribute) as? [AXUIElement] ?? []).prefix(64) {
                        guard ProcessInfo.processInfo.systemUptime < deadline else { return nil }
                        var owner: pid_t = 0
                        guard AXUIElementGetPid(item, &owner) == .success, owner == pid,
                              (read(item, kAXMenuItemCmdCharAttribute) as? String)?.lowercased() == "n",
                              (read(item, kAXMenuItemCmdModifiersAttribute) as? NSNumber)?.intValue == 0,
                              (read(item, kAXEnabledAttribute) as? NSNumber)?.boolValue == true else { continue }
                        return item
                    }
                }
            }
            pending.append(contentsOf: children.prefix(min(64, max(0, 1024 - pending.count))).map { ($0, depth + 1) })
        }
        return nil
    }

    func discover(pid: pid_t, bundleID: String, completion: @escaping (Command?) -> Void) {
        if BrowserAdapters.supports(bundleID), let app = NSRunningApplication(processIdentifier: pid),
           !app.isTerminated, app.bundleIdentifier == bundleID {
            completion(Command(pid: pid, bundleID: bundleID, strategy: .browser))
            return
        }
        queue.async {
            var command: Command?
            if AXIsProcessTrusted(), let app = NSRunningApplication(processIdentifier: pid),
               !app.isTerminated, app.bundleIdentifier ?? "" == bundleID {
                let root = AXUIElementCreateApplication(pid)
                let read = Self.menuReader()
                if let value = Self.read(root, kAXMenuBarAttribute), CFGetTypeID(value) == AXUIElementGetTypeID(),
                   let item = Self.find(in: value as! AXUIElement, pid: pid, read: read),
                   let title = read(item, kAXTitleAttribute) as? String {
                    command = Command(pid: pid, bundleID: bundleID, menuItem: MenuItem(element: item, title: title))
                }
            }
            let result = command
            DispatchQueue.main.async { completion(result) }
        }
    }

    func perform(_ command: Command, completion: @escaping (Bool) -> Void) {
        let complete: (Bool) -> Void = { success in
            AppLog.shared.record("create_result", category: .windows, level: success ? .info : .warning,
                                 fields: ["pid": String(command.pid), "success": String(success)])
            completion(success)
        }
        queue.async {
            guard let app = NSRunningApplication(processIdentifier: command.pid), !app.isTerminated,
                  app.bundleIdentifier == command.bundleID else {
                DispatchQueue.main.async { complete(false) }; return
            }
            if command.strategy == .browser, BrowserAdapters.supports(command.bundleID),
               BrowserEvents.permission(pid: command.pid, ask: false) == noErr {
                // Do not retry an uncertain create response via another mechanism:
                // a timeout may mean the first request already created a window.
                let success = (try? BrowserEvents(pid: command.pid, budget: 2).newWindow()) != nil
                DispatchQueue.main.async {
                    if success { _ = app.activate(options: []) }
                    complete(success)
                }
                return
            }
            // Without browser Automation access, use the already-authorized AX
            // route. Activate only after the user's explicit New Window action,
            // once LumaRing's context menu has finished tracking.
            DispatchQueue.main.async {
                guard AXIsProcessTrusted(), app.activate(options: []) else { complete(false); return }
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.10) {
                    self.queue.async {
                        let success = Self.performMenu(command)
                        DispatchQueue.main.async { complete(success) }
                    }
                }
            }
        }
    }

    private static func performMenu(_ command: Command) -> Bool {
        guard let app = NSRunningApplication(processIdentifier: command.pid), !app.isTerminated,
              app.bundleIdentifier == command.bundleID else { return false }
        return pressMenu(command, locate: {
            let root = AXUIElementCreateApplication(command.pid)
            guard let value = read(root, kAXMenuBarAttribute), CFGetTypeID(value) == AXUIElementGetTypeID() else { return nil }
            return find(in: value as! AXUIElement, pid: command.pid)
        })
    }

    static func pressMenu(_ command: Command, read: Read? = nil, locate: () -> AXUIElement?,
                          press: (AXUIElement) -> Bool = {
                              AXUIElementSetMessagingTimeout($0, 0.25)
                              return AXUIElementPerformAction($0, kAXPressAction as CFString) == .success
                          }) -> Bool {
        let read = read ?? menuReader()
        if let saved = command.menuItem {
            var owner: pid_t = 0
            if AXUIElementGetPid(saved.element, &owner) == .success, owner == command.pid,
               read(saved.element, kAXRoleAttribute) as? String == kAXMenuItemRole,
               read(saved.element, kAXTitleAttribute) as? String == saved.title,
               (read(saved.element, kAXEnabledAttribute) as? NSNumber)?.boolValue == true {
                // No second traversal for a still-valid captured command. Never
                // retry a failed press: it may already have opened the window.
                return press(saved.element)
            }
        }
        guard let item = locate() else { return false }
        return press(item)
    }
}
