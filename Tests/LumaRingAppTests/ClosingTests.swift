import XCTest
import AppKit
import Carbon
import LumaRingCore
@testable import LumaRing

final class ClosingTests: XCTestCase {
    private let app = AppRecord(pid: 100, bundleID: "test.app", name: "Test App", icon: NSImage(systemSymbolName: "app.fill", accessibilityDescription: nil)!)
    private var appPoint: CGPoint { RingGeometry.point(angle: .pi / 2, radius: RingGeometry.appRadius) }
    private var outside: CGPoint { RingGeometry.point(angle: .pi / 2, radius: 175) }
    private func records(_ count: Int = 3) -> [WindowRecord] {
        (0..<count).map { WindowRecord(id: "window-\($0)", pid: 100, title: "Window \($0)", minimized: false,
                                     fullscreen: false, frame: .zero, element: AXUIElementCreateApplication(100)) }
    }
    @MainActor private func view(_ count: Int = 3) -> RingView {
        let view = RingView(frame: NSRect(x: 0, y: 0, width: 480, height: 480))
        view.reset(apps: [app], options: Options())
        view.select(app); view.setWindows(.ready(records(count)), for: app.pid)
        return view
    }
    @MainActor func testClickWaitsForMouseUpAndKeepsSingleWindowActivation() async {
        let view = view(1)
        var activated: [String] = []
        view.onActivateWindow = { activated.append($0.id) }
        view.onQuitApp = { _ in XCTFail("Ordinary click must not quit") }
        view.beginPointer(at: appPoint)
        XCTAssertTrue(activated.isEmpty)
        view.endPointer(at: CGPoint(x: appPoint.x + 2, y: appPoint.y))
        XCTAssertEqual(activated, ["window-0"])
    }
    @MainActor func testDragOutQuitsOnlyAfterReleaseAndNeverActivates() async {
        let view = view()
        var quits: [pid_t] = []
        view.onQuitApp = { quits.append($0.pid) }
        view.onActivateApp = { _ in XCTFail("Drag must not activate") }
        view.onActivateWindow = { _ in XCTFail("Drag must not activate") }
        view.beginPointer(at: appPoint)
        view.movePointer(to: outside)
        XCTAssertTrue(view.isDraggingApp); XCTAssertTrue(view.dragWillQuit)
        XCTAssertFalse(view.showsWindowArc)
        XCTAssertTrue(quits.isEmpty)
        view.activateHovered() // Releasing the invocation shortcut during a drag.
        view.endPointer(at: outside)
        view.endPointer(at: outside)
        XCTAssertEqual(quits, [100])
        XCTAssertFalse(view.isPointerDown)
    }
    @MainActor func testDragBackIntoRingCancelsWithoutActivating() async {
        let view = view()
        view.onQuitApp = { _ in XCTFail("Returning to the ring cancels") }
        view.onActivateApp = { _ in XCTFail("Cancelled drag is not a click") }
        view.beginPointer(at: appPoint); view.movePointer(to: outside)
        view.movePointer(to: appPoint)
        XCTAssertFalse(view.dragWillQuit)
        view.endPointer(at: appPoint)
        XCTAssertTrue(view.showsWindowArc)
    }
    @MainActor func testDragMustStartOnIconAndClearTheOuterMargin() async {
        let view = view()
        view.onQuitApp = { _ in XCTFail("No intentional outward icon drag") }
        view.beginPointer(at: RingGeometry.point(angle: .pi / 2, radius: 62))
        view.movePointer(to: outside); view.endPointer(at: outside)
        view.beginPointer(at: appPoint)
        let edge = RingGeometry.point(angle: .pi / 2, radius: RingGeometry.appOuter + 10)
        view.movePointer(to: edge); view.endPointer(at: edge)
    }
    @MainActor func testResetAndRemovedAppCancelPendingDrag() async {
        let view = view()
        view.onQuitApp = { _ in XCTFail("Stale drag must not quit") }
        view.beginPointer(at: appPoint); view.movePointer(to: outside)
        view.reset(apps: [app], options: Options())
        view.endPointer(at: outside)
        XCTAssertFalse(view.isDraggingApp)
        view.beginPointer(at: appPoint); view.movePointer(to: outside)
        view.apps = []
        view.endPointer(at: outside)
    }
    @MainActor func testCloseClickUsesExactItemAndDoesNotSwitchOnShortcutRelease() async {
        let view = view()
        let rect = view.closeButtonRect(at: 1), point = CGPoint(x: rect.midX, y: rect.midY)
        var closed: [String] = []
        view.onCloseWindow = { closed.append($0.id) }
        view.onActivateWindow = { _ in XCTFail("Close must not activate") }
        view.onActivateApp = { _ in XCTFail("Close must not activate") }
        view.updateHover(at: point); view.activateHovered()
        view.beginPointer(at: point); view.activateHovered()
        XCTAssertTrue(closed.isEmpty)
        view.endPointer(at: point)
        XCTAssertEqual(closed, ["window-1"])
    }
    @MainActor func testCloseDragAwayAndChangedItemCancel() async {
        let view = view()
        let rect = view.closeButtonRect(at: 1), point = CGPoint(x: rect.midX, y: rect.midY)
        view.onCloseWindow = { _ in XCTFail("Cancelled close must not close anything") }
        view.onActivateWindow = { _ in XCTFail("Cancelled close must not switch") }
        view.beginPointer(at: point); view.endPointer(at: RingGeometry.center)
        view.beginPointer(at: point)
        view.windows.swapAt(0, 1)
        view.endPointer(at: point)
    }
    @MainActor func testWindowClickDoesNotTurnIntoCloseOnMouseUp() async {
        let view = view()
        let center = RingGeometry.point(angle: .pi / 2, radius: RingGeometry.windowRadius)
        let rect = view.closeButtonRect(at: 1)
        view.onCloseWindow = { _ in XCTFail("Must press the close button first") }
        view.onActivateWindow = { _ in XCTFail("Moving into close button cancels selection") }
        view.beginPointer(at: center); view.endPointer(at: CGPoint(x: rect.midX, y: rect.midY))
    }
    @MainActor func testCloseButtonsHitCorrectTargetsAcrossAllArcAnchors() async {
        let view = view(8)
        let apps = (0..<24).map { AppRecord(pid: pid_t(100 + $0), bundleID: "test.\($0)", name: "App", icon: app.icon) }
        var options = Options(); options.appPageSize = 24; options.windowPageSize = 8
        view.reset(apps: apps, options: options)
        for app in apps {
            view.select(app)
            view.setWindows(.ready(records(8)), for: app.pid)
            for (index, record) in view.visibleWindows.enumerated() {
                var closed: String?
                view.onCloseWindow = { closed = $0.id }
                let rect = view.closeButtonRect(at: index)
                let point = CGPoint(x: rect.midX, y: rect.midY)
                view.activate(at: point)
                XCTAssertEqual(closed, record.id)
            }
        }
    }
    @MainActor func testLateWindowResultCannotTurnBackgroundPressIntoClose() async {
        let view = view()
        let rect = view.closeButtonRect(at: 1), point = CGPoint(x: rect.midX, y: rect.midY)
        view.windows = []
        view.beginPointer(at: point)
        view.setWindows(.ready(records()), for: app.pid)
        view.onCloseWindow = { _ in XCTFail("No close button existed on mouse-down") }
        view.onActivateWindow = { _ in XCTFail("No window existed on mouse-down") }
        view.endPointer(at: point)
    }
    @MainActor func testEscapeCancelsDragAndLaterMouseUp() async {
        let view = view()
        view.onQuitApp = { _ in XCTFail("Escape cancels quit") }
        view.beginPointer(at: appPoint); view.movePointer(to: outside)
        view.keyDown(with: NSEvent.keyEvent(with: .keyDown, location: .zero, modifierFlags: [], timestamp: 0,
            windowNumber: 0, context: nil, characters: "", charactersIgnoringModifiers: "", isARepeat: false, keyCode: 53)!)
        XCTAssertFalse(view.isPointerDown)
        view.endPointer(at: outside)
    }
    @MainActor func testRenderCloseHoverAndDragFeedback() async throws {
        guard let directory = ProcessInfo.processInfo.environment["LUMARING_SNAPSHOT_DIR"] else { return }
        _ = NSApplication.shared
        let view = view()
        let panel = NSWindow(contentRect: view.frame, styleMask: .borderless, backing: .buffered, defer: false)
        panel.contentView = view
        view.appearance = NSAppearance(named: .aqua)
        for dragging in [false, true] {
            if dragging { view.beginPointer(at: appPoint); view.movePointer(to: outside) }
            else {
                let rect = view.closeButtonRect(at: 1)
                view.updateHover(at: CGPoint(x: rect.midX, y: rect.midY))
            }
            view.layoutSubtreeIfNeeded()
            let bitmap = try XCTUnwrap(view.bitmapImageRepForCachingDisplay(in: view.bounds))
            view.cacheDisplay(in: view.bounds, to: bitmap)
            let data = try XCTUnwrap(bitmap.representation(using: .png, properties: [:]))
            try FileManager.default.createDirectory(atPath: directory, withIntermediateDirectories: true)
            try data.write(to: URL(fileURLWithPath: directory).appendingPathComponent(dragging ? "drag-to-quit.png" : "close-hover.png"))
        }
        view.cancelPointerInteraction()
    }
    func testWindowCloseRequiresOwnEnabledCloseButton() {
        let record = records(1)[0]
        let button = AXUIElementCreateApplication(100)
        var presses = 0
        for enabled in [false, true] {
            var reads = 0
            let result = WindowService.requestClose(record, read: { _, attribute in
                reads += 1
                switch attribute {
                case kAXRoleAttribute: return (reads == 1 ? kAXWindowRole : kAXButtonRole) as CFString
                case kAXCloseButtonAttribute: return button
                case kAXEnabledAttribute: return enabled ? kCFBooleanTrue : kCFBooleanFalse
                default: return nil
                }
            }, press: { _ in presses += 1; return true })
            XCTAssertEqual(result, enabled)
        }
        XCTAssertEqual(presses, 1)
    }
    func testWindowCloseRejectsStaleOrForeignElementsAndMissingButton() {
        var record = records(1)[0]
        let wrong = WindowRecord(id: record.id, pid: 101, title: record.title, minimized: false, fullscreen: false,
                                 frame: .zero, element: record.element)
        XCTAssertFalse(WindowService.requestClose(wrong, read: { _, _ in XCTFail("Wrong owner"); return nil }, press: { _ in XCTFail(); return true }))
        XCTAssertFalse(WindowService.requestClose(record, read: { _, _ in nil }, press: { _ in XCTFail(); return true }))
        XCTAssertFalse(WindowService.requestClose(record, read: { _, attribute in
            if attribute == kAXRoleAttribute { return kAXWindowRole as CFString }
            return AXUIElementCreateApplication(101)
        }, press: { _ in XCTFail("Foreign button"); return true }))
        record.tab = BrowserTab(bundleID: "com.google.Chrome", windowID: "10", id: "1", title: "", url: "", windowIndex: 1, index: 1, minimized: false)
        XCTAssertFalse(WindowService.requestClose(record, read: { _, _ in XCTFail("Tabs must use scripting"); return nil }, press: { _ in XCTFail(); return true }))
    }
}
