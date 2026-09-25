import AppKit
import XCTest
@testable import LumaRing

final class RingAccessibilityTests: XCTestCase {
    @MainActor func testUnusedPreviewDoesNotAllocateAWindow() {
        let preview = WindowPreview()
        XCTAssertNil(preview.view.window)
        preview.dismiss()
        XCTAssertNil(preview.view.window)
    }

    @MainActor func testRefreshReusesIdentityButUpdatesLabelsFramesAndActions() throws {
        let view = NSView(frame: CGRect(x: 0, y: 0, width: 480, height: 480))
        let host = NSWindow(contentRect: view.frame, styleMask: .borderless, backing: .buffered, defer: false)
        host.contentView = view
        defer { host.contentView = nil }
        let tree = RingAccessibility()
        var invoked = ""
        tree.update([.init(id: "window", label: "Original", rect: .zero) { invoked = "old" }], in: view)
        let original = try XCTUnwrap(view.accessibilityChildren()?.first as? RingAccessibleItem)
        let rect = CGRect(x: 20, y: 30, width: 40, height: 50)
        tree.update([.init(id: "window", label: "Renamed", help: "Updated", rect: rect) { invoked = "new" }], in: view)
        XCTAssertTrue(original === view.accessibilityChildren()?.first as? RingAccessibleItem)
        XCTAssertEqual(original.accessibilityLabel(), "Renamed")
        XCTAssertEqual(original.accessibilityHelp(), "Updated")
        XCTAssertEqual(original.accessibilityFrame(), host.convertToScreen(view.convert(rect, to: nil)))
        XCTAssertTrue(original.accessibilityPerformPress())
        XCTAssertEqual(invoked, "new")
        tree.update([], in: view)
        XCTAssertFalse(original.accessibilityPerformPress(), "Removed targets cannot run stale callbacks")
        XCTAssertNil(original.action)
        XCTAssertNil(original.accessibilityParent())
    }

    @MainActor func testActionSelectionKeepsTargetsAndPagingInvalidatesOldPage() throws {
        let view = ActionRingView(frame: CGRect(x: 0, y: 0, width: 480, height: 480))
        let host = NSWindow(contentRect: view.frame, styleMask: .borderless, backing: .buffered, defer: false)
        host.contentView = view
        defer { host.contentView = nil }
        view.actions = (0..<8).map { AppAction(id: "a\($0)", name: "Action \($0)", shortcut: Shortcut()) }
        view.ready = true
        view.refresh()
        let original = try XCTUnwrap(view.accessibilityChildren()?.first as? RingAccessibleItem)
        for _ in 0..<6 { view.navigate(.step(1)) }
        XCTAssertTrue(original === view.accessibilityChildren()?.first as? RingAccessibleItem)
        XCTAssertEqual(view.hover, "a5")
        view.navigate(.step(1))
        XCTAssertFalse(original.accessibilityPerformPress())
        let next = try XCTUnwrap(view.accessibilityChildren()?.first as? RingAccessibleItem)
        var invoked: String?
        view.onAction = { invoked = $0.id }
        XCTAssertTrue(next.accessibilityPerformPress())
        XCTAssertEqual(invoked, "a6")
        view.ready = false; view.refresh()
        XCTAssertFalse(next.accessibilityPerformPress(), "Unavailable actions remain disabled after reuse")
        view.ready = true; view.actions = []; view.reset()
        XCTAssertFalse(next.accessibilityPerformPress())
    }

    @MainActor func testGlobalRingKeepsAppIdentityWhenCountsChange() throws {
        let view = RingView(frame: CGRect(x: 0, y: 0, width: 480, height: 480))
        let host = NSWindow(contentRect: view.frame, styleMask: .borderless, backing: .buffered, defer: false)
        host.contentView = view
        defer { host.contentView = nil }
        let app = AppRecord(pid: 99999, bundleID: "test.app", name: "Test App", icon: NSImage())
        view.reset(apps: [app], options: Options())
        let original = try XCTUnwrap(view.accessibilityChildren()?.first as? RingAccessibleItem)
        view.setItemCount(.init(value: 4, limited: false), for: app.pid)
        XCTAssertTrue(original === view.accessibilityChildren()?.first as? RingAccessibleItem)
        XCTAssertTrue(original.accessibilityLabel()?.contains("4") == true)
        var selected: pid_t?
        view.onSelectApp = { selected = $0.pid }
        XCTAssertTrue(original.accessibilityPerformPress())
        XCTAssertEqual(selected, app.pid)
        view.reset(apps: [], options: Options())
        XCTAssertFalse(original.accessibilityPerformPress())
    }
}
