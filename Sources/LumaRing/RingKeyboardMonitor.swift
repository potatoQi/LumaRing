import AppKit

/// The action panel deliberately stays non-key. A session tap consumes navigation
/// before it reaches the original app, without changing its window/input focus.
@MainActor final class RingKeyboardMonitor {
    private var local: Any?
    private var global: Any?
    private var tap: CFMachPort?
    private var source: CFRunLoopSource?
    private var handler: (@MainActor (NSEvent, Bool) -> Bool)?
    private var held: Set<UInt16> = []
    private var initiallyHeld: Set<UInt16> = []
    private var drainTimer: Timer?
    private var drainingSelf: RingKeyboardMonitor?

    init(install: Bool = true, handler: @escaping @MainActor (NSEvent, Bool) -> Bool) {
        self.handler = handler
        guard install else { return }
        initiallyHeld = Set(RingNavigation.keyCodes.filter { CGEventSource.keyState(.combinedSessionState, key: $0) })
        let mask = (CGEventMask(1) << CGEventType.keyDown.rawValue) | (CGEventMask(1) << CGEventType.keyUp.rawValue)
        tap = CGEvent.tapCreate(tap: .cgSessionEventTap, place: .headInsertEventTap, options: .defaultTap,
            eventsOfInterest: mask, callback: { _, type, event, context in
                guard let context else { return Unmanaged.passUnretained(event) }
                return MainActor.assumeIsolated {
                    let monitor = Unmanaged<RingKeyboardMonitor>.fromOpaque(context).takeUnretainedValue()
                    if type == .tapDisabledByTimeout || type == .tapDisabledByUserInput {
                        if let tap = monitor.tap { CGEvent.tapEnable(tap: tap, enable: true) }
                        return Unmanaged.passUnretained(event)
                    }
                    guard let key = NSEvent(cgEvent: event) else { return Unmanaged.passUnretained(event) }
                    return monitor.consume(key) ? nil : Unmanaged.passUnretained(event)
                }
            }, userInfo: Unmanaged.passUnretained(self).toOpaque())
        if let tap {
            source = CFMachPortCreateRunLoopSource(kCFAllocatorDefault, tap, 0)
            if let source { CFRunLoopAddSource(CFRunLoopGetMain(), source, .commonModes) }
            CGEvent.tapEnable(tap: tap, enable: true)
        } else {
            AppLog.shared.record("keyboard_navigation_unavailable", category: .ring, level: .warning)
        }
        let events: NSEvent.EventTypeMask = [.flagsChanged, .keyDown]
        local = NSEvent.addLocalMonitorForEvents(matching: events) { [weak self] event in
            let consumed = MainActor.assumeIsolated {
                guard let self else { return false }
                // Navigation is already handled by the tap. Other events (notably
                // modifier changes and typing to dismiss actions) retain their path.
                if self.tap != nil, RingNavigation.command(for: event) != nil { return false }
                return self.handler?(event, true) == true
            }
            return consumed ? nil : event
        }
        global = NSEvent.addGlobalMonitorForEvents(matching: events) { [weak self] event in
            MainActor.assumeIsolated {
                guard let self else { return }
                if self.tap != nil, RingNavigation.command(for: event) != nil { return }
                // An observational monitor must never navigate AND forward Tab.
                _ = self.handler?(event, false)
            }
        }
    }

    func consume(_ event: NSEvent) -> Bool {
        let code = event.keyCode
        if initiallyHeld.contains(code) {
            if event.type == .keyUp { initiallyHeld.remove(code) }
            return false // Let Carbon receive the invoking shortcut's release.
        }
        if event.type == .keyUp { return held.remove(code) != nil }
        guard event.type == .keyDown else { return false }
        if held.contains(code) {
            if event.isARepeat, let command = RingNavigation.command(for: event), command.repeats {
                _ = handler?(event, true)
            }
            return true
        }
        guard RingNavigation.command(for: event) != nil, let handler else { return false }
        // Mark before dispatch: Return may dismiss and stop this monitor inside
        // the callback. Its repeat/key-up must still not leak into the target app.
        held.insert(code)
        if handler(event, true) { return true }
        held.remove(code)
        return false
    }

    func stop() {
        handler = nil
        if let local { NSEvent.removeMonitor(local) }; local = nil
        if let global { NSEvent.removeMonitor(global) }; global = nil
        guard tap != nil, !held.isEmpty else { finish(); return }
        // Only drain keys whose down events we swallowed. Polling also handles a
        // lost key-up (sleep/tap interruption); no keyboard hook remains idle.
        drainingSelf = self
        guard drainTimer == nil else { return }
        let timer = Timer(timeInterval: 0.05, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated {
                guard let self else { return }
                self.held = self.held.filter { CGEventSource.keyState(.hidSystemState, key: $0) }
                if self.held.isEmpty { self.finish() }
            }
        }
        drainTimer = timer
        RunLoop.main.add(timer, forMode: .common)
    }

    private func finish() {
        drainTimer?.invalidate(); drainTimer = nil
        if let tap { CFMachPortInvalidate(tap) }; tap = nil
        if let source { CFRunLoopRemoveSource(CFRunLoopGetMain(), source, .commonModes) }; source = nil
        drainingSelf = nil
    }

    deinit {
        if let local { NSEvent.removeMonitor(local) }
        if let global { NSEvent.removeMonitor(global) }
        if let tap { CFMachPortInvalidate(tap) }
        if let source { CFRunLoopRemoveSource(CFRunLoopGetMain(), source, .commonModes) }
        drainTimer?.invalidate()
    }
}
