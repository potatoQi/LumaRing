import AppKit
import ScreenCaptureKit
import XCTest
import LumaRingCore
@testable import LumaRing

final class RingMotionTests: XCTestCase {
    @MainActor func testOpeningPreservesUserSelectedRingSize() async throws {
        let view = NSView(frame: CGRect(x: 0, y: 0, width: 560, height: 560))
        view.bounds = CGRect(x: 0, y: 0, width: 480, height: 480)
        RingMotion.open(view)
        let layer = try XCTUnwrap(view.layer)
        XCTAssertEqual(layer.transform.m11, 560.0 / 480, accuracy: 0.0001)
        XCTAssertEqual(layer.transform.m22, 560.0 / 480, accuracy: 0.0001)
        RingMotion.reset(view)
        XCTAssertEqual(layer.transform.m11, 560.0 / 480, accuracy: 0.0001)
        XCTAssertNil(layer.animationKeys())
    }

    @MainActor func testHoverMovesOnlyPresentationAndKeepsTileCoordinatesStable() async throws {
        let host = NSView(frame: CGRect(x: 0, y: 0, width: 480, height: 480))
        host.wantsLayer = true
        let tile = RingTile(glass: true)
        host.addSubview(tile)
        let shape = RingGeometry.windowPetalPath(index: 0, count: 2, anchor: .pi / 2)
        let rect = shape.boundingBoxOfPath
        tile.place(in: rect, shape: shape)
        tile.update(highlighted: true, animated: true)
        XCTAssertEqual(tile.frame, rect)
        XCTAssertEqual(tile.artwork.convert(CGPoint(x: rect.midX, y: rect.midY), to: host), CGPoint(x: rect.midX, y: rect.midY))
        XCTAssertNil(tile.hitTest(.zero))
        if !RingMotion.reduced {
            XCTAssertNotNil(tile.layer?.animation(forKey: "pose"))
            XCTAssertGreaterThan(try XCTUnwrap(tile.layer).transform.m11, 1)
        }
        // Rapid reversal replaces the current animation rather than queuing motion.
        for _ in 0..<12 {
            tile.update(highlighted: false, animated: true)
            tile.update(highlighted: true, animated: true)
        }
        XCTAssertLessThanOrEqual(tile.layer?.animationKeys()?.count ?? 0, 1)
        tile.update(highlighted: false, animated: false)
        XCTAssertTrue(CATransform3DIsIdentity(try XCTUnwrap(tile.layer).transform))
        XCTAssertNil(tile.layer?.animationKeys())
    }

    @MainActor func testClosingStopsInputImmediatelyAndOldCompletionCannotCloseReopenedRing() async throws {
        _ = NSApplication.shared
        let ring = RingController(catalog: ApplicationCatalog())
        ring.show(actionMode: false)
        let panel = try XCTUnwrap(ring.view.window)
        ring.dismiss()
        XCTAssertFalse(ring.isVisible)
        XCTAssertTrue(panel.ignoresMouseEvents)
        ring.show(actionMode: false)
        XCTAssertTrue(ring.isVisible)
        XCTAssertFalse(panel.ignoresMouseEvents)
        try await Task.sleep(nanoseconds: 180_000_000)
        XCTAssertTrue(ring.isVisible)
        XCTAssertTrue(panel.isVisible)
        ring.dismiss()
        try await Task.sleep(nanoseconds: 180_000_000)
        XCTAssertFalse(panel.isVisible)
        XCTAssertTrue(ring.view.apps.isEmpty)
        XCTAssertTrue(ring.view.windows.isEmpty)
    }

    // Optional visual QA captures only this synthetic window, never user windows.
    @MainActor func testMotionSnapshots() async throws {
        guard let directory = ProcessInfo.processInfo.environment["LUMARING_MOTION_SNAPSHOTS"] else { return }
        guard CGPreflightScreenCaptureAccess() else { throw XCTSkip("Screen recording access is unavailable") }
        _ = NSApplication.shared
        let rect = CGRect(x: 0, y: 0, width: 720, height: 720)
        let window = NSWindow(contentRect: rect, styleMask: .borderless, backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        let backdrop = MotionBackdrop(frame: rect)
        window.contentView = backdrop
        let view = RingView(frame: rect)
        view.bounds = CGRect(x: 0, y: 0, width: 480, height: 480)
        backdrop.addSubview(view)
        let names = ["Finder", "Safari", "Notes", "Messages", "Calendar", "Music", "Preview", "App Store"]
        let ids = ["com.apple.finder", "com.apple.Safari", "com.apple.Notes", "com.apple.MobileSMS", "com.apple.iCal", "com.apple.Music", "com.apple.Preview", "com.apple.AppStore"]
        let apps = zip(names, ids).enumerated().map { index, item in
            AppRecord(pid: pid_t(100 + index), bundleID: item.1, name: item.0,
                icon: NSWorkspace.shared.urlForApplication(withBundleIdentifier: item.1).map { NSWorkspace.shared.icon(forFile: $0.path) } ?? NSImage())
        }
        let output = URL(fileURLWithPath: directory)
        try FileManager.default.createDirectory(at: output, withIntermediateDirectories: true)
        window.center(); window.orderFrontRegardless()
        defer { window.orderOut(nil); window.contentView = nil; window.close() }
        let content = try await SCShareableContent.excludingDesktopWindows(true, onScreenWindowsOnly: true)
        let target = try XCTUnwrap(content.windows.first { $0.windowID == CGWindowID(window.windowNumber) })
        let filter = SCContentFilter(desktopIndependentWindow: target)
        let configuration = SCStreamConfiguration()
        configuration.width = 1440; configuration.height = 1440
        configuration.showsCursor = false
        func capture(_ name: String) async throws {
            let image = try await SCScreenshotManager.captureImage(contentFilter: filter, configuration: configuration)
            let bitmap = NSBitmapImageRep(cgImage: image)
            try XCTUnwrap(bitmap.representation(using: .png, properties: [:])).write(to: output.appendingPathComponent(name + ".png"))
        }
        for appearance in [NSAppearance.Name.aqua, .darkAqua] {
            window.appearance = NSAppearance(named: appearance)
            backdrop.plain = false
            view.reset(apps: apps, options: Options())
            view.layoutSubtreeIfNeeded()
            view.animateOpening()
            try await Task.sleep(nanoseconds: 60_000_000)
            try await capture("opening-\(appearance.rawValue)")
            try await Task.sleep(nanoseconds: 350_000_000)
            view.selectingWithShortcut = true
            view.updateHover(at: RingGeometry.point(angle: .pi / 4, radius: 88))
            let windows = ["Mac — Apple", "HomePod mini", "Design notes"].enumerated().map { index, title in
                WindowRecord(id: "window-\(index)", pid: 101, title: title, minimized: false,
                    fullscreen: false, frame: .zero, element: AXUIElementCreateApplication(101))
            }
            view.setWindows(.ready(windows), for: 101)
            try await Task.sleep(nanoseconds: 60_000_000)
            try await capture("secondary-opening-\(appearance.rawValue)")
            view.updateHover(at: RingGeometry.point(angle: .pi / 4, radius: 158))
            try await Task.sleep(nanoseconds: 450_000_000)
            try await capture("selected-\(appearance.rawValue)")
            backdrop.plain = true
            for index in [0, 2, 4, 6] {
                view.updateHover(at: RingGeometry.point(angle: RingGeometry.angle(index: index, count: 8), radius: 88))
                try await Task.sleep(nanoseconds: 400_000_000)
                try await capture("edge-\(index)-\(appearance.rawValue)")
            }
        }
    }
}

private final class MotionBackdrop: NSView {
    var plain = false { didSet { needsDisplay = true } }
    override func draw(_ dirtyRect: NSRect) {
        if plain { NSColor.windowBackgroundColor.setFill(); bounds.fill(); return }
        NSGradient(starting: NSColor(calibratedRed: 0.30, green: 0.14, blue: 0.74, alpha: 1),
                   ending: NSColor(calibratedRed: 0.05, green: 0.36, blue: 0.74, alpha: 1))?.draw(in: bounds, angle: -70)
    }
}
