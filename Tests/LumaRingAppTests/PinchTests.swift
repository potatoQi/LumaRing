import XCTest
import AppKit
import TrackpadInput
import LumaRingCore
@testable import LumaRing

final class PinchTests: XCTestCase {
    private func contacts(scale: Float = 1, dx: Float = 0, state: Int32 = 4) -> [LRContact] {
        [(Float(-0.2), Float(-0.1)), (0.2, -0.1), (0, 0.2)].enumerated().map {
            LRContact(id: Int32($0.offset + 1), state: state,
                      x: 0.5 + $0.element.0 * scale + dx, y: 0.5 + $0.element.1 * scale)
        }
    }
    private func feed(_ r: inout LRPinchRecognizer, _ c: [LRContact], _ time: Double) -> LRPinchEvent {
        c.withUnsafeBufferPointer { LRPinchFrame(&r, $0.baseAddress, Int32($0.count), time) }
    }
    private func ready() -> LRPinchRecognizer {
        var r = LRPinchRecognizer(); LRPinchReset(&r)
        XCTAssertEqual(feed(&r, [], 0), LRPinchNone)
        return r
    }
    private func contract(_ r: inout LRPinchRecognizer, at time: Double = 1) {
        XCTAssertEqual(feed(&r, contacts(), time), LRPinchBegan)
        XCTAssertEqual(feed(&r, contacts(scale: 0.85), time + 0.08), LRPinchNone)
        XCTAssertEqual(feed(&r, contacts(scale: 0.6), time + 0.16), LRPinchNone)
    }

    func testPinchFiresOnlyOnLiftOnceWithCooldown() {
        var r = ready()
        contract(&r)
        XCTAssertEqual(feed(&r, [], 1.22), LRPinchCompleted)
        XCTAssertEqual(feed(&r, [], 1.23), LRPinchNone)
        XCTAssertEqual(feed(&r, contacts(), 1.4), LRPinchNone)
        XCTAssertEqual(feed(&r, [], 1.48), LRPinchNone)
        contract(&r, at: 2)
        XCTAssertEqual(feed(&r, contacts(scale: 0.6, state: 5), 2.22), LRPinchCompleted)
    }

    func testStaggeredLandingReorderingAndRelease() {
        var r = ready()
        XCTAssertEqual(feed(&r, Array(contacts().prefix(1)), 1), LRPinchNone)
        XCTAssertEqual(feed(&r, contacts().reversed(), 1.04), LRPinchBegan)
        XCTAssertEqual(feed(&r, contacts(scale: 0.8).reversed(), 1.12), LRPinchNone)
        XCTAssertEqual(feed(&r, contacts(scale: 0.6), 1.20), LRPinchNone)
        XCTAssertEqual(feed(&r, Array(contacts(scale: 0.6).dropFirst()), 1.24), LRPinchNone)
        XCTAssertEqual(feed(&r, Array(contacts(scale: 0.6).suffix(1)), 1.28), LRPinchNone)
        XCTAssertEqual(feed(&r, [], 1.32), LRPinchCompleted)
    }

    func testNaturalAsymmetricPinchWithTwoFingersMaintainingTheirSpacing() {
        var r = ready()
        // Two adjacent fingertips move together toward the opposing finger.
        let start = [LRContact(id: 1, state: 4, x: 0.3, y: 0.5),
                     LRContact(id: 2, state: 4, x: 0.7, y: 0.46),
                     LRContact(id: 3, state: 4, x: 0.7, y: 0.54)]
        XCTAssertEqual(feed(&r, start, 1), LRPinchBegan)
        var middle = start; middle[0].x += 0.04; middle[1].x -= 0.03; middle[2].x -= 0.03
        XCTAssertEqual(feed(&r, middle, 1.1), LRPinchNone)
        var end = start; end[0].x += 0.08; end[1].x -= 0.06; end[2].x -= 0.06
        XCTAssertEqual(feed(&r, end, 1.2), LRPinchNone)
        XCTAssertEqual(feed(&r, [], 1.28), LRPinchCompleted)
    }

    func testWideAsymmetricContractionCanShiftItsCenter() {
        var r = ready()
        let start = [LRContact(id: 1, state: 4, x: 0.42, y: 0.03),
                     LRContact(id: 2, state: 4, x: 0.52, y: 0.67),
                     LRContact(id: 3, state: 4, x: 0.65, y: 0.91)]
        XCTAssertEqual(feed(&r, start, 1), LRPinchBegan)
        var middle = start
        middle[0].x = 0.45; middle[0].y = 0.09
        middle[1].y = 0.58; middle[2].y = 0.83
        XCTAssertEqual(feed(&r, middle, 1.08), LRPinchNone)
        var end = start
        end[0].x = 0.51; end[0].y = 0.19
        end[1].x = 0.54; end[1].y = 0.45
        end[2].x = 0.63; end[2].y = 0.65
        XCTAssertEqual(feed(&r, end, 1.16), LRPinchNone)
        XCTAssertEqual(feed(&r, [], 1.24), LRPinchCompleted)
    }

    func testStaggeredLiftAllowsContinuedInwardMotionAndIgnoresEndedFingerHover() {
        for lingering in [false, true] {
            var r = ready(); contract(&r)
            var end = contacts(scale: 0.6)
            end[0].state = 5
            XCTAssertEqual(feed(&r, end, 1.20), LRPinchNone)
            for (offset, scale) in [Float(0.45), 0.30].enumerated() {
                var next = contacts(scale: scale)
                if lingering {
                    // This finger already ended; later state-6 coordinates are
                    // hover/liftoff noise, not another touch or a reversed pinch.
                    next[0].state = 6; next[0].x = 0.8; next[0].y = 0.9
                } else { next.removeFirst() }
                XCTAssertEqual(feed(&r, next, 1.24 + Double(offset) * 0.04), LRPinchNone)
            }
            XCTAssertEqual(feed(&r, [], 1.32), LRPinchCompleted)
        }
    }

    func testFastModestPinchQualifiesOnFirstBreakTouchFrame() {
        for staggered in [false, true] {
            var r = ready()
            XCTAssertEqual(feed(&r, contacts(), 1), LRPinchBegan)
            XCTAssertEqual(feed(&r, contacts(scale: 0.95), 1.04), LRPinchNone)
            // A 21% contraction needs less than the former 22% / 120 ms rules.
            // Its final inward movement arrives with the first finger's lift.
            var end = contacts(scale: 0.79, state: staggered ? 4 : 5)
            end[0].state = 5
            XCTAssertEqual(feed(&r, end, 1.08), staggered ? LRPinchNone : LRPinchCompleted)
            if staggered { XCTAssertEqual(feed(&r, [], 1.12), LRPinchCompleted) }
            XCTAssertEqual(feed(&r, [], 1.13), LRPinchNone)
        }
    }

    func testHoverCannotSupplyMissingContractionAtFirstLift() {
        for state: Int32 in [6, 7] {
            var r = ready()
            XCTAssertEqual(feed(&r, contacts(), 1), LRPinchBegan)
            XCTAssertEqual(feed(&r, contacts(scale: 0.95), 1.04), LRPinchNone)
            XCTAssertEqual(feed(&r, contacts(scale: 0.6, state: state), 1.08), LRPinchCancelled)
            XCTAssertEqual(feed(&r, [], 1.12), LRPinchNone)
        }
    }

    func testConfirmedPinchIgnoresRemainingFingerGeometryDuringLift() {
        var r = ready(); contract(&r)
        var end = contacts(scale: 0.6); end[0].state = 5
        XCTAssertEqual(feed(&r, end, 1.20), LRPinchNone)
        // These same fingers can spread or drift as the hand lifts, after the
        // pinch has already been confirmed. This must not cancel completion.
        var lifting = Array(contacts(scale: 1.3, dx: 0.15).dropFirst())
        XCTAssertEqual(feed(&r, lifting, 1.24), LRPinchNone)
        lifting[0].state = 5
        XCTAssertEqual(feed(&r, lifting, 1.28), LRPinchNone)
        XCTAssertEqual(feed(&r, [], 1.32), LRPinchCompleted)
    }

    func testConfirmedReleaseStillRejectsNewOrReturningContactsAndTimeout() {
        for mode in 0..<4 {
            var r = ready(); contract(&r)
            var end = contacts(scale: 0.6); end[0].state = 5
            XCTAssertEqual(feed(&r, end, 1.20), LRPinchNone)
            var next = Array(end.dropFirst())
            switch mode {
            case 0: next.append(LRContact(id: 99, state: 4, x: 0.8, y: 0.8))
            case 1: next = contacts(scale: 0.6)
            case 2:
                next = contacts(scale: 0.6)
                next.append(LRContact(id: 4, state: 4, x: 0.8, y: 0.8))
            default:
                XCTAssertEqual(feed(&r, next, 1.30), LRPinchNone)
                XCTAssertEqual(feed(&r, next, 1.40), LRPinchNone)
            }
            // The timeout path has no missing-frame gap to mask its cause.
            XCTAssertEqual(feed(&r, next, mode == 3 ? 1.43 : 1.24), LRPinchCancelled)
            XCTAssertEqual(feed(&r, [], 1.46), LRPinchNone)
            contract(&r, at: 2)
            XCTAssertEqual(feed(&r, [], 2.22), LRPinchCompleted)
        }
    }

    func testFastNoiseAndInsufficientInwardMovementCannotQualify() {
        for mode in 0..<3 {
            var r = ready()
            XCTAssertEqual(feed(&r, contacts(), 1), LRPinchBegan)
            // Too brief, below the inward-distance requirement, or below the
            // contraction threshold even with a wide initial finger spread.
            if mode == 2 {
                r = ready()
                XCTAssertEqual(feed(&r, contacts(scale: 1.8), 1), LRPinchBegan)
            }
            let scale: Float = mode == 0 ? 0.6 : mode == 1 ? 0.85 : 1.8 * 0.89
            XCTAssertEqual(feed(&r, contacts(scale: scale, state: 5), mode == 0 ? 1.04 : 1.08), LRPinchCancelled)
        }
    }

    func testThreeFingerTapAndFastPinchRemainDistinct() {
        for pinch in [false, true] {
            var r = ready(), tap = LRTapRecognizer()
            LRTapResetForFingerCount(&tap, 3)
            XCTAssertFalse(LRTapFrame(&tap, nil, 0, 0))
            let frames: [(Double, [LRContact])] = [
                (1, contacts()), (1.04, contacts(scale: pinch ? 0.95 : 0.99)),
                (1.08, contacts(scale: pinch ? 0.79 : 0.99, state: 5))
            ]
            var taps = 0, pinches = 0
            for (time, c) in frames {
                if feed(&r, c, time) == LRPinchCompleted { pinches += 1 }
                c.withUnsafeBufferPointer {
                    if LRTapFrame(&tap, $0.baseAddress, Int32($0.count), time) { taps += 1 }
                }
            }
            XCTAssertEqual(taps, pinch ? 0 : 1)
            XCTAssertEqual(pinches, pinch ? 1 : 0)
        }
    }

    func testTranslationAndOutwardMovementDoNotGainPinchTolerance() {
        for scale: Float in [1, 1.05, 0.95] {
            var r = ready()
            _ = feed(&r, contacts(), 1)
            XCTAssertEqual(feed(&r, contacts(scale: scale, dx: 0.1), 1.08), LRPinchCancelled)
            XCTAssertNotEqual(feed(&r, [], 1.16), LRPinchCompleted)
        }
    }

    func testDeliberatePinchAndStaggeredLiftHaveEnoughTime() {
        var r = ready()
        _ = feed(&r, Array(contacts().prefix(1)), 1)
        _ = feed(&r, Array(contacts().prefix(2)), 1.08)
        XCTAssertEqual(feed(&r, contacts(), 1.16), LRPinchBegan)
        for i in 1...10 {
            XCTAssertEqual(feed(&r, contacts(scale: 1 - Float(i) * 0.04), 1.16 + Double(i) * 0.1), LRPinchNone)
        }
        _ = feed(&r, Array(contacts(scale: 0.6).dropFirst()), 2.22)
        _ = feed(&r, Array(contacts(scale: 0.6).suffix(1)), 2.32)
        XCTAssertEqual(feed(&r, [], 2.42), LRPinchCompleted)
    }

    func testSwipeOutwardPinchJitterAndSingleMovingFingerCannotMinimize() {
        for mode in 0..<4 {
            var r = ready()
            _ = feed(&r, contacts(), 1)
            var moved = contacts(scale: mode == 1 ? 1.3 : mode == 2 ? 0.97 : 1, dx: mode == 0 ? 0.08 : 0)
            if mode == 3 { moved[0].x += 0.15; moved[0].y += 0.07 }
            XCTAssertNotEqual(feed(&r, moved, 1.08), LRPinchCompleted)
            XCTAssertNotEqual(feed(&r, moved, 1.16), LRPinchCompleted)
            XCTAssertNotEqual(feed(&r, [], 1.22), LRPinchCompleted)
        }
    }

    func testExtraFingerReplacedFingerAndReversalCancel() {
        for mode in 0..<4 {
            var r = ready(); contract(&r)
            var c = contacts(scale: 0.6)
            if mode == 0 { c.append(LRContact(id: 4, state: 4, x: 0.8, y: 0.8)) }
            if mode == 1 { c[0].id = 99 }
            if mode == 2 { c = contacts() }
            if mode == 3 { c[0].id = c[1].id }
            XCTAssertEqual(feed(&r, c, 1.22), LRPinchCancelled)
            XCTAssertNotEqual(feed(&r, [], 1.28), LRPinchCompleted)
            contract(&r, at: 2)
            XCTAssertEqual(feed(&r, [], 2.22), LRPinchCompleted)
        }
    }

    func testInvalidInputAndMissingFramesCancelOnce() {
        for mode in 0..<6 {
            var r = ready(); contract(&r)
            var c = contacts(scale: 0.6)
            if mode == 0 { c[0].x = .nan }
            if mode == 1 { c[0].state = 99 }
            if mode == 2 { c[0].y = 1.2 }
            let time = mode == 3 ? 0.5 : mode == 4 ? 1.4 : mode == 5 ? Double.nan : 1.22
            XCTAssertEqual(feed(&r, c, time), LRPinchCancelled)
            XCTAssertNotEqual(feed(&r, [], 1.5), LRPinchCompleted)
            contract(&r, at: 2)
            XCTAssertEqual(feed(&r, [], 2.22), LRPinchCompleted)
        }
        var r = ready(); contract(&r)
        XCTAssertEqual(LRPinchFrame(&r, nil, 3, 1.22), LRPinchCancelled)
        XCTAssertEqual(LRPinchFrame(&r, nil, 3, 1.23), LRPinchNone)
    }

    func testSlowAssemblyHoldAndReleaseAndReturningFingerReject() {
        var r = ready()
        _ = feed(&r, Array(contacts().prefix(1)), 1)
        XCTAssertEqual(feed(&r, contacts(), 1.19), LRPinchNone)
        XCTAssertNotEqual(feed(&r, [], 1.2), LRPinchCompleted)
        r = ready(); contract(&r)
        for i in 0..<20 { XCTAssertNotEqual(feed(&r, contacts(scale: 0.6), 1.2 + Double(i) * 0.08), LRPinchCompleted) }
        XCTAssertNotEqual(feed(&r, [], 2.8), LRPinchCompleted)
        for returning in [false, true] {
            r = ready(); contract(&r)
            _ = feed(&r, Array(contacts(scale: 0.6).dropFirst()), 1.2)
            if returning { XCTAssertEqual(feed(&r, contacts(scale: 0.6), 1.25), LRPinchCancelled) }
            else {
                _ = feed(&r, Array(contacts(scale: 0.6).dropFirst()), 1.3)
                XCTAssertEqual(feed(&r, [], 1.46), LRPinchCancelled)
            }
            XCTAssertNotEqual(feed(&r, [], 1.5), LRPinchCompleted)
        }
    }

    func testResetDuringGestureAndReleaseMotionDoNotFire() {
        var r = LRPinchRecognizer(); LRPinchReset(&r)
        XCTAssertEqual(feed(&r, contacts(), 1), LRPinchNone)
        XCTAssertEqual(feed(&r, contacts(scale: 0.6), 1.08), LRPinchNone)
        XCTAssertEqual(feed(&r, [], 1.16), LRPinchNone)
        contract(&r, at: 2); LRPinchReset(&r)
        XCTAssertEqual(feed(&r, [], 2.22), LRPinchNone)
        contract(&r, at: 3)
        XCTAssertEqual(feed(&r, contacts(scale: 0.6, dx: 0.1, state: 5), 3.22), LRPinchCancelled)
    }

    func testFourFingerTapAndThreeFingerPinchRemainDistinct() {
        var p = ready(), tap = LRTapRecognizer(); LRTapResetForFingerCount(&tap, 4)
        XCTAssertFalse(LRTapFrame(&tap, nil, 0, 0))
        for (time, c) in [(1.0, contacts()), (1.08, contacts(scale: 0.8)), (1.16, contacts(scale: 0.6)), (1.22, [])] {
            c.withUnsafeBufferPointer { XCTAssertFalse(LRTapFrame(&tap, $0.baseAddress, Int32($0.count), time)) }
        }
        var c = contacts(); c.append(LRContact(id: 4, state: 4, x: 0.8, y: 0.8))
        XCTAssertEqual(feed(&p, c, 2), LRPinchNone)
        XCTAssertEqual(feed(&p, [], 2.08), LRPinchNone)
    }

    @MainActor func testIndependentTogglesGenerationSuspensionAndDevices() {
        var generation: UInt64 = 0, begins = 0, completes = 0, taps = 0, cancels = 0
        let service = TrackpadGesture(startListening: {
            generation += 1
            return LRTrackpadResult(generation: generation, devices: 2, available: true)
        }, stopListening: {}, observeDevices: false)
        service.onTap = { taps += 1 }; service.onPinchBegin = { begins += 1 }
        service.onPinchComplete = { completes += 1 }; service.onPinchCancel = { cancels += 1 }
        service.configure(gesture: .disabled, pinch: true)
        service.deliver(1); XCTAssertEqual(taps, 0)
        service.deliverPinch(1, device: 0, event: LRPinchBegan)
        service.deliverPinch(1, device: 1, event: LRPinchCompleted)
        XCTAssertEqual(completes, 0)
        service.deliverPinch(1, device: 0, event: LRPinchCompleted)
        service.deliverPinch(1, device: 0, event: LRPinchCompleted)
        XCTAssertEqual(completes, 1)
        service.configure(gesture: .fourFingers, pinch: true)
        service.deliverPinch(1, device: 0, event: LRPinchBegan)
        XCTAssertEqual(begins, 1)
        service.deliver(2); XCTAssertEqual(taps, 1)
        service.deliverPinch(2, device: 0, event: LRPinchBegan)
        service.deliverPinch(2, device: 1, event: LRPinchBegan) // overlap cancels
        service.deliverPinch(2, device: 0, event: LRPinchCompleted)
        service.deliverPinch(2, device: 1, event: LRPinchCompleted)
        XCTAssertEqual(completes, 1)
        service.deliverPinch(2, device: 0, event: LRPinchBegan)
        let previousCancels = cancels
        service.suspend(.sleep)
        XCTAssertGreaterThan(cancels, previousCancels)
        service.deliverPinch(2, device: 0, event: LRPinchCompleted)
        XCTAssertEqual(completes, 1)
        service.resume(.sleep)
        service.configure(gesture: .fourFingers, pinch: false)
        service.deliverPinch(generation, device: 0, event: LRPinchBegan)
        XCTAssertEqual(begins, 3)
        service.deliver(generation); XCTAssertEqual(taps, 2)
        service.shutdown(); XCTAssertFalse(service.enabled)
    }

    func testPreferenceDefaultsAndIndependentPersistence() throws {
        var options = try JSONDecoder().decode(Options.self, from: Data("{}".utf8))
        XCTAssertFalse(options.threeFingerPinch)
        options.threeFingerPinch = true
        let saved = try JSONDecoder().decode(Options.self, from: JSONEncoder().encode(options))
        XCTAssertTrue(saved.threeFingerPinch); XCTAssertEqual(saved.trackpadTap, .disabled)
    }
}
