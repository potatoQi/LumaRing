import XCTest
import AppKit
import LumaRingCore
@testable import LumaRing

final class CenterLauncherTests: XCTestCase {
    @MainActor private func makeView() -> RingView {
        let view = RingView(frame: NSRect(x: 0, y: 0, width: 480, height: 480))
        let icon = NSImage(systemSymbolName: "app.fill", accessibilityDescription: nil)!
        view.reset(apps: [AppRecord(pid: 100, bundleID: "test.primary", name: "Primary", icon: icon)], options: Options())
        view.launcherApps = [LauncherRecord(app: LauncherApp(bundleID: "test.quick", name: "Quick", path: "/missing.app"), icon: icon, available: true)]
        return view
    }
    @MainActor func testRepeatedDoubleClicksToggleWithoutMovingThePointer() async {
        let view = makeView()
        // One stationary rapid sequence is reported as 1...8, not four 1,2 pairs.
        for count in 1...8 {
            view.beginPointer(at: RingGeometry.center, clickCount: count)
            view.endPointer(at: RingGeometry.center)
            XCTAssertEqual(view.showsLauncher, (count / 2) % 2 == 1, "click \(count)")
            XCTAssertFalse(view.isPointerDown)
        }
        // A pause resets AppKit's count, which must still toggle normally.
        for count in [1, 2] {
            view.beginPointer(at: RingGeometry.center, clickCount: count)
            view.endPointer(at: RingGeometry.center)
        }
        XCTAssertTrue(view.showsLauncher)
    }
    @MainActor func testDoubleClickOpensAndRemainsOpenThroughOptionRelease() async {
        let view = makeView()
        view.optionPressed = true // Invocation's Option may still be down.
        view.beginPointer(at: RingGeometry.center)
        view.endPointer(at: RingGeometry.center)
        view.beginPointer(at: RingGeometry.center, clickCount: 2)
        view.endPointer(at: RingGeometry.center)
        XCTAssertTrue(view.showsLauncher); XCTAssertTrue(view.launcherPinned)
        view.updateOption(pressed: false)
        XCTAssertTrue(view.showsLauncher)
        view.updateOption(pressed: true); view.updateOption(pressed: false)
        XCTAssertTrue(view.showsLauncher)
        view.beginPointer(at: RingGeometry.center)
        view.endPointer(at: RingGeometry.center)
        view.beginPointer(at: RingGeometry.center, clickCount: 2)
        view.endPointer(at: RingGeometry.center)
        XCTAssertFalse(view.showsLauncher); XCTAssertFalse(view.launcherPinned)
    }
    @MainActor func testMouseOpenedLauncherUsesExistingLaunchAndDisabledPrimaryActions() async {
        let view = makeView()
        var launched: String?
        view.onActivateApp = { _ in XCTFail("Primary apps remain disabled") }
        view.onQuitApp = { _ in XCTFail("Primary apps remain disabled") }
        view.onLaunchApp = { launched = $0.bundleID }
        XCTAssertTrue(view.toggleLauncherFromCenter(at: RingGeometry.center))
        let primary = RingGeometry.point(angle: .pi / 2, radius: 88)
        view.beginPointer(at: primary); view.endPointer(at: primary)
        let outer = view.launcherPoint(0)
        view.beginPointer(at: outer); view.endPointer(at: outer)
        XCTAssertEqual(launched, "test.quick")
    }
    @MainActor func testSecondaryArcEditingMenuDragAndPagingExcludeDoubleClick() async {
        let view = makeView()
        let arrow = CGPoint(x: 225, y: 216)
        XCTAssertFalse(view.toggleLauncherFromCenter(at: arrow))
        XCTAssertFalse(view.toggleLauncherFromCenter(at: RingGeometry.point(angle: 0, radius: 88)))
        view.select(view.apps[0])
        let windows = (0..<2).map { WindowRecord(id: "w\($0)", pid: 100, title: "Window \($0)", minimized: false,
            fullscreen: false, frame: .zero, element: AXUIElementCreateApplication(100)) }
        view.setWindows(.ready(windows), for: 100)
        XCTAssertFalse(view.toggleLauncherFromCenter(at: RingGeometry.center))
        view.clearSelection()
        view.isEditingName = true
        XCTAssertFalse(view.toggleLauncherFromCenter(at: RingGeometry.center))
        view.isEditingName = false; view.isContextMenuOpen = true
        XCTAssertFalse(view.toggleLauncherFromCenter(at: RingGeometry.center))
        view.isContextMenuOpen = false
        view.beginPointer(at: RingGeometry.point(angle: .pi / 2, radius: 88))
        XCTAssertFalse(view.toggleLauncherFromCenter(at: RingGeometry.center))
    }
    @MainActor func testKeyboardModeStillClosesOnReleaseAndDoubleClickClosesHeldMode() async {
        let view = makeView()
        view.updateOption(pressed: true)
        XCTAssertTrue(view.showsLauncher); XCTAssertFalse(view.launcherPinned)
        view.updateOption(pressed: false); XCTAssertFalse(view.showsLauncher)
        view.updateOption(pressed: true)
        XCTAssertTrue(view.toggleLauncherFromCenter(at: RingGeometry.center))
        XCTAssertFalse(view.showsLauncher)
        view.updateOption(pressed: false); XCTAssertFalse(view.showsLauncher)
    }
    @MainActor func testResetAndDoubleClickCancelDeferredCenterSettings() async {
        let view = makeView()
        view.scheduleCenterSettings()
        let pending = view.centerClickWork
        XCTAssertNotNil(pending)
        view.beginPointer(at: RingGeometry.center, clickCount: 2)
        XCTAssertEqual(pending?.isCancelled, true)
        XCTAssertNil(view.centerClickWork)
        view.reset(apps: [], options: Options())
        XCTAssertFalse(view.launcherPinned); XCTAssertFalse(view.showsLauncher)
        view.scheduleCenterSettings()
        let moved = view.centerClickWork
        view.updateHover(at: RingGeometry.point(angle: 0, radius: 88))
        XCTAssertEqual(moved?.isCancelled, true)
        view.scheduleCenterSettings()
        let reset = view.centerClickWork
        view.reset(apps: [], options: Options())
        XCTAssertEqual(reset?.isCancelled, true)
    }
}
