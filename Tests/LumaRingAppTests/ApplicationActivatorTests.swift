import XCTest
import AppKit
@testable import LumaRing

final class ApplicationActivatorTests: XCTestCase {
    @MainActor func testUsesReopenWithoutLaunchingAnotherInstance() async throws {
        _ = NSApplication.shared
        let current = try XCTUnwrap(NSRunningApplication(processIdentifier: getpid()))
        guard current.bundleURL != nil else { throw XCTSkip("Test host has no bundle URL") }
        let completed = expectation(description: "activation callback")
        var opened = false
        let activator = ApplicationActivator { url, config, callback in
            opened = true
            XCTAssertEqual(url, current.bundleURL)
            XCTAssertTrue(config.activates)
            XCTAssertFalse(config.createsNewApplicationInstance)
            XCTAssertFalse(config.addsToRecentItems)
            XCTAssertFalse(config.promptsUserIfNeeded)
            callback(current, nil)
        }
        activator.activate(pid: getpid()) { success in
            XCTAssertTrue(success); completed.fulfill()
        }
        await fulfillment(of: [completed], timeout: 1)
        XCTAssertTrue(opened)
    }

    @MainActor func testOpenFailureIsNotReportedAsSuccess() async throws {
        _ = NSApplication.shared
        guard NSRunningApplication(processIdentifier: getpid())?.bundleURL != nil else { throw XCTSkip("Test host has no bundle URL") }
        let completed = expectation(description: "failed activation")
        let activator = ApplicationActivator { _, _, callback in
            callback(nil, NSError(domain: NSCocoaErrorDomain, code: NSFileNoSuchFileError))
        }
        activator.activate(pid: getpid()) { success in
            XCTAssertFalse(success); completed.fulfill()
        }
        await fulfillment(of: [completed], timeout: 1)
    }

    @MainActor func testExitedApplicationIsNotLaunchedAgain() {
        let activator = ApplicationActivator { _, _, _ in XCTFail("Must not relaunch an exited app") }
        var result: Bool?
        activator.activate(pid: pid_t(Int32.max)) { result = $0 }
        XCTAssertEqual(result, false)
    }
}
