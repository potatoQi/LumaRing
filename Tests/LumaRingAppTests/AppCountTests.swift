import XCTest
import AppKit
@testable import LumaRing

final class AppCountTests: XCTestCase {
    private func app(_ pid: pid_t, bundleID: String = "test.app") -> AppRecord {
        AppRecord(pid: pid, bundleID: bundleID, name: "App \(pid)",
                  icon: NSImage(systemSymbolName: "app.fill", accessibilityDescription: nil)!
                    .withSymbolConfiguration(.init(paletteColors: [.systemBlue]))!)
    }

    private func records(_ count: Int, minimized: Bool = false) -> [WindowRecord] {
        (0..<count).map {
            WindowRecord(id: "test-\($0)", pid: 100, title: "Test \($0)", minimized: minimized,
                         fullscreen: false, frame: CGRect(x: 0, y: 0, width: 600, height: 400),
                         element: AXUIElementCreateApplication(100))
        }
    }

    func testCountsUseTheSameMinimizedFilterAndDoNotInventTotals() {
        let result = WindowResult.ready(records(4) + records(2, minimized: true))
        XCTAssertEqual(AppItemCount(result, includeMinimized: true)?.badge, "6")
        XCTAssertEqual(AppItemCount(result, includeMinimized: false)?.badge, "4")
        XCTAssertNil(AppItemCount(.ready(records(1)), includeMinimized: true)?.badge)
        XCTAssertNil(AppItemCount(.ready([]), includeMinimized: true)?.badge)
        XCTAssertNil(AppItemCount(.permissionRequired, includeMinimized: true))
        XCTAssertNil(AppItemCount(.unavailable("Unavailable"), includeMinimized: true))
        XCTAssertEqual(AppItemCount(.ready(records(4), limited: true), includeMinimized: true)?.badge, "4+")
    }

    @MainActor func testPageCountsAreSerialUseEachAppsModeAndRejectCancelledResults() {
        var pending: [(WindowResult) -> Void] = []
        var requests: [(pid_t, AppContentMode)] = []
        var delivered: [pid_t] = []
        var cancellations = 0
        let service = AppCountService(read: { app, mode, completion in
            requests.append((app.pid, mode)); pending.append(completion)
        }, cancel: { cancellations += 1 })
        var options = Options()
        options.appContentModes["com.google.Chrome"] = .tabs
        service.refresh(apps: [app(100), app(101, bundleID: "com.google.Chrome")], options: options) { pid, count in
            delivered.append(pid); XCTAssertEqual(count?.badge, "4")
        }
        XCTAssertEqual(requests.map(\.0), [100], "Only one count query runs at a time")
        pending[0](.ready(records(4)))
        XCTAssertEqual(requests.map(\.0), [100, 101])
        XCTAssertEqual(requests.map(\.1), [.windows, .tabs])
        // Switching pages invalidates even a late successful result from the previous page.
        service.refresh(apps: [app(102)], options: options) { pid, _ in delivered.append(pid) }
        pending[1](.ready(records(9)))
        XCTAssertEqual(delivered, [100])
        service.cancelAndClear()
        pending[2](.ready(records(4)))
        XCTAssertEqual(delivered, [100], "Dismissal cannot deliver or start more work")
        XCTAssertEqual(cancellations, 3)
    }

    @MainActor func testHoverCountsWinOverPageResultsAndResetClearsCounts() {
        let view = RingView()
        let target = app(100)
        view.reset(apps: [target], options: Options())
        view.setItemCount(AppItemCount(.ready(records(4)), includeMinimized: true), for: 100)
        XCTAssertEqual(view.itemCounts[100]?.badge, "4")
        view.select(target)
        view.setWindows(.ready(records(2)), for: 100)
        view.setItemCount(AppItemCount(.ready(records(9)), includeMinimized: true), for: 100)
        XCTAssertEqual(view.itemCounts[100]?.badge, "2")
        view.setWindows(.unavailable("Closed"), for: 100)
        XCTAssertNil(view.itemCounts[100])
        view.reset(apps: [], options: Options())
        view.setItemCount(AppItemCount(.ready(records(4)), includeMinimized: true), for: 100)
        XCTAssertTrue(view.itemCounts.isEmpty)
    }

    @MainActor func testPageChangeRequestsCountsForOnlyTheNewPage() {
        let view = RingView()
        var options = Options(); options.appPageSize = 4
        view.reset(apps: (100..<106).map { app(pid_t($0)) }, options: options)
        view.select(view.apps[0])
        view.setWindows(.ready(records(2)), for: 100)
        var requested: [pid_t] = []
        view.onVisibleAppsChanged = { requested = view.visibleApps.map(\.pid) }
        view.changeAppPage(1)
        XCTAssertEqual(requested, [104, 105])
        view.setItemCount(AppItemCount(.ready(records(4)), includeMinimized: true), for: 100)
        XCTAssertEqual(view.itemCounts[100]?.badge, "2", "An off-page response must not replace the cached count")
        view.changeAppPage(-1)
        view.setItemCount(AppItemCount(.ready(records(4)), includeMinimized: true), for: 100)
        XCTAssertEqual(view.itemCounts[100]?.badge, "4", "Returning to a page permits a fresh count")
    }

    @MainActor func testBadgeDrawingAndAccessibilityInBothAppearances() throws {
        _ = NSApplication.shared
        for count in [12, 24] {
            for appearance in [NSAppearance.Name.aqua, .darkAqua] {
                let view = RingView(frame: NSRect(x: 0, y: 0, width: 480, height: 480))
                let host = NSWindow(contentRect: view.frame, styleMask: .borderless, backing: .buffered, defer: false)
                host.contentView = view
                view.appearance = NSAppearance(named: appearance)
                var options = Options(); options.appPageSize = count
                view.reset(apps: (100..<(100 + count)).map { app(pid_t($0)) }, options: options)
                for (index, app) in view.apps.enumerated() {
                    let value = [1, 4, 12, 128][index % 4]
                    view.setItemCount(AppItemCount(.ready(records(value)), includeMinimized: true), for: app.pid)
                }
                view.layoutSubtreeIfNeeded()
                let labels = (view.accessibilityChildren() as? [NSAccessibilityElement])?.compactMap { $0.accessibilityLabel() } ?? []
                XCTAssertTrue(labels.contains { $0.contains("App 101, 4") })
                XCTAssertTrue(labels.contains("App 100"), "A single window has no badge")
                if let directory = ProcessInfo.processInfo.environment["LUMARING_SNAPSHOT_DIR"] {
                    try FileManager.default.createDirectory(atPath: directory, withIntermediateDirectories: true)
                    let bitmap = try XCTUnwrap(view.bitmapImageRepForCachingDisplay(in: view.bounds))
                    view.cacheDisplay(in: view.bounds, to: bitmap)
                    try XCTUnwrap(bitmap.representation(using: .png, properties: [:])).write(
                        to: URL(fileURLWithPath: directory).appendingPathComponent("badges-\(count)-\(appearance.rawValue).png"))
                }
            }
        }
    }
}
