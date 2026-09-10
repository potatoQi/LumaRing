import XCTest
import TrackpadInput
@testable import LumaRing

final class TrackpadTests: XCTestCase {
    private func contacts(_ count: Int = 4, state: Int32 = 4, dx: Float = 0) -> [LRContact] {
        (0..<count).map { LRContact(id: Int32($0 + 1), state: state, x: 0.2 + Float($0) * 0.15 + dx, y: 0.5) }
    }
    private func feed(_ r: inout LRTapRecognizer, _ contacts: [LRContact], _ time: Double) -> Bool {
        contacts.withUnsafeBufferPointer { LRTapFrame(&r, $0.baseAddress, Int32($0.count), time) }
    }
    private func ready() -> LRTapRecognizer {
        var r = LRTapRecognizer()
        LRTapResetForFingerCount(&r, 4)
        XCTAssertFalse(feed(&r, [], 0))
        return r
    }
    private func tap(_ r: inout LRTapRecognizer, at time: Double) -> Bool {
        XCTAssertFalse(feed(&r, contacts(state: 3), time))
        XCTAssertFalse(feed(&r, contacts(), time + 0.04))
        return feed(&r, [], time + 0.08)
    }

    func testTapOnlyFiresOnLiftOnceAndCanRepeat() {
        var r = ready()
        XCTAssertTrue(tap(&r, at: 1))
        XCTAssertFalse(feed(&r, [], 1.1))
        XCTAssertFalse(tap(&r, at: 1.2)) // debounce
        XCTAssertTrue(tap(&r, at: 2))
    }

    func testStaggeredLandingReleaseAndReorderedContacts() {
        var r = ready()
        let c = contacts()
        XCTAssertFalse(feed(&r, Array(c.prefix(2)), 1))
        XCTAssertFalse(feed(&r, c.reversed(), 1.04))
        XCTAssertFalse(feed(&r, Array(c.dropFirst()), 1.09))
        XCTAssertFalse(feed(&r, [c[3]], 1.12))
        XCTAssertTrue(feed(&r, [], 1.16))
    }

    func testOneTwoThreeAndFiveFingersNeverTrigger() {
        for count in [1, 2, 3, 5] {
            var r = ready()
            XCTAssertFalse(feed(&r, contacts(count), 1))
            XCTAssertFalse(feed(&r, contacts(count), 1.04))
            XCTAssertFalse(feed(&r, [], 1.08))
            XCTAssertTrue(tap(&r, at: 2))
        }
    }

    func testFifthFingerInvalidatesGestureEvenAfterItLeaves() {
        var r = ready()
        XCTAssertFalse(feed(&r, contacts(), 1))
        XCTAssertFalse(feed(&r, contacts(5), 1.04))
        XCTAssertFalse(feed(&r, contacts(), 1.06))
        XCTAssertFalse(feed(&r, [], 1.1))
        XCTAssertTrue(tap(&r, at: 2))
    }

    func testSwipeAndPinchReturningToOriginAreRejected() {
        for pinch in [false, true] {
            var r = ready()
            XCTAssertFalse(feed(&r, contacts(), 1))
            var moved = contacts(dx: pinch ? 0 : 0.04)
            if pinch { moved[0].x += 0.05 }
            XCTAssertFalse(feed(&r, moved, 1.04))
            XCTAssertFalse(feed(&r, contacts(), 1.08))
            XCTAssertFalse(feed(&r, [], 1.1))
        }
    }

    func testReleaseCoordinatesAlsoRejectSwipe() {
        for state: Int32 in [5, 6, 7] {
            var r = ready()
            XCTAssertFalse(feed(&r, contacts(), 1))
            XCTAssertFalse(feed(&r, contacts(), 1.04))
            XCTAssertFalse(feed(&r, contacts(state: state, dx: 0.04), 1.08))
        }
    }

    func testSmallJitterAndBreakingStateAreAccepted() {
        var r = ready()
        XCTAssertFalse(feed(&r, contacts(), 1))
        XCTAssertFalse(feed(&r, contacts(dx: 0.005), 1.04))
        XCTAssertTrue(feed(&r, contacts(state: 5, dx: 0.005), 1.08))
        XCTAssertFalse(feed(&r, contacts(state: 6), 1.09))
    }

    func testLongHoldSlowAssemblyAndSlowReleaseAreRejected() {
        var hold = ready()
        for i in 0...8 { XCTAssertFalse(feed(&hold, contacts(), 1 + Double(i) * 0.05)) }
        XCTAssertFalse(feed(&hold, [], 1.45))
        var assemble = ready()
        XCTAssertFalse(feed(&assemble, contacts(3), 1))
        XCTAssertFalse(feed(&assemble, contacts(), 1.11))
        XCTAssertFalse(feed(&assemble, [], 1.16))
        var release = ready()
        XCTAssertFalse(feed(&release, contacts(), 1))
        XCTAssertFalse(feed(&release, contacts(), 1.04))
        XCTAssertFalse(feed(&release, contacts(2), 1.08))
        XCTAssertFalse(feed(&release, contacts(2), 1.14))
        XCTAssertFalse(feed(&release, [], 1.2))
    }

    func testReplacedFingerAndFingerReturningAfterReleaseAreRejected() {
        var r = ready()
        XCTAssertFalse(feed(&r, contacts(), 1))
        var replacement = contacts(); replacement[3].id = 99
        XCTAssertFalse(feed(&r, replacement, 1.04))
        XCTAssertFalse(feed(&r, [], 1.08))
        r = ready()
        XCTAssertFalse(feed(&r, contacts(), 1))
        XCTAssertFalse(feed(&r, contacts(3), 1.05))
        XCTAssertFalse(feed(&r, contacts(), 1.08))
        XCTAssertFalse(feed(&r, [], 1.12))
    }

    func testEnableDuringContactAndResetDuringTapDoNotTrigger() {
        var r = LRTapRecognizer(); LRTapResetForFingerCount(&r, 4)
        XCTAssertFalse(tap(&r, at: 1)) // Drain contacts that predate enabling.
        XCTAssertTrue(tap(&r, at: 2))
        XCTAssertFalse(feed(&r, contacts(), 3))
        LRTapResetForFingerCount(&r, 4)
        XCTAssertFalse(feed(&r, [], 3.08))
        XCTAssertTrue(tap(&r, at: 4))
    }

    func testInvalidInputAndMissingFramesFailClosed() {
        for mode in 0..<5 {
            var r = ready()
            XCTAssertFalse(feed(&r, contacts(), 1))
            var c = contacts()
            if mode == 0 { c[0].x = .nan }
            if mode == 1 { c[0].state = 99 }
            if mode == 2 { c[0].id = c[1].id }
            XCTAssertFalse(feed(&r, c, mode == 3 ? 0.9 : mode == 4 ? 1.2 : 1.04))
            XCTAssertFalse(feed(&r, [], 1.25))
            XCTAssertTrue(tap(&r, at: 2))
        }
        var r = ready()
        XCTAssertFalse(LRTapFrame(&r, nil, 4, 1))
        XCTAssertFalse(LRTapFrame(&r, nil, 0, .nan))
    }

    func testDevicesHaveIndependentGestureState() {
        var a = ready(), b = ready()
        XCTAssertFalse(feed(&a, contacts(2), 1))
        XCTAssertFalse(feed(&b, contacts(2), 1))
        XCTAssertFalse(feed(&a, [], 1.08))
        XCTAssertFalse(feed(&b, [], 1.08))
        XCTAssertTrue(tap(&a, at: 2))
        XCTAssertTrue(tap(&b, at: 2))
    }

    func testPreferenceRoundTripAndLegacyCompatibility() throws {
        var options = try JSONDecoder().decode(Options.self, from: Data(#"{"ringSize":480,"excludedBundleIDs":["keep.me"]}"#.utf8))
        XCTAssertEqual(options.trackpadTap, .disabled)
        options.trackpadTap = .fourFingers
        let result = try JSONDecoder().decode(Options.self, from: JSONEncoder().encode(options))
        XCTAssertEqual(result.trackpadTap, .fourFingers)
        XCTAssertEqual(result.ringSize, 480)
        XCTAssertEqual(result.excludedBundleIDs, ["keep.me"])
    }

    @MainActor func testLifecycleAndStaleQueuedTapDelivery() {
        var token: UInt64 = 0, starts = 0, stops = 0, taps = 0
        let service = TrackpadGesture(startListening: {
            starts += 1; token += 1
            return LRTrackpadResult(generation: token, devices: 1, available: true)
        }, stopListening: { stops += 1 }, observeDevices: false)
        service.onTap = { taps += 1 }
        service.configure(gesture: .disabled, pinch: false)
        XCTAssertEqual(starts, 0); XCTAssertEqual(stops, 0)
        service.configure(gesture: .fourFingers, pinch: false)
        service.configure(gesture: .fourFingers, pinch: false)
        XCTAssertEqual(starts, 1)
        service.deliver(1); XCTAssertEqual(taps, 1)
        service.suspend(.sleep); service.suspend(.session); service.suspend(.screenLock)
        service.deliver(1); XCTAssertEqual(taps, 1)
        service.resume(.sleep); XCTAssertEqual(starts, 1)
        service.resume(.session); XCTAssertEqual(starts, 1)
        service.resume(.screenLock); XCTAssertEqual(starts, 2)
        service.deliver(1); XCTAssertEqual(taps, 1)
        service.deliver(2); XCTAssertEqual(taps, 2)
        service.configure(gesture: .disabled, pinch: false)
        service.deliver(2); XCTAssertEqual(taps, 2)
        service.resume(.display); XCTAssertEqual(starts, 2)
        service.configure(gesture: .fourFingers, pinch: false)
        service.deliver(2); XCTAssertEqual(taps, 2)
        service.shutdown()
        service.deliver(3); XCTAssertEqual(taps, 2)
        XCTAssertEqual(service.status, .disabled)
    }

    @MainActor func testMissingFrameworkAndNoDeviceDoNotDeliverTaps() {
        for available in [false, true] {
            let service = TrackpadGesture(startListening: {
                LRTrackpadResult(generation: 1, devices: 0, available: available)
            }, stopListening: {}, observeDevices: false)
            service.onTap = { XCTFail("Unavailable listener must not deliver a tap") }
            service.configure(gesture: .fourFingers, pinch: false)
            XCTAssertEqual(service.status, available ? .noDevice : .unavailable)
            service.deliver(1)
            service.shutdown()
        }
    }
}
