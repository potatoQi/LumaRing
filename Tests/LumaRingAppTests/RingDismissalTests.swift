import AppKit
import XCTest
@testable import LumaRing

final class RingDismissalTests: XCTestCase {
    private func escape(flags: NSEvent.ModifierFlags = [], repeat repeating: Bool = false,
                        type: NSEvent.EventType = .keyDown) -> NSEvent {
        NSEvent.keyEvent(with: type, location: .zero, modifierFlags: flags, timestamp: 1,
                        windowNumber: 0, context: nil, characters: "", charactersIgnoringModifiers: "",
                        isARepeat: repeating, keyCode: 53)!
    }

    @MainActor func testEscapeDismissesBothRingsWithLocalAndGlobalFallbackHandling() async {
        _ = NSApplication.shared
        let saved = Preferences.shared.options
        let ring = RingController(catalog: ApplicationCatalog())
        defer { ring.dismiss(); Preferences.shared.options = saved }
        for actionMode in [false, true] {
            for canNavigate in [true, false] {
                ring.show(actionMode: actionMode)
                XCTAssertTrue(ring.isVisible)
                XCTAssertTrue(ring.handleKeyboard(escape(), canNavigate: canNavigate))
                XCTAssertFalse(ring.isVisible)
                XCTAssertFalse(ring.handleKeyboard(escape(), canNavigate: canNavigate))
            }
        }
    }

    @MainActor func testEscapeCancelsHoldToSelectBeforeShortcutReleaseAndAllowsReopening() async {
        _ = NSApplication.shared
        let saved = Preferences.shared.options
        let ring = RingController(catalog: ApplicationCatalog())
        defer { ring.dismiss(); Preferences.shared.options = saved }
        Preferences.shared.options = Options()
        Preferences.shared.options.holdToSelect = true
        ring.pressShortcut()
        XCTAssertTrue(ring.isVisible)
        ring.view.onActivateApp = { _ in XCTFail("Escape must not activate an app") }
        ring.view.onActivateWindow = { _ in XCTFail("Escape must not activate a window") }
        ring.view.navigate(.step(1))
        XCTAssertTrue(ring.handleKeyboard(escape(flags: .option)))
        XCTAssertFalse(ring.isVisible)
        ring.releaseShortcut()
        XCTAssertFalse(ring.isVisible)
        ring.pressShortcut()
        XCTAssertTrue(ring.isVisible)
        XCTAssertTrue(ring.handleKeyboard(escape()))
        XCTAssertFalse(ring.isVisible)
    }

    @MainActor func testMenusAndNameEditingKeepEscape() async {
        _ = NSApplication.shared
        let saved = Preferences.shared.options
        let ring = RingController(catalog: ApplicationCatalog())
        defer { ring.dismiss(); Preferences.shared.options = saved }
        ring.show(actionMode: false)
        ring.view.isContextMenuOpen = true
        XCTAssertFalse(ring.handleKeyboard(escape()))
        XCTAssertTrue(ring.isVisible)
        ring.view.isContextMenuOpen = false
        ring.view.isEditingName = true
        XCTAssertFalse(ring.handleKeyboard(escape()))
        XCTAssertTrue(ring.isVisible)
        ring.view.isEditingName = false
        XCTAssertTrue(ring.handleKeyboard(escape()))
        XCTAssertFalse(ring.isVisible)
    }

    @MainActor func testEscapeRepeatAndReleaseAreConsumedAfterDismissal() async {
        var dismissals = 0
        var monitor: RingKeyboardMonitor!
        monitor = RingKeyboardMonitor(install: false) { _, _ in
            dismissals += 1
            monitor.stop()
            return true
        }
        XCTAssertTrue(monitor.consume(escape(flags: .option)))
        XCTAssertTrue(monitor.consume(escape(repeat: true)))
        XCTAssertTrue(monitor.consume(escape(type: .keyUp)))
        XCTAssertEqual(dismissals, 1)
        XCTAssertFalse(monitor.consume(escape()))
        XCTAssertFalse(monitor.consume(escape(type: .keyUp)))
    }
}
