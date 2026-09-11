import AppKit

/// Keeps a pinch tied to the settings window that was focused when it began.
@MainActor class SettingsWindow: NSWindow {
    private var pinchPending = false

    var canCloseWithPinch: Bool {
        NSApp.isActive && isKeyWindow && isVisible && attachedSheet == nil
    }

    func beginPinch() { pinchPending = canCloseWithPinch }

    func completePinch() {
        let shouldClose = pinchPending && canCloseWithPinch
        cancelPinch()
        if shouldClose { performClose(nil) }
    }

    func cancelPinch() { pinchPending = false }

    override func resignKey() {
        cancelPinch()
        super.resignKey()
    }

    override func close() {
        cancelPinch()
        super.close()
    }
}
