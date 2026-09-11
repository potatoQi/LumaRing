import AppKit

/// Installed only while a ring is visible. Global monitoring is observational;
/// local modifier events are handled here instead of being handled twice by views.
@MainActor final class RingKeyboardMonitor {
    private var local: Any?
    private var global: Any?
    init(handler: @escaping @MainActor (NSEvent) -> Bool) {
        let mask: NSEvent.EventTypeMask = [.flagsChanged, .keyDown]
        local = NSEvent.addLocalMonitorForEvents(matching: mask) { event in
            let consumed = MainActor.assumeIsolated { handler(event) }
            return consumed ? nil : event
        }
        global = NSEvent.addGlobalMonitorForEvents(matching: mask) { event in
            MainActor.assumeIsolated { _ = handler(event) }
        }
    }
    func stop() {
        if let local { NSEvent.removeMonitor(local) }; local = nil
        if let global { NSEvent.removeMonitor(global) }; global = nil
    }
    deinit {
        if let local { NSEvent.removeMonitor(local) }
        if let global { NSEvent.removeMonitor(global) }
    }
}
