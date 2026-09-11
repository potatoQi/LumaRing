import AppKit
import Carbon
import LumaRingCore

struct ActionFocus: @unchecked Sendable {
    let pid: pid_t
    let launched: Date
    let window: AXUIElement
    let element: AXUIElement?
    var scope: String { element == nil ? "window" : "control" }
}

enum ActionFocusAccess {
    typealias Read = (AXUIElement, String) -> (value: CFTypeRef?, error: AXError)

    static func read(_ element: AXUIElement, _ attribute: String) -> (value: CFTypeRef?, error: AXError) {
        AXUIElementSetMessagingTimeout(element, 0.08)
        var value: CFTypeRef?
        let error = AXUIElementCopyAttributeValue(element, attribute as CFString, &value)
        return (error == .success ? value : nil, error)
    }

    static func element(_ raw: CFTypeRef?) -> AXUIElement? {
        guard let raw, CFGetTypeID(raw) == AXUIElementGetTypeID() else { return nil }
        return (raw as! AXUIElement)
    }
    static func capture(pid: pid_t, read: Read = ActionFocusAccess.read,
                        foreground: () -> pid_t? = FocusedWindowAccess.foregroundPID,
                        launched: (pid_t) -> Date? = { NSRunningApplication(processIdentifier: $0)?.launchDate },
                        report: (String) -> Void = { _ in }) -> ActionFocus? {
        func unavailable(_ reason: String) -> ActionFocus? { report(reason); return nil }
        guard foreground() == pid else { return unavailable("foreground_changed") }
        guard let date = launched(pid) else { return unavailable("process_unavailable") }
        guard !IsSecureEventInputEnabled() else { return unavailable("secure_input") }
        let app = AXUIElementCreateApplication(pid)
        guard let window = element(read(app, kAXFocusedWindowAttribute).value) else { return unavailable("window_unavailable") }
        guard read(window, kAXRoleAttribute).value as? String == kAXWindowRole else { return unavailable("invalid_window_role") }
        var owner: pid_t = 0
        guard AXUIElementGetPid(window, &owner) == .success, owner == pid else { return unavailable("owner_changed") }

        let control = read(app, kAXFocusedUIElementAttribute)
        let focused: AXUIElement?
        switch control.error {
        case .success:
            focused = element(control.value)
            if control.value != nil && focused == nil { return unavailable("invalid_control") }
        case .noValue, .attributeUnsupported:
            focused = nil
        default:
            // A timeout, permission failure or destroyed object is not evidence
            // that the app only supports window-level focus.
            return unavailable("control_read_failed")
        }
        if let focused {
            guard let role = read(focused, kAXRoleAttribute).value as? String, role != kAXApplicationRole else {
                return unavailable("invalid_control_role")
            }
            let subrole = read(focused, kAXSubroleAttribute)
            guard [.success, .noValue, .attributeUnsupported].contains(subrole.error) else { return unavailable("control_read_failed") }
            guard subrole.value as? String != kAXSecureTextFieldSubrole else { return unavailable("secure_control") }
            guard AXUIElementGetPid(focused, &owner) == .success, owner == pid else { return unavailable("owner_changed") }
        }
        guard foreground() == pid, launched(pid) == date else { return unavailable("process_changed") }
        return ActionFocus(pid: pid, launched: date, window: window, element: focused)
    }

    static func captureWithDiagnostics(pid: pid_t) -> ActionFocus? {
        guard AXIsProcessTrusted() else {
            AppLog.shared.record("focus_unavailable", category: .actions, level: .warning,
                                 fields: ["pid": String(pid), "reason": "accessibility_permission"])
            return nil
        }
        var errors: [String: String] = [:]
        return capture(pid: pid, read: { element, attribute in
            let result = read(element, attribute)
            if result.error != .success { errors[attribute] = String(result.error.rawValue) }
            return result
        }, report: { reason in
            // Attribute names/error codes only: never read or log input text.
            var fields = errors
            fields["pid"] = String(pid); fields["reason"] = reason
            AppLog.shared.record("focus_unavailable", category: .actions, level: .warning, fields: fields)
        })
    }
    static func matches(_ target: ActionFocus, read: Read = ActionFocusAccess.read,
                        foreground: () -> pid_t? = FocusedWindowAccess.foregroundPID,
                        launched: (pid_t) -> Date? = { NSRunningApplication(processIdentifier: $0)?.launchDate }) -> Bool {
        guard let current = capture(pid: target.pid, read: read, foreground: foreground, launched: launched) else { return false }
        guard current.launched == target.launched, CFEqual(current.window, target.window) else { return false }
        // The invocation fixes the verification scope. A captured control may
        // never silently downgrade to window-only verification at dispatch.
        guard let original = target.element else { return true }
        guard let currentElement = current.element else { return false }
        return CFEqual(currentElement, original)
    }

    static func events(_ shortcut: Shortcut) -> [CGEvent]? {
        guard AppAction.validShortcut(shortcut), let source = CGEventSource(stateID: .privateState) else { return nil }
        let keys: [(UInt32, CGKeyCode, CGEventFlags)] = [
            (UInt32(controlKey), 59, .maskControl), (UInt32(optionKey), 58, .maskAlternate),
            (UInt32(shiftKey), 56, .maskShift), (UInt32(cmdKey), 55, .maskCommand)
        ].filter { shortcut.modifiers & $0.0 != 0 }
        var flags: CGEventFlags = [], events: [CGEvent] = []
        func add(_ key: CGKeyCode, _ down: Bool) -> Bool {
            guard let event = CGEvent(keyboardEventSource: source, virtualKey: key, keyDown: down) else { return false }
            event.flags = flags; events.append(event); return true
        }
        for (_, key, flag) in keys { flags.insert(flag); guard add(key, true) else { return nil } }
        guard add(CGKeyCode(shortcut.keyCode), true), add(CGKeyCode(shortcut.keyCode), false) else { return nil }
        for (_, key, flag) in keys.reversed() { flags.remove(flag); guard add(key, false) else { return nil } }
        return events
    }
    static func modifiersReleased() -> Bool {
        let flags = CGEventSource.flagsState(.combinedSessionState)
        return flags.intersection([.maskCommand, .maskAlternate, .maskControl, .maskShift, .maskSecondaryFn]).isEmpty
    }
}

/// Captures and checks AX identity off the render thread. No activating apps,
/// restoring focus, reading text/selection, command strings or automatic retries.
@MainActor final class ActionExecutor {
    private let queue = DispatchQueue(label: "local.lumaring.actions", qos: .userInitiated)
    private var flag: CancellationFlag?
    private(set) var focus: ActionFocus?
    private let capture: (pid_t) -> ActionFocus?
    private let matches: (ActionFocus) -> Bool
    private let released: () -> Bool
    private let post: (CGEvent, pid_t) -> Void

    init(capture: @escaping (pid_t) -> ActionFocus? = ActionFocusAccess.captureWithDiagnostics,
         matches: @escaping (ActionFocus) -> Bool = { AXIsProcessTrusted() && ActionFocusAccess.matches($0) },
         released: @escaping () -> Bool = ActionFocusAccess.modifiersReleased,
         post: @escaping (CGEvent, pid_t) -> Void = { $0.postToPid($1) }) {
        self.capture = capture; self.matches = matches; self.released = released; self.post = post
    }
    func prepare(pid: pid_t, completion: @escaping (Bool) -> Void) {
        cancel()
        let token = CancellationFlag(); flag = token
        queue.async { [weak self, capture] in
            guard !token.isCancelled else { return }
            let focus = capture(pid)
            DispatchQueue.main.async {
                guard let self, !token.isCancelled else { return }
                self.focus = focus
                AppLog.shared.record("focus_captured", category: .actions, fields: ["pid": String(pid), "available": String(focus != nil), "scope": focus?.scope ?? "unavailable"])
                completion(focus != nil)
            }
        }
    }
    func cancel() { flag?.cancel(); flag = nil; focus = nil }

    func execute(_ action: AppAction, target: ActionFocus, invocation: Shortcut, completion: @escaping (Bool) -> Void) {
        cancel()
        guard action.configured, !action.conflicts(with: invocation), let shortcut = action.shortcut,
              let events = ActionFocusAccess.events(shortcut) else { completion(false); return }
        let token = CancellationFlag(); flag = token
        let deadline = ProcessInfo.processInfo.systemUptime + 0.8
        queue.async { [matches, released, post] in
            while !token.isCancelled && !released() && ProcessInfo.processInfo.systemUptime < deadline {
                Thread.sleep(forTimeInterval: 0.01)
            }
            guard !token.isCancelled else { return }
            let valid = released() && matches(target) && !token.isCancelled && released()
            if valid {
                // Complete the balanced key sequence once begun, including key-up
                // events, even if a callback cancels during dispatch.
                for event in events { post(event, target.pid) }
            }
            AppLog.shared.record(valid ? "shortcut_posted" : "focus_or_modifiers_changed", category: .actions,
                                 level: valid ? .info : .warning, fields: ["pid": String(target.pid), "scope": target.scope])
            DispatchQueue.main.async { if !token.isCancelled { completion(valid) } }
        }
    }
}
