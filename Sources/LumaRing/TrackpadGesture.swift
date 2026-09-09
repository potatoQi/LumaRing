import AppKit
import Combine
import IOKit
import TrackpadInput

@MainActor final class TrackpadGesture: ObservableObject {
    static let shared = TrackpadGesture()
    enum Status: Equatable { case disabled, listening(Int), unavailable, noDevice, paused }
    enum Suspension: Hashable { case sleep, display, session, screenLock }
    @Published private(set) var status: Status = .disabled
    private(set) var enabled = false
    var onTap: (() -> Void)?
    private var generation: UInt64?
    private var suspensions: Set<Suspension> = []
    private var notificationPort: IONotificationPortRef?
    private var added: io_iterator_t = 0
    private var removed: io_iterator_t = 0
    private var reconnect: DispatchWorkItem?
    private let startListening: () -> LRTrackpadResult
    private let stopListening: () -> Void
    private let observeDevices: Bool

    init(startListening: @escaping () -> LRTrackpadResult = {
        LRTrackpadStart { token in
            DispatchQueue.main.async { TrackpadGesture.shared.deliver(token) }
        }
    }, stopListening: @escaping () -> Void = { LRTrackpadStop() }, observeDevices: Bool = true) {
        self.startListening = startListening
        self.stopListening = stopListening
        self.observeDevices = observeDevices
    }

    func setEnabled(_ value: Bool) {
        guard enabled != value else { return }
        enabled = value
        if value { start() } else { stop(); status = .disabled }
    }

    func suspend(_ reason: Suspension) {
        suspensions.insert(reason)
        guard enabled else { return }
        stop()
        status = .paused
    }

    func resume(_ reason: Suspension) {
        suspensions.remove(reason)
        if enabled && suspensions.isEmpty { start() }
    }

    func retry() { if enabled { start() } }

    func shutdown() {
        enabled = false
        stop()
        status = .disabled
    }

    private func start() {
        guard enabled, suspensions.isEmpty else { status = .paused; return }
        reconnect?.cancel()
        reconnect = nil
        if observeDevices { watchDevices() }
        // Opening devices and the framework only happens on enable/wake/change.
        let result = startListening()
        generation = result.devices > 0 ? result.generation : nil
        status = !result.available ? .unavailable : result.devices > 0 ? .listening(Int(result.devices)) : .noDevice
    }

    private func stop() {
        generation = nil
        reconnect?.cancel()
        reconnect = nil
        stopListening()
        if let notificationPort { IONotificationPortSetDispatchQueue(notificationPort, nil) }
        if added != 0 { IOObjectRelease(added); added = 0 }
        if removed != 0 { IOObjectRelease(removed); removed = 0 }
        if let notificationPort { IONotificationPortDestroy(notificationPort) }
        notificationPort = nil
    }

    // Internal so tests can verify that stale queued actions cannot open a ring.
    func deliver(_ token: UInt64) {
        guard enabled, suspensions.isEmpty, token == generation else { return }
        onTap?()
    }

    private func watchDevices() {
        guard notificationPort == nil, let port = IONotificationPortCreate(kIOMainPortDefault) else { return }
        notificationPort = port
        IONotificationPortSetDispatchQueue(port, .main)
        let callback: IOServiceMatchingCallback = { _, iterator in
            var changed = false
            while case let device = IOIteratorNext(iterator), device != 0 {
                IOObjectRelease(device)
                changed = true
            }
            if changed {
                MainActor.assumeIsolated { TrackpadGesture.shared.devicesChanged() }
            }
        }
        for (notification, iterator) in [(kIOFirstMatchNotification, true), (kIOTerminatedNotification, false)] {
            var result: io_iterator_t = 0
            if IOServiceAddMatchingNotification(port, notification, IOServiceMatching("AppleMultitouchDevice"), callback, nil, &result) == KERN_SUCCESS {
                // Drain the initial inventory to arm notifications, without restarting.
                while case let device = IOIteratorNext(result), device != 0 { IOObjectRelease(device) }
                if iterator { added = result } else { removed = result }
            }
        }
    }

    private func devicesChanged() {
        guard enabled, suspensions.isEmpty else { return }
        // Disconnect invalidates recognizer state and any already-queued tap now.
        generation = nil
        stopListening()
        reconnect?.cancel()
        let work = DispatchWorkItem { [weak self] in self?.start() }
        reconnect = work
        DispatchQueue.main.asyncAfter(deadline: .now() + .milliseconds(200), execute: work)
    }

    var message: String? {
        switch status {
        case .unavailable:
            return L10n.text("当前系统无法使用四指轻点。快捷键和菜单栏仍可使用。", "Four-finger tap is unavailable on this system. The shortcut and menu bar still work.")
        case .noDevice:
            return L10n.text("未检测到支持的触控板。连接触控板后可重试。", "No supported trackpad was detected. Connect a trackpad and retry.")
        default: return nil
        }
    }
}
