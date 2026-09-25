import XCTest
import AppKit
import LumaRingCore
@testable import LumaRing

final class RingNavigationTests: XCTestCase {
    private func key(_ code: UInt16, flags: NSEvent.ModifierFlags = [], repeat repeating: Bool = false,
                     type: NSEvent.EventType = .keyDown) -> NSEvent {
        NSEvent.keyEvent(with: type, location: .zero, modifierFlags: flags, timestamp: 1,
                        windowNumber: 0, context: nil, characters: "", charactersIgnoringModifiers: "",
                        isARepeat: repeating, keyCode: code)!
    }
    private func apps(_ count: Int) -> [AppRecord] {
        (0..<count).map { AppRecord(pid: pid_t(100 + $0), bundleID: "test.\($0)", name: "App \($0)", icon: NSImage()) }
    }
    private func windows(_ count: Int, pid: pid_t = 100) -> [WindowRecord] {
        (0..<count).map { WindowRecord(id: "w\($0)", pid: pid, title: "Window \($0)", minimized: false,
                                      fullscreen: false, frame: .zero, element: AXUIElementCreateApplication(pid)) }
    }

    func testOnlyRequestedKeysNavigate() {
        XCTAssertEqual(RingNavigation.command(for: key(48)), .step(1))
        XCTAssertEqual(RingNavigation.command(for: key(48, flags: .shift)), .step(-1))
        XCTAssertEqual(RingNavigation.command(for: key(48, flags: [.option, .shift])), .step(-1))
        XCTAssertEqual(RingNavigation.command(for: key(50)), .toggleSecondary)
        XCTAssertEqual(RingNavigation.command(for: key(50, flags: .shift)), .toggleSecondary)
        XCTAssertEqual(RingNavigation.command(for: key(36)), .activate)
        for code: UInt16 in [123, 124, 125, 126, 57, 53, 49, 0, 116, 121] {
            XCTAssertNil(RingNavigation.command(for: key(code)))
        }
        XCTAssertNil(RingNavigation.command(for: key(48, flags: .command)))
        XCTAssertNil(RingNavigation.command(for: key(48, flags: .control)))
        XCTAssertNil(RingNavigation.command(for: key(48, type: .keyUp)))
    }

    @MainActor func testInvocationChordsPassThroughWithoutNavigatingOrSwallowingRelease() {
        let shortcuts = [Shortcut(), Shortcut(keyCode: 36, modifiers: 0, label: "Return")]
        var navigated = 0
        let monitor = RingKeyboardMonitor(install: false) { event, _ in
            guard RingNavigation.command(for: event, reserving: shortcuts) != nil else { return false }
            navigated += 1
            return true
        }
        // Default Option-Tab must reach Carbon to close an already-open ring.
        XCTAssertFalse(monitor.consume(key(48, flags: .option)))
        XCTAssertFalse(monitor.consume(key(48, flags: .option, repeat: true)))
        XCTAssertFalse(monitor.consume(key(48, flags: .option, type: .keyUp)))
        // A user-configured action invocation gets the same priority.
        XCTAssertFalse(monitor.consume(key(36)))
        XCTAssertFalse(monitor.consume(key(36, type: .keyUp)))
        XCTAssertEqual(navigated, 0)
        XCTAssertTrue(monitor.consume(key(48)))
        XCTAssertTrue(monitor.consume(key(48, type: .keyUp)))
        XCTAssertTrue(monitor.consume(key(48, flags: .shift)))
        XCTAssertTrue(monitor.consume(key(48, flags: .shift, type: .keyUp)))
        XCTAssertEqual(navigated, 2)
        monitor.stop()
    }

    @MainActor func testPrimaryOrderCrossesPagesAndWrapsBothWays() {
        let view = RingView()
        var options = Options(); options.appPageSize = 4
        view.reset(apps: apps(9), options: options)
        var selected: [pid_t] = []
        view.onSelectApp = { selected.append($0.pid) }
        for _ in 0..<10 { view.navigate(.step(1)) }
        XCTAssertEqual(selected, Array(100...108).map(pid_t.init) + [100])
        XCTAssertEqual(view.appPage, 0)
        view.navigate(.step(-1))
        XCTAssertEqual(view.highlightedApp, 108)
        XCTAssertEqual(view.appPage, 2)
        view.navigate(.step(-1))
        XCTAssertEqual(view.highlightedApp, 107)
        XCTAssertEqual(view.appPage, 1)
        var activated: pid_t?
        view.onActivateApp = { activated = $0.pid }
        view.navigate(.activate)
        XCTAssertEqual(activated, 107)
        view.reset(apps: apps(9), options: options)
        view.navigate(.step(-1))
        XCTAssertEqual(view.highlightedApp, 108)
    }

    @MainActor func testToggleWaitsForWindowsThenTabsPreviewAcrossPagesAndToggleReturns() {
        let view = RingView()
        var options = Options(); options.windowPageSize = 2
        view.reset(apps: apps(3), options: options)
        view.navigate(.step(1))
        view.navigate(.toggleSecondary)
        XCTAssertFalse(view.keyboardSecondary)
        var previews: [String] = []
        view.onHoverWindow = { if let record = $0 { previews.append(record.id) } }
        view.setWindows(.ready(windows(5)), for: 100)
        XCTAssertTrue(view.keyboardSecondary)
        XCTAssertEqual(view.currentWindow?.id, "w0")
        for _ in 0..<4 { view.navigate(.step(1)) }
        XCTAssertEqual(view.windowPage, 2)
        XCTAssertEqual(previews, ["w0", "w1", "w2", "w3", "w4"])
        view.navigate(.step(1))
        XCTAssertEqual(view.windowPage, 0)
        view.navigate(.step(-1))
        XCTAssertEqual(view.currentWindow?.id, "w4")
        var activated: String?
        view.onActivateWindow = { activated = $0.id }
        view.navigate(.activate)
        XCTAssertEqual(activated, "w4")
        view.navigate(.toggleSecondary)
        XCTAssertNil(view.currentWindow)
        XCTAssertFalse(view.keyboardSecondary)
        XCTAssertEqual(view.highlightedApp, 100)
        view.navigate(.step(1))
        XCTAssertEqual(view.highlightedApp, 101)
    }

    @MainActor func testLateSecondaryResultsAndCancelledToggleDoNotMoveKeyboardFocus() {
        let view = RingView()
        view.reset(apps: apps(2), options: Options())
        view.navigate(.step(1)); view.navigate(.toggleSecondary)
        view.navigate(.toggleSecondary)
        view.setWindows(.ready(windows(2)), for: 100)
        XCTAssertNil(view.currentWindow)
        view.navigate(.toggleSecondary)
        XCTAssertNotNil(view.currentWindow)
        view.navigate(.toggleSecondary); view.navigate(.step(1)); view.navigate(.toggleSecondary)
        view.setWindows(.ready(windows(3)), for: 100)
        XCTAssertTrue(view.loading)
        view.setWindows(.unavailable("Unavailable"), for: 101)
        XCTAssertFalse(view.keyboardSecondary)
        view.navigate(.step(1))
        XCTAssertEqual(view.highlightedApp, 100)
    }

    @MainActor func testSingleWindowAndEmptyTargetsAreSafe() {
        let view = RingView()
        view.reset(apps: apps(1), options: Options())
        view.navigate(.step(1))
        view.setWindows(.ready(windows(1)), for: 100)
        view.navigate(.toggleSecondary)
        XCTAssertFalse(view.keyboardSecondary)
        var closed = false
        view.onClose = { closed = true }
        view.reset(apps: [], options: Options())
        for command: RingNavigation in [.step(1), .step(-1), .toggleSecondary, .toggleSecondary, .activate] {
            view.navigate(command)
        }
        XCTAssertFalse(closed)
    }

    @MainActor func testPointerTakesOverAndCancelsPendingKeyboardEntry() {
        let view = RingView()
        view.reset(apps: apps(4), options: Options())
        view.navigate(.step(1)); view.navigate(.toggleSecondary)
        let point = RingGeometry.point(angle: RingGeometry.angle(index: 2, count: 4), radius: 80)
        view.updateHover(at: point)
        view.setWindows(.ready(windows(2, pid: 102)), for: 102)
        XCTAssertEqual(view.highlightedApp, 102)
        XCTAssertFalse(view.keyboardSecondary)
        XCTAssertNil(view.currentWindow)
        view.navigate(.step(1))
        XCTAssertEqual(view.highlightedApp, 103)
        // Stationary pointer/tracking notifications cannot clear keyboard selection.
        view.mouseExited(with: key(48))
        XCTAssertEqual(view.highlightedApp, 103)
        view.cancelHover()
    }

    @MainActor func testActionNavigationCrossesPagesAndExecutesOnlyWhenReady() {
        let view = ActionRingView()
        view.actions = (0..<14).map { AppAction(id: "a\($0)", name: "Action \($0)", shortcut: Shortcut()) }
        view.reset()
        for _ in 0..<14 { view.navigate(.step(1)) }
        XCTAssertEqual(view.page, 2)
        XCTAssertEqual(view.hover, "a13")
        view.navigate(.step(1)); XCTAssertEqual(view.hover, "a0")
        view.navigate(.step(-1)); XCTAssertEqual(view.hover, "a13")
        var executed: [String] = []
        view.onAction = { executed.append($0.id) }
        view.navigate(.activate); XCTAssertTrue(executed.isEmpty)
        view.ready = true
        view.navigate(.toggleSecondary); view.navigate(.toggleSecondary)
        XCTAssertEqual(view.hover, "a13")
        view.navigate(.activate); XCTAssertEqual(executed, ["a13"])
        view.reset(); view.navigate(.activate)
        XCTAssertEqual(executed, ["a13"])
        XCTAssertFalse(view.acceptsFirstResponder)
        XCTAssertFalse(ActionPanel().canBecomeKey)
    }

    @MainActor func testFavoritesPageAndSelectionStaySeparateFromActionRing() {
        let view = RingView()
        view.reset(apps: apps(2), options: Options())
        view.launcherApps = (0..<14).map {
            LauncherRecord(app: LauncherApp(bundleID: "fav.\($0)", name: "Favorite \($0)", path: "/test/\($0).app"),
                           icon: NSImage(), available: $0 != 12)
        }
        let actions = ActionRingView()
        actions.actions = [AppAction(id: "a", name: "Action", shortcut: Shortcut())]
        actions.navigate(.step(1))
        view.launcherInnerArtwork = { _ in }
        view.updateOption(pressed: true)
        XCTAssertTrue(view.showsLauncher)
        for _ in 0..<13 { view.navigate(.step(1)) }
        XCTAssertEqual(view.launcherPage, 1)
        var launched: String?
        view.onLaunchApp = { launched = $0.bundleID }
        view.navigate(.activate)
        XCTAssertNil(launched) // Unavailable favorite cannot be launched.
        view.navigate(.step(1)); view.navigate(.activate)
        XCTAssertEqual(launched, "fav.13")
        view.navigate(.step(1))
        XCTAssertEqual(view.launcherPage, 0)
        view.navigate(.step(-1))
        XCTAssertEqual(view.hoveredLauncher, view.launcherApps.last?.app.id)
        view.updateOption(pressed: false)
        XCTAssertFalse(view.showsLauncher)
        XCTAssertEqual(actions.hover, "a")
    }

    @MainActor func testTapConsumesRepeatsAndReleaseWithoutForwardingAndStopsAtKeyUp() {
        var commands: [RingNavigation] = []
        let monitor = RingKeyboardMonitor(install: false) { event, canNavigate in
            XCTAssertTrue(canNavigate)
            if let command = RingNavigation.command(for: event) { commands.append(command); return true }
            return false
        }
        XCTAssertTrue(monitor.consume(key(48)))
        for _ in 0..<4 { XCTAssertTrue(monitor.consume(key(48, repeat: true))) }
        XCTAssertTrue(monitor.consume(key(48, flags: .shift, repeat: true)))
        XCTAssertEqual(commands, Array(repeating: .step(1), count: 5) + [.step(-1)])
        XCTAssertTrue(monitor.consume(key(48, type: .keyUp)))
        XCTAssertFalse(monitor.consume(key(48, type: .keyUp)))
        XCTAssertEqual(commands.count, 6)
        XCTAssertFalse(monitor.consume(key(123)))
        XCTAssertFalse(monitor.consume(key(53)))
        XCTAssertTrue(monitor.consume(key(36)))
        XCTAssertTrue(monitor.consume(key(36, repeat: true)))
        XCTAssertEqual(commands.last, .activate)
        XCTAssertEqual(commands.count, 7)
        monitor.stop()
        XCTAssertTrue(monitor.consume(key(36, repeat: true)))
        XCTAssertTrue(monitor.consume(key(36, type: .keyUp)))
        XCTAssertFalse(monitor.consume(key(48)))
        XCTAssertEqual(commands.count, 7)
    }

    @MainActor func testBacktickPressTogglesOnceAndReleaseDoesNotReachOriginalApp() {
        let view = RingView()
        view.reset(apps: apps(2), options: Options())
        view.navigate(.step(1))
        view.setWindows(.ready(windows(2)), for: 100)
        let monitor = RingKeyboardMonitor(install: false) { event, _ in
            guard let command = RingNavigation.command(for: event) else { return false }
            view.navigate(command)
            return true
        }
        XCTAssertTrue(monitor.consume(key(50)))
        XCTAssertTrue(view.keyboardSecondary)
        for _ in 0..<10 { XCTAssertTrue(monitor.consume(key(50, repeat: true))) }
        XCTAssertTrue(view.keyboardSecondary)
        XCTAssertTrue(monitor.consume(key(50, type: .keyUp)))
        XCTAssertTrue(view.keyboardSecondary)
        XCTAssertTrue(monitor.consume(key(50, flags: .shift)))
        XCTAssertFalse(view.keyboardSecondary)
        XCTAssertTrue(monitor.consume(key(50, flags: .shift, type: .keyUp)))
        XCTAssertEqual(view.highlightedApp, 100)
        monitor.stop()
        XCTAssertFalse(monitor.consume(key(50)))
    }

    @MainActor func testToggleFromMouseSelectedWindowReturnsToItsApp() {
        let view = RingView()
        view.reset(apps: apps(2), options: Options())
        view.navigate(.step(1))
        view.setWindows(.ready(windows(2)), for: 100)
        let point = RingGeometry.point(angle: RingGeometry.arcAngle(index: 1, count: 2, anchor: .pi / 2), radius: RingGeometry.windowRadius)
        view.updateHover(at: point)
        XCTAssertEqual(view.currentWindow?.id, "w1")
        XCTAssertFalse(view.keyboardSecondary)
        view.navigate(.toggleSecondary)
        XCTAssertNil(view.currentWindow)
        XCTAssertEqual(view.highlightedApp, 100)
        view.navigate(.step(1))
        XCTAssertEqual(view.highlightedApp, 101)
    }

    @MainActor func testEditingAndMenusKeepTheirKeysAndPointerPressCannotActivate() {
        let monitor = RingKeyboardMonitor(install: false) { _, _ in false }
        XCTAssertFalse(monitor.consume(key(48)))
        XCTAssertFalse(monitor.consume(key(48, type: .keyUp)))
        monitor.stop()
        let view = RingView()
        view.reset(apps: apps(3), options: Options())
        view.isEditingName = true; view.navigate(.step(1)); XCTAssertNil(view.highlightedApp)
        view.isEditingName = false; view.isContextMenuOpen = true
        view.navigate(.step(1)); XCTAssertNil(view.highlightedApp)
        view.isContextMenuOpen = false
        view.beginPointer(at: RingGeometry.center)
        view.navigate(.step(1)); XCTAssertNil(view.highlightedApp)
        view.cancelPointerInteraction()
    }
}
