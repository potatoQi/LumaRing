import AppKit
import ApplicationServices
import LumaRingCore

/// Owns one gesture target. AX work is serialized off the main thread and every
/// queued operation carries a cancellation flag, including after finger release.
@MainActor final class PinchMinimizer {
    // The main actor retains this immutable handle; all AX access stays on queue.
    private struct Target: @unchecked Sendable { let element: AXUIElement }
    private let queue = DispatchQueue(label: "local.lumaring.pinch-minimize", qos: .userInitiated)
    private let foreground: () -> pid_t?
    private let allowed: () -> Bool
    private let capture: (pid_t, CancellationFlag) -> AXUIElement?
    private let minimize: (pid_t, AXUIElement, CancellationFlag) -> Void
    private var pending: CancellationFlag?
    private var pid: pid_t?
    private var target: Target?
    private var released = false
    private var timeout: DispatchWorkItem?
    private var activationObserver: NSObjectProtocol?

    init(foreground: @escaping () -> pid_t? = { NSWorkspace.shared.frontmostApplication?.processIdentifier },
         allowed: @escaping () -> Bool,
         capture: @escaping (pid_t, CancellationFlag) -> AXUIElement? = FocusedWindowAccess.capture,
         minimize: @escaping (pid_t, AXUIElement, CancellationFlag) -> Void = { pid, window, flag in
             _ = FocusedWindowAccess.minimize(pid: pid, window: window, cancelled: flag)
         }, observeActivation: Bool = true) {
        self.foreground = foreground; self.allowed = allowed
        self.capture = capture; self.minimize = minimize
        if observeActivation {
            activationObserver = NSWorkspace.shared.notificationCenter.addObserver(
                forName: NSWorkspace.didActivateApplicationNotification, object: nil, queue: .main
            ) { [weak self] _ in MainActor.assumeIsolated { self?.cancel() } }
        }
    }

    deinit {
        pending?.cancel(); timeout?.cancel()
        if let activationObserver { NSWorkspace.shared.notificationCenter.removeObserver(activationObserver) }
    }

    func begin() {
        cancel()
        guard allowed(), let pid = foreground(), pid > 0,
              pid != ProcessInfo.processInfo.processIdentifier else { return }
        let flag = CancellationFlag()
        pending = flag; self.pid = pid
        let expiry = DispatchWorkItem { [weak self] in
            guard let self, self.pending === flag else { return }
            self.cancel()
        }
        timeout = expiry
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.9, execute: expiry)
        let capture = self.capture
        queue.async { [weak self] in
            guard !flag.isCancelled else { return }
            let window = capture(pid, flag).map { Target(element: $0) }
            DispatchQueue.main.async { [weak self] in
                guard let self, self.pending === flag, !flag.isCancelled else { return }
                guard let window, self.foreground() == pid, self.allowed() else { self.cancel(); return }
                self.target = window
                if self.released { self.commit() }
            }
        }
    }

    func complete() { released = true; commit() }

    func cancel() {
        pending?.cancel(); pending = nil
        timeout?.cancel(); timeout = nil
        target = nil; pid = nil; released = false
    }

    private func commit() {
        guard let flag = pending, !flag.isCancelled, let pid,
              allowed(), foreground() == pid else { cancel(); return }
        // If AX capture is still pending, keep this exact gesture and wait for it.
        guard let target else { return }
        self.target = nil
        let minimize = self.minimize
        queue.async { [weak self] in
            if !flag.isCancelled { minimize(pid, target.element, flag) }
            DispatchQueue.main.async { [weak self] in
                guard let self, self.pending === flag else { return }
                self.cancel()
            }
        }
    }
}

enum FocusedWindowAccess {
    typealias Read = (AXUIElement, String) -> CFTypeRef?
    static func read(_ element: AXUIElement, _ attribute: String) -> CFTypeRef? {
        AXUIElementSetMessagingTimeout(element, 0.08)
        var value: CFTypeRef?
        return AXUIElementCopyAttributeValue(element, attribute as CFString, &value) == .success ? value : nil
    }

    private static func element(_ value: CFTypeRef?) -> AXUIElement? {
        guard let value, CFGetTypeID(value) == AXUIElementGetTypeID() else { return nil }
        return (value as! AXUIElement)
    }

    static func foregroundPID() -> pid_t? { NSWorkspace.shared.frontmostApplication?.processIdentifier }

    static func focusedWindow(pid: pid_t, read: Read = read, foreground: () -> pid_t? = foregroundPID) -> AXUIElement? {
        // The system-wide AXFocusedApplication query can fail even though the
        // foreground app exposes a fully functional focused window. Resolve the
        // known PID directly and recheck foreground ownership across the read.
        guard foreground() == pid else { return nil }
        let app = AXUIElementCreateApplication(pid)
        var owner: pid_t = 0
        guard let window = element(read(app, kAXFocusedWindowAttribute)),
              AXUIElementGetPid(window, &owner) == .success, owner == pid,
              foreground() == pid else { return nil }
        return window
    }

    static func capture(pid: pid_t, cancelled: CancellationFlag) -> AXUIElement? {
        guard !cancelled.isCancelled, AXIsProcessTrusted() else { return nil }
        return focusedWindow(pid: pid)
    }

    @discardableResult static func minimize(pid: pid_t, window: AXUIElement, cancelled: CancellationFlag,
        read: Read = read,
        foreground: () -> pid_t? = foregroundPID,
        settable: (AXUIElement) -> Bool = { window in
            var result: DarwinBoolean = false
            return AXUIElementIsAttributeSettable(window, kAXMinimizedAttribute as CFString, &result) == .success && result.boolValue
        }, write: (AXUIElement) -> Bool = {
            AXUIElementSetAttributeValue($0, kAXMinimizedAttribute as CFString, kCFBooleanTrue) == .success
        }) -> Bool {
        guard !cancelled.isCancelled, foreground() == pid,
              read(window, kAXRoleAttribute) as? String == kAXWindowRole,
              read(window, kAXSubroleAttribute) as? String == kAXStandardWindowSubrole,
              read(window, kAXMinimizedAttribute) as? Bool == false,
              read(window, "AXFullScreen") as? Bool != true,
              settable(window), !cancelled.isCancelled,
              let focused = focusedWindow(pid: pid, read: read, foreground: foreground), CFEqual(focused, window),
              !cancelled.isCancelled else { return false }
        // Targeted AX write only: no activation, key injection, raise, or app-wide fallback.
        AXUIElementSetMessagingTimeout(window, 0.08)
        return write(window)
    }
}
