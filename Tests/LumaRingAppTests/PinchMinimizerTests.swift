import AppKit
import XCTest
import LumaRingCore
@testable import LumaRing

final class PinchMinimizerTests: XCTestCase {
    @MainActor func testReleaseWaitsForCaptureAndMinimizesOnlyOnce() async {
        let started = expectation(description: "capture started")
        let minimized = expectation(description: "exact window minimized")
        let gate = DispatchSemaphore(value: 0)
        let target = AXUIElementCreateApplication(81234)
        let service = PinchMinimizer(foreground: { 81234 }, allowed: { true }, capture: { _, _ in
            started.fulfill(); gate.wait(); return target
        }, minimize: { pid, window, flag in
            XCTAssertEqual(pid, 81234); XCTAssertTrue(CFEqual(window, target)); XCTAssertFalse(flag.isCancelled)
            minimized.fulfill()
        }, observeActivation: false)
        service.begin()
        await fulfillment(of: [started], timeout: 1)
        service.complete(); service.complete()
        gate.signal()
        await fulfillment(of: [minimized], timeout: 1)
        service.cancel()
    }

    @MainActor func testCancelAndForegroundOrPermissionChangeDiscardPendingTarget() async {
        for mode in 0..<3 {
            let started = expectation(description: "capture started")
            let finished = expectation(description: "capture finished")
            let unexpected = expectation(description: "must not minimize"); unexpected.isInverted = true
            let gate = DispatchSemaphore(value: 0)
            var foreground: pid_t? = 81234, allowed = true
            let service = PinchMinimizer(foreground: { foreground }, allowed: { allowed }, capture: { _, _ in
                started.fulfill(); gate.wait(); finished.fulfill(); return AXUIElementCreateApplication(81234)
            }, minimize: { _, _, _ in unexpected.fulfill() }, observeActivation: false)
            service.begin()
            await fulfillment(of: [started], timeout: 1)
            if mode == 0 { service.cancel() }
            if mode == 1 { foreground = 81235 }
            if mode == 2 { allowed = false }
            service.complete(); gate.signal()
            await fulfillment(of: [finished, unexpected], timeout: 0.15)
            service.cancel()
        }
    }

    @MainActor func testNoCaptureWhenDisabledOrForegroundIsLumaRing() {
        for pid in [nil, ProcessInfo.processInfo.processIdentifier, 0] as [pid_t?] {
            let service = PinchMinimizer(foreground: { pid }, allowed: { true }, capture: { _, _ in
                XCTFail("No target should be captured"); return nil
            }, observeActivation: false)
            service.begin(); service.complete(); service.cancel()
        }
        let service = PinchMinimizer(foreground: { 81234 }, allowed: { false }, capture: { _, _ in
            XCTFail("Disabled gesture should not capture"); return nil
        }, observeActivation: false)
        service.begin(); service.complete(); service.cancel()
    }

    func testAXWriteUsesExactFocusedStandardWindowAndSkipsUnsupportedTargets() {
        // AX application values provide stable opaque, PID-bearing identities for
        // this injected backend. No accessibility messages or real writes occur.
        let pid: pid_t = 81234
        let window = AXUIElementCreateApplication(pid)
        for mode in 0..<10 {
            let flag = CancellationFlag()
            if mode == 1 { flag.cancel() }
            var writes = 0
            let read: FocusedWindowAccess.Read = { _, key in
                switch key {
                case kAXFocusedApplicationAttribute: XCTFail("Do not depend on system-wide AX focus"); return nil
                case kAXFocusedWindowAttribute:
                    return mode == 3 ? AXUIElementCreateApplication(81235) : window
                case kAXRoleAttribute: return (mode == 4 ? kAXButtonRole : kAXWindowRole) as CFString
                case kAXSubroleAttribute: return (mode == 5 ? kAXDialogSubrole : kAXStandardWindowSubrole) as CFString
                case kAXMinimizedAttribute: return mode == 6 ? kCFBooleanTrue : kCFBooleanFalse
                case "AXFullScreen": return mode == 7 ? kCFBooleanTrue : kCFBooleanFalse
                default: return nil
                }
            }
            let result = FocusedWindowAccess.minimize(pid: pid, window: window, cancelled: flag, read: read,
                foreground: { mode == 2 ? 81235 : pid },
                settable: { _ in
                    if mode == 9 { flag.cancel() }
                    return mode != 8
                }, write: { target in
                    XCTAssertTrue(CFEqual(target, window)); writes += 1; return true
                })
            XCTAssertEqual(result, mode == 0, "mode \(mode)")
            XCTAssertEqual(writes, mode == 0 ? 1 : 0, "mode \(mode)")
        }
    }

    func testFocusUsesKnownForegroundPIDWithoutSystemWideAXQuery() {
        let pid: pid_t = 81234
        let window = AXUIElementCreateApplication(pid)
        var reads = 0
        let found = FocusedWindowAccess.focusedWindow(pid: pid, read: { app, key in
            reads += 1
            var owner: pid_t = 0
            XCTAssertEqual(AXUIElementGetPid(app, &owner), .success)
            XCTAssertEqual(owner, pid)
            XCTAssertEqual(key, kAXFocusedWindowAttribute)
            return window
        }, foreground: { pid })
        XCTAssertTrue(found.map { CFEqual($0, window) } ?? false)
        XCTAssertEqual(reads, 1)
    }

    func testFocusChangeDuringLookupAndUnavailableFocusedWindowAreRejected() {
        let pid: pid_t = 81234
        var foreground = pid
        XCTAssertNil(FocusedWindowAccess.focusedWindow(pid: pid, read: { _, _ in
            foreground += 1
            return AXUIElementCreateApplication(pid)
        }, foreground: { foreground }))
        XCTAssertNil(FocusedWindowAccess.focusedWindow(pid: pid, read: { _, _ in
            XCTFail("A background application must not be queried"); return nil
        }, foreground: { pid + 1 }))
        XCTAssertNil(FocusedWindowAccess.focusedWindow(pid: pid, read: { _, key in
            XCTAssertEqual(key, kAXFocusedWindowAttribute, "Do not fall back to an arbitrary window")
            return nil
        }, foreground: { pid }))
    }
}
