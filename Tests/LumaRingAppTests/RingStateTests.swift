import XCTest
import AppKit
import LumaRingCore
@testable import LumaRing

final class RingStateTests: XCTestCase {
    private func apps(_ count: Int) -> [AppRecord] {
        (0..<count).map { AppRecord(pid: pid_t($0 + 100), bundleID: "test.\($0)", name: "App \($0)",
                                   icon: NSImage(systemSymbolName: "app.fill", accessibilityDescription: nil)!) }
    }
    private func windows(_ count: Int, pid: pid_t = 100) -> [WindowRecord] {
        (0..<count).map { WindowRecord(id: "window-\($0)", pid: pid, title: ["项目周报 — 产品设计", "首页 — LumaRing", "灵感收集", "界面调整记录"][$0 % 4], minimized: $0 == 2,
                                       fullscreen: false, frame: CGRect(x: 0, y: 0, width: 600, height: 400),
                                       element: AXUIElementCreateApplication(pid)) }
    }
    private func key(_ code: UInt16, text: String = "", flags: NSEvent.ModifierFlags = []) -> NSEvent {
        NSEvent.keyEvent(with: .keyDown, location: .zero, modifierFlags: flags, timestamp: 0,
                        windowNumber: 0, context: nil, characters: text,
                        charactersIgnoringModifiers: text, isARepeat: false, keyCode: code)!
    }
    private func appPoint(_ index: Int, count: Int) -> CGPoint {
        RingGeometry.point(angle: RingGeometry.angle(index: index, count: count), radius: RingGeometry.appRadius)
    }
    private func windowPoint(_ index: Int, count: Int, anchor: Double = .pi / 2) -> CGPoint {
        RingGeometry.point(angle: RingGeometry.arcAngle(index: index, count: count, anchor: anchor), radius: RingGeometry.windowRadius)
    }

    func testNewDefaultsAndLegacySettingsDecode() throws {
        let defaults = Options()
        XCTAssertFalse(defaults.holdToSelect)
        XCTAssertEqual(defaults.ringSize, 520)
        XCTAssertEqual(defaults.shortcut.display, "⌥Tab")
        XCTAssertEqual(defaults.previewSize, CGSize(width: 840, height: 630))
        XCTAssertTrue(defaults.sortByName)
        XCTAssertEqual(defaults.appPageSize, 12)
        XCTAssertEqual(defaults.windowPageSize, 6)
        let legacy = Data(#"{"shortcut":{"keyCode":15,"modifiers":6144,"label":"R"},"hoverDelay":0.5,"ringSize":500,"showAppNames":true,"reduceMotion":true,"excludedBundleIDs":["local.hidden"]}"#.utf8)
        let decoded = try JSONDecoder().decode(Options.self, from: legacy)
        XCTAssertEqual(decoded.shortcut.keyCode, 15)
        XCTAssertEqual(decoded.ringSize, 500)
        XCTAssertEqual(decoded.excludedBundleIDs, ["local.hidden"])
        XCTAssertEqual(decoded.appPageSize, 12)
        XCTAssertEqual(decoded.windowPageSize, 6)
        XCTAssertEqual(decoded.previewWidth, 840)
        let enlarged = try JSONDecoder().decode(Options.self, from: Data(#"{"previewWidth":960}"#.utf8))
        XCTAssertEqual(enlarged.previewSize, CGSize(width: 960, height: 720))
        let clamped = try JSONDecoder().decode(Options.self, from: Data(#"{"previewWidth":9999}"#.utf8))
        XCTAssertEqual(clamped.previewWidth, 960)
        let encoded = String(decoding: try JSONEncoder().encode(decoded), as: UTF8.self)
        XCTAssertFalse(encoded.contains("showAppNames")); XCTAssertFalse(encoded.contains("reduceMotion"))
        XCTAssertFalse(encoded.contains("hoverDelay"))
    }

    @MainActor func testShortcutRecorderAccessiblePressAndCancel() async {
        let button = RecorderButton()
        button.savedTitle = "⌃⌥Space"
        XCTAssertTrue(button.accessibilityPerformPress())
        XCTAssertTrue(button.recording)
        button.keyDown(with: key(53))
        XCTAssertFalse(button.recording)
        XCTAssertEqual(button.title, button.savedTitle)
        button.performClick(nil)
        var recorded: Shortcut?
        button.onRecord = { recorded = $0 }
        button.keyDown(with: key(15, text: "r", flags: [.control, .option]))
        XCTAssertEqual(recorded?.keyCode, 15)
    }

    @MainActor func testLateResultsCannotReplaceSelectedApp() async {
        let view = RingView()
        let applications = apps(2)
        view.reset(apps: applications, options: Options())
        view.select(applications[0]); view.select(applications[1])
        view.setWindows(.ready(windows(3)), for: 100)
        XCTAssertTrue(view.windows.isEmpty)
        XCTAssertTrue(view.loading)
        view.setWindows(.ready(windows(2, pid: 101)), for: 101)
        XCTAssertEqual(view.windows.count, 2)
        XCTAssertFalse(view.loading)
    }

    @MainActor func testConfigurablePagesPreserveAllApplications() async {
        let view = RingView()
        let applications = apps(37)
        for size in [6, 8, 12, 16, 24] {
            var options = Options(); options.appPageSize = size
            view.reset(apps: applications, options: options)
            var seen: [pid_t] = []
            for _ in 0..<RingGeometry.pageCount(total: 37, size: size) {
                XCTAssertLessThanOrEqual(view.visibleApps.count, size)
                seen += view.visibleApps.map(\.pid)
                view.changeAppPage(1)
            }
            XCTAssertEqual(seen, applications.map(\.pid))
            XCTAssertEqual(view.appPage, 0)
        }
    }

    func testWindowPageSizePersistsAndClampsInvalidValues() throws {
        for size in RingGeometry.windowPageSizeRange {
            var options = Options(); options.windowPageSize = size
            let decoded = try JSONDecoder().decode(Options.self, from: JSONEncoder().encode(options))
            XCTAssertEqual(decoded.windowPageSize, size)
        }
        for (stored, expected) in [(-10, 2), (0, 2), (999, 8)] {
            let decoded = try JSONDecoder().decode(Options.self, from: Data("{\"windowPageSize\":\(stored)}".utf8))
            XCTAssertEqual(decoded.windowPageSize, expected)
        }
    }

    @MainActor func testConfigurableWindowPagesPreserveTargetsAndWrap() async {
        let view = RingView()
        let applications = apps(1)
        let records = windows(19)
        for size in RingGeometry.windowPageSizeRange {
            var options = Options(); options.windowPageSize = size
            view.reset(apps: applications, options: options)
            view.select(applications[0]); view.setWindows(.ready(records), for: 100)
            var seen: [String] = []
            for _ in 0..<RingGeometry.pageCount(total: records.count, size: size) {
                let visible = view.visibleWindows
                XCTAssertLessThanOrEqual(visible.count, size)
                seen += visible.map(\.id)
                var activated: String?
                view.onActivateWindow = { activated = $0.id }
                view.updateHover(at: windowPoint(visible.count - 1, count: visible.count))
                view.activateHovered()
                XCTAssertEqual(activated, visible.last?.id)
                view.changeWindowPage(1)
                XCTAssertNil(view.hoveredWindow)
            }
            XCTAssertEqual(seen, records.map(\.id))
            XCTAssertEqual(view.windowPage, 0)
            view.changeWindowPage(-1)
            XCTAssertEqual(view.visibleWindows.last?.id, records.last?.id)
        }
    }

    @MainActor func testMouseWindowPagingAndReleaseActivatesExactTarget() async {
        let view = RingView()
        let applications = apps(8)
        var options = Options(); options.windowPageSize = 4
        view.reset(apps: applications, options: options)
        view.select(applications[0]); view.setWindows(.ready(windows(10)), for: 100)
        view.changeWindowPage(1); view.changeWindowPage(1)
        XCTAssertEqual(view.visibleWindows.count, 2)
        view.updateHover(at: windowPoint(1, count: 2))
        var target: String?
        view.onActivateWindow = { target = $0.id }
        view.activateHovered()
        XCTAssertEqual(target, "window-9")
    }

    @MainActor func testReleaseBeforeHoverDelayUsesCurrentPointerNotOldSelection() async {
        let view = RingView()
        let applications = apps(8)
        view.reset(apps: applications, options: Options())
        view.select(applications[0]); view.setWindows(.ready(windows(1)), for: 100)
        view.updateHover(at: appPoint(1, count: 8))
        var activated: pid_t?
        view.onActivateApp = { activated = $0.pid }
        view.onActivateWindow = { activated = $0.pid }
        view.activateHovered()
        XCTAssertEqual(activated, 101)
        var closed = false
        view.onClose = { closed = true }
        view.updateHover(at: RingGeometry.center)
        activated = nil
        view.activateHovered()
        XCTAssertNil(activated)
        XCTAssertTrue(closed)
        view.cancelHover()
    }

    @MainActor func testRemovedKeysDoNotChangeOrActivateSelection() async {
        let view = RingView()
        let applications = apps(12)
        view.reset(apps: applications, options: Options())
        view.select(applications[0])
        var triggered = false
        view.onClose = { triggered = true }; view.onActivateApp = { _ in triggered = true }
        for code: UInt16 in [48, 49, 36, 53, 123, 124, 125, 126, 116, 121, 0, 18] {
            view.keyDown(with: key(code, text: code == 18 ? "1" : "a"))
        }
        XCTAssertEqual(view.selectedApp, 100)
        XCTAssertEqual(view.appPage, 0)
        XCTAssertEqual(view.visibleApps.count, 12)
        XCTAssertFalse(triggered)
    }

    @MainActor func testPageChangeRejectsOldWindowResultAndCancelsPreview() async {
        let view = RingView()
        let applications = apps(25)
        view.reset(apps: applications, options: Options())
        view.select(applications[0]); view.setWindows(.ready(windows(3)), for: 100)
        view.updateHover(at: windowPoint(0, count: 3))
        var cleared = false
        view.onHoverWindow = { if $0 == nil { cleared = true } }
        view.changeAppPage(1)
        view.setWindows(.ready(windows(4)), for: 100)
        XCTAssertNil(view.selectedApp); XCTAssertNil(view.hoveredWindow)
        XCTAssertTrue(view.windows.isEmpty); XCTAssertFalse(view.loading)
        XCTAssertTrue(cleared)
    }

    @MainActor func testMinimizedFilterAndDeniedPermissionFallback() async {
        let view = RingView()
        var options = Options(); options.includeMinimized = false
        let applications = apps(1)
        view.reset(apps: applications, options: options)
        view.select(applications[0]); view.setWindows(.ready(windows(4)), for: 100)
        XCTAssertEqual(view.windows.count, 3)
        view.setWindows(.permissionRequired, for: 100)
        XCTAssertTrue(view.windows.isEmpty)
        var activated: pid_t?
        view.onActivateApp = { activated = $0.pid }
        view.activate(at: appPoint(0, count: 1))
        XCTAssertEqual(activated, 100)
    }

    @MainActor func testResetClearsWindowsAndAdjacentPreview() async {
        let view = RingView()
        let applications = apps(1)
        view.reset(apps: applications, options: Options())
        view.select(applications[0]); view.setWindows(.ready(windows(10)), for: 100)
        view.updateHover(at: windowPoint(0, count: view.visibleWindows.count))
        var cleared = false
        view.onHoverWindow = { if $0 == nil { cleared = true } }
        view.reset(apps: [], options: Options())
        XCTAssertTrue(view.windows.isEmpty); XCTAssertTrue(view.apps.isEmpty)
        XCTAssertNil(view.hoveredWindow); XCTAssertNil(view.selectedApp)
        XCTAssertTrue(cleared)
    }

    @MainActor func testSingleWindowNeverExpandsAndClickRestoresIt() async {
        let view = RingView()
        let applications = apps(2)
        view.reset(apps: applications, options: Options())
        view.select(applications[0]); view.setWindows(.ready(windows(1)), for: 100)
        XCTAssertFalse(view.showsWindowArc); XCTAssertTrue(view.visibleWindows.isEmpty)
        var target: String?
        view.onActivateWindow = { target = $0.id }
        view.activate(at: appPoint(0, count: 2))
        XCTAssertEqual(target, "window-0")
    }

    @MainActor func testImmediateHoverAttachedArcAndCollapse() async {
        let view = RingView()
        view.reset(apps: apps(8), options: Options())
        var queries = 0
        view.onSelectApp = { [weak view] app in
            queries += 1
            view?.setWindows(.ready(self.windows(3, pid: app.pid)), for: app.pid)
        }
        view.updateHover(at: appPoint(0, count: 8))
        XCTAssertEqual(view.selectedApp, 100)
        XCTAssertEqual(queries, 1)
        XCTAssertTrue(view.showsWindowArc)
        view.updateHover(at: appPoint(0, count: 8))
        XCTAssertEqual(queries, 1, "Moving within the same app must not repeat the query")
        view.updateHover(at: RingGeometry.point(angle: .pi / 2, radius: 119))
        try? await Task.sleep(nanoseconds: 240_000_000)
        XCTAssertTrue(view.showsWindowArc)
        view.updateHover(at: RingGeometry.center)
        try? await Task.sleep(nanoseconds: 240_000_000)
        XCTAssertFalse(view.showsWindowArc)
    }

    @MainActor func testNearCenterSectorHoverAndClickDoNotRequireReachingIcon() async {
        let view = RingView()
        let applications = apps(6)
        view.reset(apps: applications, options: Options())
        for (i, app) in applications.enumerated() {
            let point = RingGeometry.point(angle: RingGeometry.angle(index: i, count: 6) + 0.35,
                                           radius: RingGeometry.appInner + 2)
            view.updateHover(at: point)
            XCTAssertEqual(view.selectedApp, app.pid)
            XCTAssertEqual(view.highlightedApp, app.pid)
            var activated: pid_t?
            view.onActivateApp = { activated = $0.pid }
            view.beginPointer(at: point); view.endPointer(at: point)
            XCTAssertEqual(activated, app.pid)
        }
        view.updateHover(at: RingGeometry.center)
        XCTAssertNil(view.highlightedApp, "Neutral center clears the highlight immediately")
        var activated = false
        view.onActivateApp = { _ in activated = true }
        view.activateHovered()
        XCTAssertFalse(activated)
        view.cancelHover()
    }

    @MainActor func testPrimaryDiskBoundaryDoesNotActivateASecondaryWindow() async {
        let view = RingView()
        let applications = apps(6)
        view.reset(apps: applications, options: Options())
        view.select(applications[0]); view.setWindows(.ready(windows(3)), for: applications[0].pid)
        let point = RingGeometry.point(angle: .pi / 2, radius: RingGeometry.appOuter)
        var activated: pid_t?
        view.onActivateApp = { activated = $0.pid }
        view.onActivateWindow = { _ in XCTFail("The shared boundary belongs to the primary disk") }
        view.updateHover(at: point)
        view.beginPointer(at: point); view.endPointer(at: point)
        XCTAssertEqual(activated, applications[0].pid)
    }

    @MainActor func testCompactCenterPagingDoesNotSelectASector() async {
        let view = RingView()
        let applications = apps(20)
        view.reset(apps: applications, options: Options())
        view.onActivateApp = { _ in XCTFail("Paging must not activate an app") }
        let next = CGPoint(x: RingGeometry.center.x + 12, y: RingGeometry.center.y - 26)
        view.activate(at: next)
        XCTAssertEqual(view.appPage, 1)
        let app = view.visibleApps[0]
        view.select(app); view.setWindows(.ready(windows(10, pid: app.pid)), for: app.pid)
        view.updateHover(at: next)
        XCTAssertNil(view.highlightedApp)
        view.activate(at: next)
        XCTAssertEqual(view.windowPage, 1)
        XCTAssertEqual(view.appPage, 1)
    }

    @MainActor func testRenderSolidThemesAndDensePages() async throws {
        guard let directory = ProcessInfo.processInfo.environment["LUMARING_SNAPSHOT_DIR"] else { return }
        _ = NSApplication.shared
        try FileManager.default.createDirectory(atPath: directory, withIntermediateDirectories: true)
        let view = RingView(frame: NSRect(x: 0, y: 0, width: 480, height: 480))
        let panel = NSWindow(contentRect: view.frame, styleMask: .borderless, backing: .buffered, defer: false)
        panel.contentView = view
        let iconURLs = ["/Applications/Safari.app", "/System/Applications/Mail.app", "/System/Applications/Notes.app", "/System/Applications/Calendar.app", "/System/Applications/Messages.app", "/System/Applications/Photos.app", "/System/Applications/Music.app", "/System/Library/CoreServices/Finder.app"]
        for dark in [false, true] {
            for count in [6, 8, 12, 16, 24] {
                var applications = apps(count)
                for i in applications.indices {
                    let path = iconURLs[i % iconURLs.count]
                    applications[i] = AppRecord(pid: pid_t(i + 100), bundleID: "test.\(i)", name: URL(fileURLWithPath: path).deletingPathExtension().lastPathComponent, icon: NSWorkspace.shared.icon(forFile: path))
                }
                view.appearance = NSAppearance(named: dark ? .darkAqua : .aqua)
                var options = Options(); options.appPageSize = count
                view.reset(apps: applications, options: options)
                for windowCount in [0, 2, 4] {
                view.select(applications[0]); view.setWindows(.ready(windows(windowCount)), for: 100)
                if windowCount == 0 {
                    view.updateHover(at: RingGeometry.point(angle: RingGeometry.angle(index: 1, count: count), radius: RingGeometry.appInner + 3))
                } else { view.updateHover(at: windowPoint(1, count: windowCount)) }
                view.layoutSubtreeIfNeeded()
                let bitmap = try XCTUnwrap(view.bitmapImageRepForCachingDisplay(in: view.bounds))
                view.cacheDisplay(in: view.bounds, to: bitmap)
                let data = try XCTUnwrap(bitmap.representation(using: .png, properties: [:]))
                try data.write(to: URL(fileURLWithPath: directory).appendingPathComponent("ring-\(dark ? "dark" : "light")-\(count)-windows-\(windowCount).png"))
                }
            }
        }
    }
}
