import XCTest
import AppKit
@testable import LumaRing

final class LiveWindowTests: XCTestCase {
    @MainActor private func fixtureWindows() async throws -> [WindowRecord] {
        _ = NSApplication.shared
        guard ProcessInfo.processInfo.environment["LUMARING_LIVE_TESTS"] == "1" else {
            throw XCTSkip("Opt-in test: launch scripts/build-fixture.sh output and set LUMARING_LIVE_TESTS=1")
        }
        guard AXIsProcessTrusted() else { throw XCTSkip("Test runner has no accessibility access") }
        let app = try XCTUnwrap(NSRunningApplication.runningApplications(withBundleIdentifier: "local.lumaring.fixture").first)
        let service = WindowService()
        let result: WindowResult = await withCheckedContinuation { continuation in
            service.load(pid: app.processIdentifier) { continuation.resume(returning: $0) }
        }
        guard case .ready(let windows, let limited) = result else {
            XCTFail("Fixture window enumeration failed"); return []
        }
        XCTAssertFalse(limited)
        XCTAssertEqual(windows.count, 10)
        XCTAssertTrue(windows.allSatisfy { $0.title.hasPrefix("LumaRing Test ") })
        return windows
    }

    @MainActor func testRealWindowAttributes() async throws {
        let windows = try await fixtureWindows()
        XCTAssertTrue(windows.contains { $0.minimized })
        XCTAssertTrue(windows.allSatisfy { $0.frame.width > 0 && $0.frame.height > 0 })
    }

    @MainActor func testRealStillPreview() async throws {
        _ = NSApplication.shared
        guard CGPreflightScreenCaptureAccess() else { throw XCTSkip("Test runner has no screen-capture access") }
        let windows = try await fixtureWindows()
        let target = try XCTUnwrap(windows.first { !$0.minimized })
        let preview = PreviewService()
        let ready = expectation(description: "one still image")
        var captured: NSImage?
        preview.load(target) { result in
            let image = try? result.get()
            XCTAssertNotNil(image)
            captured = image
            if let image {
                XCTAssertGreaterThan(image.size.width, 400)
                XCTAssertLessThanOrEqual(image.size.width, 880)
                XCTAssertLessThanOrEqual(image.size.height, 560)
            }
            ready.fulfill()
        }
        await fulfillment(of: [ready], timeout: 15)
        if let directory = ProcessInfo.processInfo.environment["LUMARING_SNAPSHOT_DIR"] {
            try FileManager.default.createDirectory(atPath: directory, withIntermediateDirectories: true)
            let view = WindowPreviewView(frame: NSRect(x: 0, y: 0, width: 440, height: 340))
            let host = NSWindow(contentRect: view.frame, styleMask: .borderless, backing: .buffered, defer: false)
            host.contentView = view
            view.appearance = NSAppearance(named: .aqua)
            view.title = target.title; view.image = captured
            let bitmap = try XCTUnwrap(view.bitmapImageRepForCachingDisplay(in: view.bounds))
            view.cacheDisplay(in: view.bounds, to: bitmap)
            try XCTUnwrap(bitmap.representation(using: .png, properties: [:])).write(to: URL(fileURLWithPath: directory).appendingPathComponent("large-window-preview.png"))
        }
        preview.cancelAndClear()
    }
}
