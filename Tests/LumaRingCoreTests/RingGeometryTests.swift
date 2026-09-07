import XCTest
import CoreGraphics
@testable import LumaRingCore

final class RingGeometryTests: XCTestCase {
    func testWindowArcFollowsEveryAppAndNeverWrapsIntoFullRing() {
        for app in 0..<8 {
            let anchor = RingGeometry.angle(index: app, count: 8)
            for count in 1...RingGeometry.windowPageSizeRange.upperBound {
                let path = RingGeometry.arcPath(count: count, anchor: anchor)
                XCTAssertTrue(CGRect(x: 0, y: 0, width: 480, height: 480).contains(path.boundingBoxOfPath))
                for index in 0..<count {
                    let p = RingGeometry.point(angle: RingGeometry.arcAngle(index: index, count: count, anchor: anchor), radius: RingGeometry.windowRadius)
                    XCTAssertEqual(RingGeometry.arcIndex(at: p, count: count, anchor: anchor), index)
                }
                XCTAssertNil(RingGeometry.arcIndex(at: RingGeometry.point(angle: anchor + .pi, radius: RingGeometry.windowRadius), count: count, anchor: anchor))
                XCTAssertNil(RingGeometry.arcIndex(at: RingGeometry.center, count: count, anchor: anchor))
                XCTAssertNil(RingGeometry.arcIndex(at: RingGeometry.point(angle: anchor, radius: 117), count: count, anchor: anchor))
            }
        }
    }

    func testAttachedArcHasNoRadialGap() {
        XCTAssertEqual(RingGeometry.appOuter, RingGeometry.windowInner)
        for count in 1...RingGeometry.windowPageSizeRange.upperBound {
            let path = RingGeometry.arcPath(count: count, anchor: .pi / 2)
            XCTAssertTrue(path.contains(RingGeometry.point(angle: .pi / 2, radius: RingGeometry.appOuter + 0.05)))
        }
    }

    func testLargePreviewPlacementAvoidsRingAndStaysOnScreen() {
        for screen in [CGRect(x: 0, y: 0, width: 1440, height: 900), CGRect(x: -1920, y: -200, width: 1920, height: 1080)] {
            let occupied = CGRect(x: screen.midX - 200, y: screen.midY - 200, width: 400, height: 400)
            for anchor in [CGRect(x: occupied.maxX - 70, y: occupied.midY, width: 70, height: 58),
                           CGRect(x: occupied.minX, y: occupied.midY, width: 70, height: 58)] {
                let frame = PreviewPlacement.frame(anchor: anchor, avoiding: occupied, screen: screen, preferredSize: CGSize(width: 440, height: 340))
                XCTAssertTrue(screen.contains(frame))
                XCTAssertFalse(frame.intersects(occupied))
                XCTAssertEqual(frame.width, 440)
                XCTAssertEqual(frame.height, 340)
            }
        }
        let small = CGRect(x: -400, y: 120, width: 400, height: 300)
        XCTAssertTrue(small.contains(PreviewPlacement.frame(anchor: small, avoiding: small, screen: small)))
    }

    func testSectorJoinsDiskAcrossItsEntireWidthWithoutRoundCaps() {
        for count in RingGeometry.windowPageSizeRange {
            for anchor in [0.0, .pi / 2, .pi, .pi * 1.75] {
                let half = RingGeometry.arcHalfAngle(count: count)
                let arc = RingGeometry.arcPath(count: count, anchor: anchor)
                let surface = RingGeometry.surfacePath(windowCount: count, anchor: anchor)
                for fraction in stride(from: -0.99, through: 0.99, by: 0.03) {
                    let angle = anchor + half * fraction
                    XCTAssertTrue(arc.contains(RingGeometry.point(angle: angle, radius: 118.1)))
                    XCTAssertTrue(surface.contains(RingGeometry.point(angle: angle, radius: 117.9)))
                    XCTAssertTrue(surface.contains(RingGeometry.point(angle: angle, radius: 118.1)))
                }
                for edge in [-1.0, 1.0] {
                    XCTAssertFalse(arc.contains(RingGeometry.point(angle: anchor + edge * (half + 0.01), radius: 158)))
                }
            }
        }
    }

    func testConfigurablePreviewFitsWithoutCoveringRing() {
        let screen = CGRect(x: -1440, y: 0, width: 1440, height: 900)
        let occupied = CGRect(x: -900, y: 280, width: 360, height: 340)
        let anchor = CGRect(x: -600, y: 400, width: 50, height: 50)
        for width in [400.0, 640, 960] {
            let result = PreviewPlacement.frame(anchor: anchor, avoiding: occupied, screen: screen,
                                                preferredSize: CGSize(width: width, height: width * 0.75))
            XCTAssertTrue(screen.insetBy(dx: 8, dy: 8).contains(result))
            XCTAssertFalse(result.intersects(occupied))
            XCTAssertLessThanOrEqual(result.width, width)
            XCTAssertEqual(result.width / result.height, 4.0 / 3, accuracy: 0.001)
        }
    }

    func testEverySectorCenterAndWrapBoundary() {
        for count in 1...16 {
            for index in 0..<count {
                let angle = RingGeometry.angle(index: index, count: count)
                let point = RingGeometry.point(angle: angle, radius: 88)
                XCTAssertEqual(RingGeometry.index(at: point, count: count, inner: 60, outer: 118), index)
                for offset in [-0.49, 0.49] {
                    let edge = RingGeometry.point(angle: angle + offset * .pi * 2 / Double(count), radius: 88)
                    XCTAssertEqual(RingGeometry.index(at: edge, count: count, inner: 60, outer: 118), index)
                }
            }
        }
    }

    func testDeadZoneAndBridgeDoNotSelectDifferentApps() {
        for radius in [0.0, 59, 119, 198, 240] {
            XCTAssertNil(RingGeometry.index(at: RingGeometry.point(angle: 1, radius: radius), count: 8, inner: 60, outer: 118))
        }
        XCTAssertNil(RingGeometry.index(at: .zero, count: 0, inner: 0, outer: 500))
    }

    func testPaginationNeverLosesOrDuplicatesItems() {
        for total in 0...200 {
            let indices = (0..<RingGeometry.pageCount(total: total)).flatMap {
                Array(RingGeometry.pageRange(page: $0, total: total))
            }
            XCTAssertEqual(indices, Array(0..<total))
        }
        XCTAssertEqual(RingGeometry.pageRange(page: 99, total: 9), 8..<9)
        XCTAssertEqual(RingGeometry.pageRange(page: -1, total: 9), 0..<8)
    }

    func testScreenClampingIncludingNegativeMonitorOrigins() {
        for screen in [CGRect(x: 0, y: 0, width: 1440, height: 875),
                       CGRect(x: -1920, y: -200, width: 1920, height: 1080),
                       CGRect(x: 1440, y: 300, width: 600, height: 460)] {
            for pointer in [screen.origin, CGPoint(x: screen.maxX, y: screen.maxY),
                            CGPoint(x: screen.midX, y: screen.midY)] {
                let frame = RingGeometry.panelFrame(pointer: pointer, visibleFrame: screen, preferredSize: 680)
                XCTAssertTrue(screen.contains(frame))
                XCTAssertEqual(frame.width, frame.height)
            }
        }
    }

    func testOutOfOrderResultsAndDismissAreRejected() {
        var gate = RequestGate()
        let safari = gate.invalidate()
        let finder = gate.invalidate()
        XCTAssertFalse(gate.accepts(safari))
        XCTAssertTrue(gate.accepts(finder))
        gate.invalidate() // dismiss
        XCTAssertFalse(gate.accepts(finder))
    }

    func testKeyboardWrapping() {
        XCTAssertEqual(RingGeometry.wrapped(-1, count: 8), 7)
        XCTAssertEqual(RingGeometry.wrapped(8, count: 8), 0)
        XCTAssertEqual(RingGeometry.wrapped(12, count: 0), 0)
    }
}
