import AppKit
import XCTest
import LumaRingCore
@testable import LumaRing

final class GestureInvocationTests: XCTestCase {
    @MainActor private func event(_ type: NSEvent.EventType, time: TimeInterval, clicks: Int = 1) -> NSEvent {
        NSEvent.mouseEvent(with: type, location: RingGeometry.center, modifierFlags: [], timestamp: time,
            windowNumber: 0, context: nil, eventNumber: 0, clickCount: clicks, pressure: 0)!
    }

    @MainActor func testResidualSecondaryClickCannotOpenSettingsButFreshClickCan() {
        let view = RingView(frame: NSRect(x: 0, y: 0, width: 480, height: 480))
        view.reset(apps: [], options: Options())
        var settings = 0
        view.onSettings = { settings += 1 }
        view.suppressInvocationClicks(at: 10)
        view.rightMouseDown(with: event(.rightMouseDown, time: 9.99))
        view.rightMouseDown(with: event(.rightMouseDown, time: 10.08))
        XCTAssertEqual(settings, 0)
        view.rightMouseDown(with: event(.rightMouseDown, time: 10.3))
        XCTAssertEqual(settings, 1)
    }

    @MainActor func testResidualPrimaryAndDoubleClickCannotActivateOrOpenLauncher() {
        let view = RingView(frame: NSRect(x: 0, y: 0, width: 480, height: 480))
        view.reset(apps: [], options: Options())
        view.suppressInvocationClicks(at: 10)
        view.mouseDown(with: event(.leftMouseDown, time: 10.05, clicks: 2))
        view.mouseUp(with: event(.leftMouseUp, time: 10.08, clicks: 2))
        XCTAssertFalse(view.showsLauncher)
        XCTAssertFalse(view.isPointerDown)
        XCTAssertNil(view.centerClickWork)
        XCTAssertTrue(view.acceptsPointerEvent(event(.leftMouseDown, time: 10.3)))
    }

    @MainActor func testNormalInvocationResetsFenceAndNewGestureCancelsPendingClick() {
        let view = RingView(frame: NSRect(x: 0, y: 0, width: 480, height: 480))
        view.reset(apps: [], options: Options())
        view.scheduleCenterSettings()
        let pending = view.centerClickWork
        view.suppressInvocationClicks(at: 10)
        XCTAssertEqual(pending?.isCancelled, true)
        XCTAssertFalse(view.acceptsPointerEvent(event(.rightMouseDown, time: 10.1)))
        view.reset(apps: [], options: Options())
        XCTAssertTrue(view.acceptsPointerEvent(event(.rightMouseDown, time: 10.1)))
    }
}
