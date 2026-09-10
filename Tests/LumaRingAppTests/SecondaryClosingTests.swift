import AppKit
import XCTest
import LumaRingCore
@testable import LumaRing

final class SecondaryClosingTests: XCTestCase {
    @MainActor private func makeView(count: Int, tabs: Bool = false) -> RingView {
        let view = RingView(frame: NSRect(x: 0, y: 0, width: 480, height: 480))
        let app = AppRecord(pid: 100, bundleID: "com.google.Chrome", name: "Chrome", icon: NSImage())
        var options = Options(); options.appContentModes[app.bundleID] = tabs ? .tabs : .windows
        view.reset(apps: [app], options: options); view.select(app)
        view.setWindows(.ready((0..<count).map {
            WindowRecord(id: "item-\($0)", pid: 100, title: "Item \($0)", minimized: false, fullscreen: false,
                frame: .zero, element: AXUIElementCreateApplication(100), tab: tabs ? BrowserTab(bundleID: app.bundleID,
                    windowID: "1", id: "\($0)", title: "Item \($0)", url: "about:blank", windowIndex: 1, index: $0 + 1, minimized: false) : nil)
        }), for: app.pid)
        return view
    }

    @MainActor func testSequentialWindowAndTabClosesKeepLastItemAccessible() {
        for tabs in [false, true] {
            let view = makeView(count: 3, tabs: tabs)
            var closed: [String] = []
            view.onClose = { XCTFail("Closing a secondary item must not dismiss the ring") }
            view.onActivateApp = { _ in XCTFail("Close must not activate") }
            view.onActivateWindow = { _ in XCTFail("Close must not activate") }
            view.onCloseWindow = { record in closed.append(record.id); view.removeClosedWindow(record) }
            while !view.windows.isEmpty {
                XCTAssertTrue(view.showsWindowArc)
                let button = view.closeButtonRect(at: 0)
                let point = CGPoint(x: button.midX, y: button.midY)
                view.beginPointer(at: point); view.endPointer(at: point)
                XCTAssertEqual(view.selectedApp, 100)
                XCTAssertEqual(view.apps.count, 1)
                XCTAssertEqual(view.itemCounts[100]?.value, view.windows.count)
            }
            XCTAssertEqual(closed, ["item-0", "item-1", "item-2"])
            XCTAssertFalse(view.showsWindowArc)
        }
    }

    @MainActor func testCloseOnFinalPageClampsPageAndClearsPreview() {
        let view = makeView(count: 7)
        view.windowPage = 1
        let record = view.visibleWindows[0]
        view.hoveredWindow = record.id
        var cleared = false
        view.onHoverWindow = { if $0 == nil { cleared = true } }
        view.removeClosedWindow(record)
        XCTAssertEqual(view.windowPage, 0)
        XCTAssertEqual(view.visibleWindows.count, 6)
        XCTAssertNil(view.hoveredWindow); XCTAssertTrue(cleared)
        // An authoritative result also clamps after unrelated external closes.
        view.windowPage = 5
        view.setWindows(.ready(Array(view.windows.prefix(2))), for: 100)
        XCTAssertEqual(view.windowPage, 0)
    }

    @MainActor func testEarlierCompletionDoesNotCancelPressOnAnotherItem() {
        let view = makeView(count: 3)
        let closing = view.windows[0], next = view.windows[1]
        let button = view.closeButtonRect(at: 1)
        view.beginPointer(at: CGPoint(x: button.midX, y: button.midY))
        view.removeClosedWindow(closing)
        XCTAssertTrue(view.isPointerDown)
        var closed: String?
        view.onCloseWindow = { closed = $0.id }
        let movedButton = view.closeButtonRect(at: 0)
        view.endPointer(at: CGPoint(x: movedButton.midX, y: movedButton.midY))
        XCTAssertEqual(closed, next.id)
    }

    @MainActor func testCancelledCloseCanRestoreWindowAndNewSelectionResetsSingleArc() {
        let view = makeView(count: 2)
        let before = view.windows
        view.removeClosedWindow(before[0])
        XCTAssertTrue(view.showsWindowArc)
        // AXPress may open a save dialog; reconciliation restores an unclosed item.
        view.setWindows(.ready(before), for: 100)
        XCTAssertEqual(view.windows.map(\.id), before.map(\.id))
        let other = AppRecord(pid: 101, bundleID: "test.other", name: "Other", icon: NSImage())
        view.apps.append(other); view.select(other)
        view.setWindows(.ready([WindowRecord(id: "other", pid: 101, title: "Other", minimized: false,
            fullscreen: false, frame: .zero, element: AXUIElementCreateApplication(101))]), for: 101)
        view.removeClosedWindow(before[0])
        XCTAssertEqual(view.windows.map(\.id), ["other"])
        XCTAssertFalse(view.showsWindowArc)
    }
}
