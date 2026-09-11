import AppKit
import XCTest
@testable import LumaRing

final class SettingsWindowTests: XCTestCase {
    @MainActor private class TestWindow: SettingsWindow {
        var eligible = true
        var closeCount = 0
        override var canCloseWithPinch: Bool { eligible }
        override func performClose(_ sender: Any?) { closeCount += 1 }
    }

    @MainActor private func makeWindow() -> TestWindow {
        _ = NSApplication.shared
        let window = TestWindow(contentRect: .zero, styleMask: [.titled, .closable], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        return window
    }

    @MainActor func testCompletedPinchClosesOnceAndOnlyAfterRelease() async {
        let window = makeWindow()
        window.beginPinch()
        XCTAssertEqual(window.closeCount, 0)
        window.completePinch()
        window.completePinch()
        XCTAssertEqual(window.closeCount, 1)
    }

    @MainActor func testCancelledOrInterruptedPinchDoesNotCloseSettings() async {
        for interruption in 0..<4 {
            let window = makeWindow()
            window.beginPinch()
            switch interruption {
            case 0: window.cancelPinch()
            case 1: window.resignKey() // Returning to settings must not revive the gesture.
            case 2: window.eligible = false
            default: window.close() // Closing and reopening must not revive it either.
            }
            window.completePinch()
            XCTAssertEqual(window.closeCount, 0)
        }
    }

    @MainActor func testGestureStartingElsewhereDoesNotCloseNewlyFocusedSettings() async {
        let window = makeWindow()
        window.eligible = false
        window.beginPinch()
        window.eligible = true
        window.completePinch()
        XCTAssertEqual(window.closeCount, 0)
    }
}
