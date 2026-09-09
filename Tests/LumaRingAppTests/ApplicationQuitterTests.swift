import XCTest
import AppKit
@testable import LumaRing

final class ApplicationQuitterTests: XCTestCase {
    @MainActor func testSlowQuitLeavesMainThreadAndOtherAppsResponsive() async {
        let started = expectation(description: "slow request started")
        let mainResponsive = expectation(description: "main queue ran during blocked delivery")
        let fastCompleted = expectation(description: "other app completed independently")
        let slowCompleted = expectation(description: "slow app eventually completed")
        let release = DispatchSemaphore(value: 0)
        defer { release.signal() }
        let quitter = ApplicationQuitter { target in
            XCTAssertFalse(Thread.isMainThread)
            if target.pid == 42 {
                started.fulfill()
                XCTAssertEqual(release.wait(timeout: .now() + 5), .success)
            }
            return .requested
        }
        XCTAssertTrue(quitter.quit(.init(pid: 42, bundleID: "test.slow")) { outcome in
            XCTAssertTrue(Thread.isMainThread)
            XCTAssertEqual(outcome, .requested)
            slowCompleted.fulfill()
        })
        await fulfillment(of: [started], timeout: 2)
        DispatchQueue.main.async { mainResponsive.fulfill() }
        XCTAssertTrue(quitter.quit(.init(pid: 43, bundleID: "test.fast")) { outcome in
            XCTAssertEqual(outcome, .requested)
            fastCompleted.fulfill()
        })
        await fulfillment(of: [mainResponsive, fastCompleted], timeout: 2)
        release.signal()
        await fulfillment(of: [slowCompleted], timeout: 2)
    }

    @MainActor func testDuplicateDeliveryIsCoalescedAndRejectionCanBeRetried() async {
        let completed = expectation(description: "rejected request completed")
        let retryCompleted = expectation(description: "retry completed")
        let release = DispatchSemaphore(value: 0)
        defer { release.signal() }
        let target = ApplicationQuitter.Target(pid: 42, bundleID: "test.app")
        let quitter = ApplicationQuitter { _ in
            _ = release.wait(timeout: .now() + 5)
            return .rejected
        }
        quitter.quit(target) { outcome in
            XCTAssertEqual(outcome, .rejected)
            completed.fulfill()
        }
        XCTAssertFalse(quitter.quit(target) { _ in XCTFail("Duplicate request must not be sent") })
        release.signal()
        await fulfillment(of: [completed], timeout: 2)
        // A completed failure must not permanently suppress a future user request.
        release.signal()
        XCTAssertTrue(quitter.quit(target) { outcome in
            XCTAssertEqual(outcome, .rejected)
            retryCompleted.fulfill()
        })
        await fulfillment(of: [retryCompleted], timeout: 2)
    }

    @MainActor func testInvalidAndOwnProcessNeverReceivesQuit() {
        let quitter = ApplicationQuitter { _ in XCTFail("Must not send"); return .requested }
        for pid in [pid_t(0), -1, getpid()] {
            let target = ApplicationQuitter.Target(pid: pid, bundleID: "test.app")
            XCTAssertFalse(quitter.quit(target) { _ in XCTFail("Must not complete unsent request") })
            XCTAssertEqual(ApplicationQuitter.sendQuit(target), .rejected)
        }
    }

    func testExitedTargetDoesNotLaunchOrQuitAnotherApplication() {
        XCTAssertEqual(ApplicationQuitter.sendQuit(.init(pid: pid_t(Int32.max), bundleID: "test.gone")), .alreadyExited)
    }
}
