import AppKit
import ApplicationServices
import LumaRingCore

struct WindowRecord: Identifiable {
    let id: String
    let pid: pid_t
    let title: String
    let minimized: Bool
    let fullscreen: Bool
    let frame: CGRect
    let element: AXUIElement
    var tab: BrowserTab? = nil
    var customName: String? = nil
    var customColor: SectorColor? = nil
    var displayTitle: String { customName ?? title }
}

enum WindowResult {
    case ready([WindowRecord], limited: Bool = false)
    case permissionRequired
    case unavailable(String)
}

/// A single worker keeps slow third-party accessibility servers off the UI thread.
/// Each instance handles one app query at a time. Every IPC operation has a bounded timeout.
final class WindowService {
    private let queue = DispatchQueue(label: "local.lumaring.accessibility", qos: .userInitiated)
    private var work: CancellationFlag?
    private var cache: [pid_t: (Date, WindowResult)] = [:] // main-thread confined

    func load(pid: pid_t, completion: @escaping (WindowResult) -> Void) {
        dispatchPrecondition(condition: .onQueue(.main))
        work?.cancel()
        guard AXIsProcessTrusted() else { completion(.permissionRequired); return }
        if let entry = cache[pid], Date().timeIntervalSince(entry.0) < 1.0 {
            completion(entry.1); return
        }
        let token = CancellationFlag()
        work = token
        queue.async { [weak self, token] in
            guard !token.isCancelled else { return }
            let result = Self.read(pid: pid, cancelled: { token.isCancelled })
            guard !token.isCancelled else { return }
            DispatchQueue.main.async { [weak self] in
                guard let self, !token.isCancelled else { return }
                if case .ready = result {
                    if self.cache.count >= 24 { self.cache.removeAll(keepingCapacity: true) }
                    self.cache[pid] = (Date(), result)
                }
                completion(result)
            }
        }
    }

    func cancelAndClear() {
        work?.cancel(); work = nil
        cache.removeAll(keepingCapacity: false)
    }

    private static func read(pid: pid_t, cancelled: () -> Bool) -> WindowResult {
        let app = AXUIElementCreateApplication(pid)
        AXUIElementSetMessagingTimeout(app, 0.18)
        var raw: CFTypeRef?
        let error = AXUIElementCopyAttributeValue(app, kAXWindowsAttribute as CFString, &raw)
        guard error == .success else {
            if error == .apiDisabled { return .permissionRequired }
            return .unavailable(error == .cannotComplete ? L10n.text("应用暂时未响应，请稍后重试", "The app is not responding. Try again shortly.") : L10n.text("此应用暂未提供可切换窗口", "This app has no available windows"))
        }
        guard let elements = raw as? [AXUIElement] else { return .ready([]) }
        var result: [WindowRecord] = []
        var limited = elements.count > 128
        let attributes = [kAXRoleAttribute, kAXSubroleAttribute, kAXTitleAttribute, kAXMinimizedAttribute,
                          "AXFullScreen", kAXPositionAttribute, kAXSizeAttribute] as CFArray
        // The overall query has a wall-time budget as well as per-message timeouts.
        let deadline = ProcessInfo.processInfo.systemUptime + 1.2
        for element in elements.prefix(128) {
            if cancelled() { break }
            if ProcessInfo.processInfo.systemUptime > deadline { limited = true; break }
            AXUIElementSetMessagingTimeout(element, 0.12)
            var rawValues: CFArray?
            guard AXUIElementCopyMultipleAttributeValues(element, attributes, [], &rawValues) == .success,
                  let values = rawValues as? [Any], values.count == 7 else { limited = true; continue }
            let role = values[0] as? String ?? ""
            guard role == kAXWindowRole else { continue }
            let subrole = values[1] as? String ?? ""
            guard subrole != kAXFloatingWindowSubrole, subrole != kAXSystemDialogSubrole else { continue }
            let title = values[2] as? String ?? ""
            let minimized = (values[3] as? NSNumber)?.boolValue ?? false
            let fullscreen = (values[4] as? NSNumber)?.boolValue ?? false
            var position = CGPoint.zero
            var size = CGSize.zero
            if let positionValue = axValue(values[5], type: .cgPoint) { AXValueGetValue(positionValue, .cgPoint, &position) }
            if let sizeValue = axValue(values[6], type: .cgSize) { AXValueGetValue(sizeValue, .cgSize, &size) }
            guard size.width > 1, size.height > 1 else { continue }
            result.append(WindowRecord(id: "\(pid):\(CFHash(element))", pid: pid,
                                       title: title.isEmpty ? L10n.text("未命名窗口", "Untitled window") : title,
                                       minimized: minimized, fullscreen: fullscreen,
                                       frame: CGRect(origin: position, size: size), element: element))
        }
        return .ready(result, limited: limited)
    }

    private static func axValue(_ raw: Any, type: AXValueType) -> AXValue? {
        let cf = raw as CFTypeRef
        guard CFGetTypeID(cf) == AXValueGetTypeID() else { return nil }
        let value = cf as! AXValue
        return AXValueGetType(value) == type ? value : nil
    }

    // Closing uses the exact AX window and its own close button. No keyboard
    // shortcut, app-wide fallback, or automatic response to a save dialog.
    static func requestClose(_ window: WindowRecord,
                             read: (AXUIElement, String) -> CFTypeRef? = { element, attribute in
                                 var value: CFTypeRef?
                                 return AXUIElementCopyAttributeValue(element, attribute as CFString, &value) == .success ? value : nil
                             },
                             press: (AXUIElement) -> Bool = { AXUIElementPerformAction($0, kAXPressAction as CFString) == .success }) -> Bool {
        guard window.tab == nil else { return false }
        var pid: pid_t = 0
        guard AXUIElementGetPid(window.element, &pid) == .success, pid == window.pid else { return false }
        AXUIElementSetMessagingTimeout(window.element, 0.25)
        guard read(window.element, kAXRoleAttribute) as? String == kAXWindowRole,
              let raw = read(window.element, kAXCloseButtonAttribute), CFGetTypeID(raw) == AXUIElementGetTypeID() else { return false }
        let button = raw as! AXUIElement
        AXUIElementSetMessagingTimeout(button, 0.25)
        guard AXUIElementGetPid(button, &pid) == .success, pid == window.pid,
              read(button, kAXRoleAttribute) as? String == kAXButtonRole,
              (read(button, kAXEnabledAttribute) as? NSNumber)?.boolValue == true else { return false }
        return press(button)
    }

    @MainActor func close(_ window: WindowRecord, completion: @escaping (Bool) -> Void) {
        work?.cancel()
        cache.removeValue(forKey: window.pid)
        guard AXIsProcessTrusted() else { completion(false); return }
        // Close in the background. Do not activate, raise, reopen or unminimize
        // the target application/window; any save prompt belongs to that app.
        queue.async {
            let success = Self.requestClose(window)
            DispatchQueue.main.async { completion(success) }
        }
    }

    @MainActor func activate(_ window: WindowRecord, allowAppFallback: Bool = false, completion: @escaping (Bool) -> Void) {
        work?.cancel()
        // Reopen immediately, before potentially slow third-party accessibility messages.
        ApplicationActivator().activate(pid: window.pid) { activated in
            guard activated else { completion(false); return }
            self.queue.async {
                AXUIElementSetMessagingTimeout(window.element, 0.25)
                if window.minimized {
                    AXUIElementSetAttributeValue(window.element, kAXMinimizedAttribute as CFString, kCFBooleanFalse)
                }
                AXUIElementSetAttributeValue(window.element, kAXMainAttribute as CFString, kCFBooleanTrue)
                // Reopen can choose the old key window; select the requested window afterwards.
                let raised = AXUIElementPerformAction(window.element, kAXRaiseAction as CFString)
                DispatchQueue.main.async { completion(raised == .success || allowAppFallback) }
            }
        }
    }
}
