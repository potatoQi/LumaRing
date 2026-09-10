import XCTest
import AppKit
import LumaRingCore
@testable import LumaRing

final class LauncherTests: XCTestCase {
    private let icon = NSImage(systemSymbolName: "app.fill", accessibilityDescription: nil)!
    private var primary: AppRecord { AppRecord(pid: 100, bundleID: "test.primary", name: "Primary", icon: icon) }
    private func records(_ count: Int = 3) -> [LauncherRecord] {
        (0..<count).map { LauncherRecord(app: LauncherApp(bundleID: "test.launch.\($0)", name: "App \($0)", path: "/missing/\($0).app"), icon: icon, available: true) }
    }
    @MainActor private func view(_ count: Int = 3) -> RingView {
        let view = RingView(frame: NSRect(x: 0, y: 0, width: 480, height: 480))
        view.reset(apps: [primary], options: Options())
        view.launcherApps = records(count)
        return view
    }
    func testOldPreferencesDefaultToEmptyAndRoundTripPreservesOrder() throws {
        let old = try JSONDecoder().decode(Options.self, from: Data("{}".utf8))
        XCTAssertTrue(old.launcherApps.isEmpty)
        var options = old; options.launcherApps = records().map(\.app)
        let decoded = try JSONDecoder().decode(Options.self, from: JSONEncoder().encode(options))
        XCTAssertEqual(decoded.launcherApps, options.launcherApps)
        XCTAssertEqual(LauncherApp.unique(options.launcherApps + options.launcherApps), options.launcherApps)
    }
    @MainActor func testInvocationOptionRequiresReleaseAndFreshPress() async {
        let view = view()
        view.optionPressed = true // Held by Option + Tab when the panel opens.
        view.updateOption(pressed: true)
        XCTAssertFalse(view.showsLauncher)
        view.updateOption(pressed: false)
        view.updateOption(pressed: true)
        XCTAssertTrue(view.showsLauncher)
        view.updateOption(pressed: false)
        XCTAssertFalse(view.showsLauncher)
    }
    @MainActor func testVisibleSecondaryRingAndDragAndMenuBlockEntry() async {
        let view = view()
        view.select(primary)
        let windows = (0..<2).map { WindowRecord(id: "w\($0)", pid: 100, title: "Window", minimized: false, fullscreen: false, frame: .zero, element: AXUIElementCreateApplication(100)) }
        view.setWindows(.ready(windows), for: 100)
        view.updateOption(pressed: true)
        XCTAssertTrue(view.showsWindowArc); XCTAssertFalse(view.showsLauncher)
        view.clearSelection()
        view.updateOption(pressed: true)
        XCTAssertFalse(view.showsLauncher, "Closing an arc while held does not synthesize a new press")
        view.updateOption(pressed: false)
        view.beginPointer(at: RingGeometry.point(angle: .pi / 2, radius: 88))
        view.updateOption(pressed: true)
        XCTAssertFalse(view.showsLauncher)
        view.cancelPointerInteraction(); view.updateOption(pressed: false)
        view.isContextMenuOpen = true; view.updateOption(pressed: true)
        XCTAssertFalse(view.showsLauncher)
    }
    @MainActor func testPendingWindowResultCannotReplaceLauncherAndPrimaryIsDisabled() async {
        let view = view()
        view.select(primary)
        view.onActivateApp = { _ in XCTFail("Primary disabled") }
        view.onQuitApp = { _ in XCTFail("Primary disabled") }
        view.onSelectApp = { _ in XCTFail("Primary disabled") }
        view.updateOption(pressed: true)
        view.setWindows(.ready([]), for: 100)
        XCTAssertNil(view.selectedApp); XCTAssertTrue(view.showsLauncher)
        let point = RingGeometry.point(angle: .pi / 2, radius: 88)
        view.updateHover(at: point); view.beginPointer(at: point)
        view.movePointer(to: view.launcherPoint(0)); view.endPointer(at: view.launcherPoint(0))
        view.activate(at: point); view.activateHovered(); view.select(primary)
        XCTAssertNil(view.selectedApp); XCTAssertTrue(view.showsLauncher)
    }
    @MainActor func testOuterClickRequiresSameAppAndHoldingOptionThroughRelease() async {
        let view = view()
        var launched: [String] = []
        view.onLaunchApp = { launched.append($0.id) }
        view.updateOption(pressed: true)
        view.beginPointer(at: view.launcherPoint(0)); view.endPointer(at: view.launcherPoint(1))
        XCTAssertTrue(launched.isEmpty)
        view.beginPointer(at: view.launcherPoint(0)); view.updateOption(pressed: false)
        view.endPointer(at: RingGeometry.point(angle: .pi / 2, radius: 88))
        XCTAssertTrue(launched.isEmpty)
        view.updateOption(pressed: true)
        view.beginPointer(at: view.launcherPoint(1)); view.endPointer(at: view.launcherPoint(1))
        XCTAssertEqual(launched, ["test.launch.1"])
    }
    @MainActor func testPagingEmptyMissingAppsAndReset() async {
        let view = view(25)
        view.updateOption(pressed: true)
        XCTAssertEqual(view.visibleLauncherApps.count, 12)
        view.changeLauncherPage(2)
        XCTAssertEqual(view.visibleLauncherApps.map(\.app.id), ["test.launch.24"])
        view.changeLauncherPage(1); XCTAssertEqual(view.launcherPage, 0)
        view.launcherApps = [LauncherRecord(app: records(1)[0].app, icon: icon, available: false)]
        view.onLaunchApp = { _ in XCTFail("Missing app must not open") }
        view.activate(at: view.launcherPoint(0))
        view.reset(apps: [], options: Options())
        XCTAssertFalse(view.showsLauncher); XCTAssertTrue(view.launcherApps.isEmpty)
        view.updateOption(pressed: true)
        XCTAssertTrue(view.showsLauncher)
        XCTAssertNil(view.launcherTarget(at: RingGeometry.point(angle: 0, radius: 158)))
    }
    @MainActor func testLaunchFailureDoesNotFallBackToAnotherApp() async {
        let app = records(1)[0].app
        let missing = ApplicationLauncher(resolve: { _ in nil }, open: { _, _, _ in XCTFail("Unresolved app") })
        missing.launch(app) { XCTAssertFalse($0) }
        let failed = expectation(description: "failed launch")
        let launcher = ApplicationLauncher(resolve: { _ in URL(fileURLWithPath: app.path) }, open: { url, config, reply in
            XCTAssertEqual(url.path, app.path)
            XCTAssertTrue(config.activates); XCTAssertFalse(config.createsNewApplicationInstance)
            XCTAssertFalse(config.promptsUserIfNeeded); XCTAssertFalse(config.addsToRecentItems)
            reply(nil, NSError(domain: "Test", code: 1))
        })
        launcher.launch(app) { XCTAssertFalse($0); failed.fulfill() }
        await fulfillment(of: [failed], timeout: 1)
    }
    @MainActor func testRenderLauncherInBothThemes() async throws {
        guard let directory = ProcessInfo.processInfo.environment["LUMARING_SNAPSHOT_DIR"] else { return }
        _ = NSApplication.shared
        try FileManager.default.createDirectory(atPath: directory, withIntermediateDirectories: true)
        let view = view(14)
        let samples = ["/System/Applications/Notes.app", "/System/Applications/Preview.app",
                       "/System/Applications/Utilities/Terminal.app", "/System/Library/CoreServices/Finder.app"]
        view.launcherApps = view.launcherApps.enumerated().map { index, record in
            let path = samples[index % samples.count]
            let app = LauncherApp(bundleID: record.app.bundleID, name: URL(fileURLWithPath: path).deletingPathExtension().lastPathComponent, path: path)
            return LauncherRecord(app: app, icon: NSWorkspace.shared.icon(forFile: path), available: true)
        }
        view.apps = (0..<6).map { index in
            let path = samples[index % samples.count]
            return AppRecord(pid: pid_t(100 + index), bundleID: "test.primary.\(index)", name: "Primary", icon: NSWorkspace.shared.icon(forFile: path))
        }
        let panel = NSWindow(contentRect: view.frame, styleMask: [.borderless], backing: .buffered, defer: false)
        panel.contentView = view
        view.updateOption(pressed: true)
        for theme in [NSAppearance.Name.aqua, .darkAqua] {
            view.appearance = NSAppearance(named: theme)
            view.updateHover(at: view.launcherPoint(1))
            view.refresh(); view.layoutSubtreeIfNeeded(); view.displayIfNeeded()
            let bitmap = try XCTUnwrap(view.bitmapImageRepForCachingDisplay(in: view.bounds))
            view.cacheDisplay(in: view.bounds, to: bitmap)
            let data = try XCTUnwrap(bitmap.representation(using: .png, properties: [:]))
            try data.write(to: URL(fileURLWithPath: directory).appendingPathComponent("launcher-\(theme.rawValue).png"))
        }
        panel.contentView = nil
    }
}
