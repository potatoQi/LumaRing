import XCTest
import TrackpadInput
@testable import LumaRing

final class TapSelectionTests: XCTestCase {
    private func contacts(_ count: Int, scale: Float = 1, dx: Float = 0) -> [LRContact] {
        let points: [(Float, Float)] = [(-0.2, -0.1), (0.2, -0.1), (0, 0.2), (0.25, 0.2), (-0.25, 0.2)]
        return points.prefix(count).enumerated().map {
            LRContact(id: Int32($0.offset), state: 4, x: 0.5 + $0.element.0 * scale + dx, y: 0.5 + $0.element.1 * scale)
        }
    }
    private func feed(_ r: inout LRTapRecognizer, _ c: [LRContact], _ time: Double) -> Bool {
        c.withUnsafeBufferPointer { LRTapFrame(&r, $0.baseAddress, Int32($0.count), time) }
    }
    private func ready(_ fingers: UInt32) -> LRTapRecognizer {
        var r = LRTapRecognizer(); LRTapResetForFingerCount(&r, fingers)
        XCTAssertFalse(feed(&r, [], 0))
        return r
    }
    private func tap(_ r: inout LRTapRecognizer, fingers: Int, at time: Double) -> Bool {
        XCTAssertFalse(feed(&r, contacts(fingers), time))
        XCTAssertFalse(feed(&r, contacts(fingers), time + 0.04))
        return feed(&r, [], time + 0.08)
    }

    func testOnlySelectedCountFiresAndSelectionSurvivesRearming() {
        for selected: UInt32 in [3, 4] {
            var r = ready(selected)
            for count in 1...5 {
                XCTAssertEqual(tap(&r, fingers: count, at: Double(count)), count == selected)
                XCTAssertEqual(r.targetCount, selected)
            }
            XCTAssertTrue(tap(&r, fingers: Int(selected), at: 6))
            XCTAssertFalse(tap(&r, fingers: Int(selected), at: 6.2))
            XCTAssertTrue(tap(&r, fingers: Int(selected), at: 7))
        }
    }

    func testStaggeredThreeFingerTapAndExtraFingerRejection() {
        var r = ready(3)
        _ = feed(&r, contacts(1), 1)
        _ = feed(&r, contacts(3).reversed(), 1.04)
        _ = feed(&r, Array(contacts(3).dropFirst()), 1.08)
        XCTAssertTrue(feed(&r, [], 1.12))
        _ = feed(&r, contacts(3), 2)
        _ = feed(&r, contacts(4), 2.04)
        _ = feed(&r, contacts(3), 2.06)
        XCTAssertFalse(feed(&r, [], 2.1))
        XCTAssertTrue(tap(&r, fingers: 3, at: 3))
    }

    func testThreeFingerTapAcceptsNaturalLandingLiftAndSmallRoll() {
        var r = ready(3)
        _ = feed(&r, contacts(1), 1)
        _ = feed(&r, contacts(2), 1.07)
        _ = feed(&r, contacts(3), 1.13)
        _ = feed(&r, contacts(3, dx: 0.028), 1.17)
        _ = feed(&r, Array(contacts(3, dx: 0.028).dropFirst()), 1.19)
        _ = feed(&r, Array(contacts(3, dx: 0.028).suffix(1)), 1.28)
        XCTAssertTrue(feed(&r, [], 1.33))
        // A brisk tap can have only one or two frames of full overlap.
        _ = feed(&r, contacts(3), 2)
        _ = feed(&r, Array(contacts(3).dropFirst()), 2.016)
        XCTAssertTrue(feed(&r, [], 2.05))
    }

    func testSmallPinchesCannotTriggerBothActions() {
        for initial: Float in [0.4, 0.6, 1] {
            for contraction: Float in [0.6, 0.75, 0.9] {
                var tap = ready(3), pinch = LRPinchRecognizer()
                LRPinchReset(&pinch); _ = LRPinchFrame(&pinch, nil, 0, 0)
                var opened = false, minimized = false
                for (time, c) in [(1.0, contacts(3, scale: initial)),
                                  (1.08, contacts(3, scale: initial * (1 + contraction) / 2)),
                                  (1.16, contacts(3, scale: initial * contraction)), (1.22, [])] {
                    opened = feed(&tap, c, time) || opened
                    c.withUnsafeBufferPointer {
                        minimized = LRPinchFrame(&pinch, $0.baseAddress, Int32($0.count), time) == LRPinchCompleted || minimized
                    }
                }
                XCTAssertFalse(opened && minimized)
            }
        }
    }

    func testThreeFingerTapRejectsDragPinchAndInvalidFrames() {
        for mode in 0..<7 {
            var r = ready(3)
            _ = feed(&r, contacts(3), 1)
            var c = contacts(3, scale: mode == 0 ? 0.7 : 1, dx: mode == 1 ? 0.04 : 0)
            if mode == 2 { c[0].id = c[1].id }
            if mode == 3 { c[0].x = .nan }
            if mode == 4 { c[0].id = 99 }
            _ = feed(&r, c, mode == 5 ? 1.2 : mode == 6 ? 0.9 : 1.04)
            XCTAssertFalse(feed(&r, [], 1.24))
            XCTAssertTrue(tap(&r, fingers: 3, at: 2))
        }
    }

    func testChangingCountDuringContactRequiresLiftAndInvalidCountCannotFire() {
        var r = ready(4)
        _ = feed(&r, contacts(3), 1)
        LRTapResetForFingerCount(&r, 3)
        XCTAssertFalse(feed(&r, contacts(3), 1.04))
        XCTAssertFalse(feed(&r, [], 1.08))
        XCTAssertTrue(tap(&r, fingers: 3, at: 2))
        for count: UInt32 in [0, 1, 2, 5, UInt32.max] {
            r = ready(count)
            XCTAssertFalse(tap(&r, fingers: 3, at: 3))
            XCTAssertFalse(tap(&r, fingers: 4, at: 4))
        }
    }

    func testTapAndPinchAreMutuallyExclusiveWithBothEnabled() {
        for pinch in [false, true] {
            var r = ready(3), p = LRPinchRecognizer()
            LRPinchReset(&p); _ = LRPinchFrame(&p, nil, 0, 0)
            var taps = 0, pinches = 0
            for (time, c) in [(1.0, contacts(3)), (1.08, contacts(3, scale: pinch ? 0.85 : 1)),
                              (1.16, contacts(3, scale: pinch ? 0.6 : 1)), (1.22, [])] {
                if feed(&r, c, time) { taps += 1 }
                c.withUnsafeBufferPointer {
                    if LRPinchFrame(&p, $0.baseAddress, Int32($0.count), time) == LRPinchCompleted { pinches += 1 }
                }
            }
            XCTAssertEqual(taps, pinch ? 0 : 1)
            XCTAssertEqual(pinches, pinch ? 1 : 0)
        }
    }

    func testLegacyMigrationNewSelectionPersistenceAndUnknownValues() throws {
        for (json, expected) in [
            (#"{}"#, TrackpadTap.disabled),
            (#"{"fourFingerTap":true}"#, .fourFingers),
            (#"{"fourFingerTap":false}"#, .disabled),
            (#"{"fourFingerTap":true,"trackpadTap":3}"#, .threeFingers),
            (#"{"fourFingerTap":true,"trackpadTap":0}"#, .disabled),
            (#"{"fourFingerTap":true,"trackpadTap":5}"#, .disabled),
            (#"{"trackpadTap":"invalid"}"#, .disabled)
        ] {
            let options = try JSONDecoder().decode(Options.self, from: Data(json.utf8))
            XCTAssertEqual(options.trackpadTap, expected)
        }
        for selection in TrackpadTap.allCases {
            var options = Options(); options.trackpadTap = selection
            options.threeFingerPinch = true; options.excludedBundleIDs = ["keep.me"]
            let data = try JSONEncoder().encode(options)
            let result = try JSONDecoder().decode(Options.self, from: data)
            XCTAssertEqual(result.trackpadTap, selection); XCTAssertTrue(result.threeFingerPinch)
            XCTAssertEqual(result.excludedBundleIDs, ["keep.me"])
            XCTAssertNil((try JSONSerialization.jsonObject(with: data) as? [String: Any])?["fourFingerTap"])
        }
    }

    @MainActor func testSwitchingCountInvalidatesQueuedEventsAndCancelsPinch() {
        var token: UInt64 = 0, taps = 0, pinches = 0, cancellations = 0
        let service = TrackpadGesture(startListening: {
            token += 1
            return LRTrackpadResult(generation: token, devices: 1, available: true)
        }, stopListening: {}, observeDevices: false)
        service.onTap = { taps += 1 }; service.onPinchComplete = { pinches += 1 }
        service.onPinchCancel = { cancellations += 1 }
        service.configure(gesture: .fourFingers, pinch: true)
        service.deliverPinch(token, device: 0, event: LRPinchBegan)
        let oldToken = token, oldCancellations = cancellations
        service.configure(gesture: .threeFingers, pinch: true)
        XCTAssertEqual(service.tapGesture, .threeFingers)
        XCTAssertGreaterThan(cancellations, oldCancellations)
        service.deliver(oldToken)
        service.deliverPinch(oldToken, device: 0, event: LRPinchCompleted)
        XCTAssertEqual(taps, 0); XCTAssertEqual(pinches, 0)
        service.deliver(token); XCTAssertEqual(taps, 1)
        let currentToken = token
        service.configure(gesture: .threeFingers, pinch: true)
        XCTAssertEqual(token, currentToken)
        service.suspend(.sleep); service.resume(.sleep)
        XCTAssertEqual(service.tapGesture, .threeFingers)
        service.configure(gesture: .disabled, pinch: true)
        XCTAssertTrue(service.enabled); XCTAssertFalse(service.tapEnabled)
        service.deliver(token); XCTAssertEqual(taps, 1)
        service.shutdown()
    }
}
