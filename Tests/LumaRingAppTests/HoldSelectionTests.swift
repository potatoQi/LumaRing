import AppKit
import XCTest
import LumaRingCore
@testable import LumaRing

final class HoldSelectionTests: XCTestCase {
    private func apps(_ count: Int = 6) -> [AppRecord] {
        (0..<count).map { AppRecord(pid: pid_t(100 + $0), bundleID: "test.\($0)", name: "App \($0)", icon: NSImage()) }
    }

    private func point(_ index: Int, count: Int = 6, radius: Double) -> CGPoint {
        RingGeometry.point(angle: RingGeometry.angle(index: index, count: count), radius: radius)
    }

    @MainActor func testSectorsExtendInEveryDirectionWithoutActivatingUntilRelease() async {
        let view = RingView()
        view.reset(apps: apps(), options: Options())
        view.selectingWithShortcut = true
        var activated: [pid_t] = []
        view.onActivateApp = { activated.append($0.pid) }
        for radius in [RingGeometry.appRadius, RingGeometry.appOuter + 1, RingGeometry.windowOuter + 1, 2000] {
            for index in 0..<6 {
                view.updateHover(at: point(index, radius: radius))
                XCTAssertEqual(view.highlightedApp, pid_t(100 + index))
            }
        }
        XCTAssertTrue(activated.isEmpty)
        // A pending collapse must not clear the selection while outside the ring.
        try? await Task.sleep(nanoseconds: 250_000_000)
        XCTAssertEqual(view.highlightedApp, 105)
        view.activateHovered()
        XCTAssertEqual(activated, [105])
    }

    @MainActor func testReturningToCenterCancelsAndNormalModeKeepsBoundedTargets() async {
        let view = RingView()
        var options = Options(); options.holdToSelect = true
        view.reset(apps: apps(), options: options)
        // The preference alone must not change click/trackpad invocation.
        view.updateHover(at: point(2, radius: 1000))
        XCTAssertNil(view.highlightedApp)
        view.selectingWithShortcut = true
        view.updateHover(at: point(2, radius: 1000))
        XCTAssertEqual(view.highlightedApp, 102)
        view.updateHover(at: RingGeometry.center)
        XCTAssertNil(view.highlightedApp)
        var closed = false
        view.onClose = { closed = true }
        view.onActivateApp = { _ in XCTFail("Returning to center cancels selection") }
        view.activateHovered()
        XCTAssertTrue(closed)
        view.reset(apps: apps(), options: options)
        XCTAssertFalse(view.selectingWithShortcut)
        view.updateHover(at: point(2, radius: 1000))
        XCTAssertNil(view.highlightedApp)
        view.cancelHover()
    }

    @MainActor func testLeavingPanelKeepsDirectionalSelection() async throws {
        let view = RingView(frame: CGRect(x: 0, y: 0, width: 480, height: 480))
        view.reset(apps: apps(), options: Options())
        view.selectingWithShortcut = true
        view.updateHover(at: point(0, radius: RingGeometry.appRadius))
        let exit = try XCTUnwrap(NSEvent.enterExitEvent(with: .mouseExited, location: point(0, radius: 500),
            modifierFlags: .option, timestamp: 1, windowNumber: 0, context: nil,
            eventNumber: 0, trackingNumber: 0, userData: nil))
        view.mouseExited(with: exit)
        XCTAssertEqual(view.highlightedApp, 100)
        view.selectingWithShortcut = false
        view.mouseExited(with: exit)
        XCTAssertNil(view.highlightedApp)
    }

    @MainActor func testWindowTargetsRemainSelectedBeyondTheOuterEdge() async {
        let view = RingView()
        view.reset(apps: apps(), options: Options())
        view.selectingWithShortcut = true
        view.updateHover(at: point(0, radius: RingGeometry.appRadius))
        let windows = (0..<2).map { WindowRecord(id: "w\($0)", pid: 100, title: "Window \($0)", minimized: false,
            fullscreen: false, frame: .zero, element: AXUIElementCreateApplication(100)) }
        view.setWindows(.ready(windows), for: 100)
        let angle = RingGeometry.arcAngle(index: 1, count: 2, anchor: view.arcAnchor)
        view.updateHover(at: RingGeometry.point(angle: angle, radius: RingGeometry.windowRadius))
        XCTAssertEqual(view.currentWindow?.id, "w1")
        var activatedWindows: [String] = []
        view.onActivateWindow = { activatedWindows.append($0.id) }
        view.activateHovered()
        XCTAssertEqual(activatedWindows, ["w1"])
        view.updateHover(at: RingGeometry.point(angle: angle, radius: 1000))
        XCTAssertEqual(view.currentWindow?.id, "w1")
        XCTAssertEqual(view.highlightedApp, 100)
        var activatedApp: pid_t?
        view.onActivateApp = { activatedApp = $0.pid }
        view.activateHovered()
        XCTAssertNil(activatedApp)
        XCTAssertEqual(activatedWindows, ["w1", "w1"])
    }

    @MainActor private func secondaryView(count: Int = 4) -> RingView {
        let view = RingView(frame: CGRect(x: 0, y: 0, width: 480, height: 480))
        view.reset(apps: apps(8), options: Options())
        view.selectingWithShortcut = true
        view.updateHover(at: point(6, count: 8, radius: RingGeometry.appRadius))
        let windows = (0..<count).map { WindowRecord(id: "w\($0)", pid: 106, title: "Window \($0)", minimized: false,
            fullscreen: false, frame: .zero, element: AXUIElementCreateApplication(106)) }
        view.setWindows(.ready(windows), for: 106)
        return view
    }

    @MainActor func testDiagonalPathToEverySecondaryItemKeepsTheParentApp() async {
        let view = secondaryView()
        let anchor = view.arcAnchor
        var activated: [String] = []
        view.onActivateWindow = { activated.append($0.id) }
        view.onActivateApp = { _ in XCTFail("Secondary selection must not activate another app") }
        for index in 0..<4 {
            let angle = RingGeometry.arcAngle(index: index, count: 4, anchor: anchor)
            for radius in [80.0, 117, 119, 158, 220, 2000, 90] {
                let p = RingGeometry.point(angle: angle, radius: radius)
                view.updateHover(at: p)
                XCTAssertEqual(view.selectedApp, 106)
                XCTAssertEqual(view.highlightedApp, 106)
                XCTAssertEqual(view.currentWindow?.id, radius > 118 ? "w\(index)" : nil)
                if radius < 118 { XCTAssertEqual(view.appHighlightPath?.contains(p), true) }
            }
            view.updateHover(at: RingGeometry.point(angle: angle, radius: 2000))
            XCTAssertEqual(activated.count, index)
            view.activateHovered()
        }
        XCTAssertEqual(activated, ["w0", "w1", "w2", "w3"])
    }

    @MainActor func testHighlightStaysBetweenCenterInsetAndOuterRim() async throws {
        for count in [2, 4, 6] {
            let view = secondaryView(count: count)
            for held in [false, true] {
                view.selectingWithShortcut = held
                let path = try XCTUnwrap(view.appHighlightPath)
                for step in 0..<360 {
                    let angle = Double(step) * .pi / 180
                    for radius in [0.0, 40, 45, 51.9, 52, 117.8, 118, 120] {
                        XCTAssertFalse(path.contains(RingGeometry.point(angle: angle, radius: radius)))
                    }
                }
                for radius in [53.0, 88, 117] {
                    XCTAssertTrue(path.contains(RingGeometry.point(angle: view.arcAnchor, radius: radius)))
                }
                // The visual inset must not change the established selection threshold.
                view.updateHover(at: RingGeometry.point(angle: view.arcAnchor, radius: 45))
                XCTAssertEqual(view.highlightedApp, 106)
            }
        }
    }

    @MainActor func testCrossingEitherSideImmediatelyHandsOffToAnotherApp() async {
        for side in [-1.0, 1.0] {
            for radius in [88.0, 158, 2000] {
                let view = secondaryView()
                let anchor = view.arcAnchor, half = RingGeometry.arcHalfAngle(count: 4)
                view.updateHover(at: RingGeometry.point(angle: anchor + side * (half - 0.001), radius: radius))
                XCTAssertEqual(view.selectedApp, 106)
                view.updateHover(at: RingGeometry.point(angle: anchor + side * (half + 0.001), radius: radius))
                XCTAssertEqual(view.selectedApp, side > 0 ? 104 : 100)
                XCTAssertFalse(view.showsWindowArc)
                XCTAssertNil(view.currentWindow)
                // An old app's asynchronous response must not restore its enlarged sector.
                view.setWindows(.ready([]), for: 106)
                XCTAssertEqual(view.highlightedApp, side > 0 ? 104 : 100)
            }
        }
    }

    @MainActor func testCenterReleasesExpandedSectorAndNormalHoverKeepsAppBoundaries() async {
        let view = secondaryView()
        let neighbor = point(5, count: 8, radius: 88)
        view.updateHover(at: neighbor)
        XCTAssertEqual(view.selectedApp, 106)
        view.updateHover(at: RingGeometry.center)
        XCTAssertNil(view.selectedApp)
        XCTAssertNil(view.currentWindow)
        XCTAssertNil(view.appHighlightPath)
        view.updateHover(at: neighbor)
        XCTAssertEqual(view.selectedApp, 105)

        let normal = secondaryView()
        normal.selectingWithShortcut = false
        XCTAssertEqual(normal.appHighlightPath?.contains(neighbor), false)
        normal.updateHover(at: neighbor)
        XCTAssertEqual(normal.selectedApp, 105)
    }

    @MainActor func testSecondaryPageChangesUseOnlyVisibleItemsAndTheirEdges() async {
        let view = secondaryView(count: 9)
        view.changeWindowPage(1)
        XCTAssertEqual(view.visibleWindows.map(\.id), ["w6", "w7", "w8"])
        let anchor = view.arcAnchor
        for index in 0..<3 {
            view.updateHover(at: RingGeometry.point(angle: RingGeometry.arcAngle(index: index, count: 3, anchor: anchor), radius: 1000))
            XCTAssertEqual(view.currentWindow?.id, "w\(6 + index)")
        }
        view.updateHover(at: RingGeometry.point(angle: anchor + 70 * .pi / 180, radius: 1000))
        XCTAssertEqual(view.selectedApp, 104)
    }

    @MainActor func testHoldSelectionOverCloseButtonSelectsWindowWhileClickStillCloses() async {
        let view = secondaryView()
        let rect = view.closeButtonRect(at: 1)
        let p = CGPoint(x: rect.midX, y: rect.midY)
        var activated: [String] = [], closed: [String] = []
        view.onActivateWindow = { activated.append($0.id) }
        view.onCloseWindow = { closed.append($0.id) }
        view.updateHover(at: p)
        view.activateHovered()
        XCTAssertEqual(activated, ["w1"])
        XCTAssertTrue(closed.isEmpty)
        view.selectingWithShortcut = false
        view.updateHover(at: p)
        view.activateHovered()
        XCTAssertEqual(activated, ["w1"])
        view.activate(at: p)
        XCTAssertEqual(closed, ["w1"])
    }

    @MainActor func testControllerReleasesSelectedTabBeyondPanel() async throws {
        _ = NSApplication.shared
        let saved = Preferences.shared.options
        let ring = RingController(catalog: ApplicationCatalog())
        defer { ring.dismiss(); Preferences.shared.options = saved }
        Preferences.shared.options = Options()
        Preferences.shared.options.holdToSelect = true
        ring.show(actionMode: false)
        ring.view.reset(apps: apps(8), options: Preferences.shared.options)
        ring.view.onSelectApp = nil
        ring.pressShortcut()
        ring.view.updateHover(at: point(6, count: 8, radius: 88))
        let tabs = (0..<4).map { index -> WindowRecord in
            let tab = BrowserTab(bundleID: "com.microsoft.edgemac", windowID: "10", id: String(index),
                title: "Tab \(index)", url: "", windowIndex: 1, index: index + 1, minimized: false)
            return WindowRecord(id: tab.id, pid: 106, title: tab.title, minimized: false, fullscreen: false,
                frame: .zero, element: AXUIElementCreateApplication(106), tab: tab)
        }
        ring.view.setWindows(.ready(tabs), for: 106)
        let p = RingGeometry.point(angle: RingGeometry.arcAngle(index: 3, count: 4, anchor: ring.view.arcAnchor), radius: 2000)
        let window = try XCTUnwrap(ring.view.window)
        ring.updateHeldSelection(at: window.convertPoint(toScreen: ring.view.convert(p, to: nil)))
        XCTAssertEqual(ring.view.currentWindow?.tab?.id, "3")
        var activated: [String] = []
        ring.view.onActivateApp = { _ in XCTFail("Release should select the tab") }
        ring.view.onActivateWindow = { activated.append($0.tab!.id); ring.dismiss() }
        ring.releaseShortcut()
        ring.releaseShortcut()
        XCTAssertEqual(activated, ["3"])
        XCTAssertFalse(ring.isVisible)
    }

    @MainActor func testExpandedHighlightMatchesSecondaryEdges() async throws {
        _ = NSApplication.shared
        let view = secondaryView()
        let angle = RingGeometry.arcAngle(index: 0, count: 4, anchor: view.arcAnchor)
        view.updateHover(at: RingGeometry.point(angle: angle, radius: 2000))
        XCTAssertEqual(view.currentWindow?.id, "w0")
        XCTAssertEqual(view.appHighlightPath?.contains(RingGeometry.point(angle: angle, radius: 88)), true)
    }

    @MainActor func testSelectionUsesCurrentPageAndHandlesEmptyLists() async {
        let view = RingView()
        var options = Options(); options.appPageSize = 4
        view.reset(apps: apps(7), options: options)
        view.selectingWithShortcut = true
        view.changeAppPage(1)
        view.updateHover(at: point(2, count: 3, radius: 1000))
        XCTAssertEqual(view.highlightedApp, 106)
        view.reset(apps: [], options: options)
        view.selectingWithShortcut = true
        view.updateHover(at: point(0, radius: 1000))
        XCTAssertNil(view.highlightedApp)
    }

    @MainActor func testEditingMenusAndDraggingKeepTheirExistingInteraction() async {
        let view = RingView()
        view.reset(apps: apps(), options: Options())
        view.selectingWithShortcut = true
        view.isEditingName = true
        view.updateHover(at: point(0, radius: 1000))
        XCTAssertNil(view.highlightedApp)
        view.isEditingName = false; view.isContextMenuOpen = true
        view.updateHover(at: point(0, radius: 1000))
        XCTAssertNil(view.highlightedApp)
        view.isContextMenuOpen = false
        view.beginPointer(at: point(0, radius: RingGeometry.appRadius))
        view.movePointer(to: point(0, radius: 1000))
        view.updateHover(at: point(1, radius: 1000))
        XCTAssertNil(view.highlightedApp)
        var quit: pid_t?
        view.onQuitApp = { quit = $0.pid }
        view.endPointer(at: point(0, radius: 1000))
        XCTAssertEqual(quit, 100)
    }

    @MainActor func testControllerTracksBeyondPanelAndReleasesExactlyOnce() async throws {
        _ = NSApplication.shared
        let saved = Preferences.shared.options
        let ring = RingController(catalog: ApplicationCatalog())
        defer { ring.dismiss(); Preferences.shared.options = saved }
        Preferences.shared.options = Options()
        Preferences.shared.options.holdToSelect = true
        ring.show(actionMode: false)
        ring.view.reset(apps: apps(), options: Preferences.shared.options)
        ring.view.onSelectApp = nil
        ring.pressShortcut()
        XCTAssertTrue(ring.view.selectingWithShortcut)
        let window = try XCTUnwrap(ring.view.window)
        for index in [0, 3, 5] {
            let screenPoint = window.convertPoint(toScreen: ring.view.convert(point(index, radius: 1000), to: nil))
            ring.updateHeldSelection(at: screenPoint)
            XCTAssertEqual(ring.view.highlightedApp, pid_t(100 + index))
        }
        var activated: [pid_t] = []
        ring.view.onActivateApp = { activated.append($0.pid); ring.dismiss() }
        ring.releaseShortcut()
        ring.releaseShortcut()
        XCTAssertEqual(activated, [105])
        XCTAssertFalse(ring.isVisible)
        XCTAssertFalse(ring.view.selectingWithShortcut)
        let selection = ring.view.highlightedApp
        ring.updateHeldSelection(at: .zero)
        XCTAssertEqual(ring.view.highlightedApp, selection)
        try await Task.sleep(nanoseconds: 180_000_000)
        XCTAssertNil(ring.view.highlightedApp)
    }

    @MainActor func testTrackpadAndClickDoNotKeepHoldSelectionActive() async throws {
        _ = NSApplication.shared
        let saved = Preferences.shared.options
        let ring = RingController(catalog: ApplicationCatalog())
        defer { ring.dismiss(); Preferences.shared.options = saved }
        Preferences.shared.options = Options()
        Preferences.shared.options.holdToSelect = true
        ring.show(fromTrackpad: true, actionMode: false)
        ring.view.reset(apps: apps(), options: Preferences.shared.options)
        ring.view.onSelectApp = nil
        let window = try XCTUnwrap(ring.view.window)
        let outside = window.convertPoint(toScreen: ring.view.convert(point(2, radius: 1000), to: nil))
        ring.updateHeldSelection(at: outside)
        XCTAssertNil(ring.view.highlightedApp)
        ring.releaseShortcut()
        XCTAssertTrue(ring.isVisible)
        ring.pressShortcut()
        ring.updateHeldSelection(at: outside)
        XCTAssertEqual(ring.view.highlightedApp, 102)
        ring.view.beginPointer(at: point(2, radius: RingGeometry.appRadius))
        XCTAssertFalse(ring.view.selectingWithShortcut)
        ring.view.onActivateApp = { _ in XCTFail("Clicking takes over from shortcut release") }
        ring.releaseShortcut()
        XCTAssertTrue(ring.isVisible)
        ring.view.cancelPointerInteraction()
    }
}
