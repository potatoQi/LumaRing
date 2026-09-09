import Foundation
import CoreGraphics

/// All geometry is expressed in AppKit's upward-positive coordinate space.
public struct RingGeometry {
    public static let canvas: Double = 480
    public static let center = CGPoint(x: 240, y: 240)
    public static let appInner: Double = 40
    public static let appOuter: Double = 118
    public static let appRadius: Double = 88
    public static let windowInner: Double = 118
    public static let windowOuter: Double = 198
    public static let windowRadius: Double = 158
    public static let pageSize = 8
    public static let windowPageSize = 6
    public static let windowPageSizeRange = 2...8
    public static let arcStep: Double = 32 * .pi / 180

    /// The entire primary disk outside its neutral center is selectable.
    public static func appIndex(at point: CGPoint, count: Int) -> Int? {
        index(at: point, count: count, inner: appInner, outer: appOuter)
    }

    public static func appSectorPath(index: Int, count: Int) -> CGPath {
        let path = CGMutablePath()
        guard count > 0, index >= 0, index < count else { return path }
        let middle = angle(index: index, count: count)
        let half = Double.pi / Double(count)
        let start = middle - half, end = middle + half
        path.move(to: point(angle: start, radius: appInner))
        path.addLine(to: point(angle: start, radius: appOuter))
        path.addArc(center: center, radius: appOuter, startAngle: start, endAngle: end, clockwise: false)
        path.addLine(to: point(angle: end, radius: appInner))
        path.addArc(center: center, radius: appInner, startAngle: end, endAngle: start, clockwise: true)
        path.closeSubpath()
        return path
    }

    public static func arcAngle(index: Int, count: Int, anchor: Double) -> Double {
        anchor + (Double(count - 1) / 2 - Double(index)) * arcStep
    }

    public static func arcPath(count: Int, anchor: Double) -> CGPath {
        let path = CGMutablePath()
        guard count > 0 else { return path }
        let half = arcHalfAngle(count: count)
        let start = anchor - half, end = anchor + half
        path.move(to: point(angle: start, radius: windowOuter))
        path.addArc(center: center, radius: windowOuter, startAngle: start, endAngle: end, clockwise: false)
        path.addLine(to: point(angle: end, radius: windowInner))
        path.addArc(center: center, radius: windowInner, startAngle: end, endAngle: start, clockwise: true)
        path.closeSubpath()
        return path
    }

    public static func arcHalfAngle(count: Int) -> Double {
        (Double(max(count, 1) - 1) / 2 + 0.65) * arcStep
    }

    /// One outer contour: no internal edge or antialiased seam between the disk and sector.
    public static func surfacePath(windowCount: Int, anchor: Double) -> CGPath {
        let path = CGMutablePath()
        guard windowCount > 0 else {
            path.addEllipse(in: CGRect(x: center.x - appOuter, y: center.y - appOuter,
                                       width: appOuter * 2, height: appOuter * 2))
            return path
        }
        let start = anchor - arcHalfAngle(count: windowCount)
        let end = anchor + arcHalfAngle(count: windowCount)
        path.move(to: point(angle: start, radius: appOuter))
        path.addLine(to: point(angle: start, radius: windowOuter))
        path.addArc(center: center, radius: windowOuter, startAngle: start, endAngle: end, clockwise: false)
        path.addLine(to: point(angle: end, radius: appOuter))
        path.addArc(center: center, radius: appOuter, startAngle: end, endAngle: start + .pi * 2, clockwise: false)
        path.closeSubpath()
        return path
    }

    public static func arcIndex(at point: CGPoint, count: Int, anchor: Double) -> Int? {
        guard count > 0, arcPath(count: count, anchor: anchor).contains(point) else { return nil }
        let angle = atan2(point.y - center.y, point.x - center.x)
        let relative = atan2(sin(anchor - angle), cos(anchor - angle))
        let index = Int((relative / arcStep + Double(count - 1) / 2).rounded())
        return min(count - 1, max(0, index))
    }

    public static func normalized(_ angle: Double) -> Double {
        let a = angle.truncatingRemainder(dividingBy: .pi * 2)
        return a < 0 ? a + .pi * 2 : a
    }

    public static func angle(index: Int, count: Int) -> Double {
        .pi / 2 - Double(index) * .pi * 2 / Double(max(count, 1))
    }

    public static func point(angle: Double, radius: Double) -> CGPoint {
        CGPoint(x: center.x + cos(angle) * radius, y: center.y + sin(angle) * radius)
    }

    public static func index(at point: CGPoint, count: Int, inner: Double, outer: Double) -> Int? {
        guard count > 0, inner >= 0, outer >= inner else { return nil }
        let dx = point.x - center.x, dy = point.y - center.y
        let radius = hypot(dx, dy)
        guard radius >= inner, radius <= outer else { return nil }
        let step = .pi * 2 / Double(count)
        let clockwise = normalized(.pi / 2 - atan2(dy, dx) + step / 2)
        return min(count - 1, Int(clockwise / step))
    }

    public static func pageCount(total: Int, size: Int = pageSize) -> Int {
        guard size > 0 else { return 1 }
        return max(1, (max(total, 0) + size - 1) / size)
    }

    public static func pageRange(page: Int, total: Int, size: Int = pageSize) -> Range<Int> {
        guard total > 0, size > 0 else { return 0..<0 }
        let p = min(max(0, page), pageCount(total: total, size: size) - 1)
        let start = p * size
        return start..<min(start + size, total)
    }

    public static func wrapped(_ index: Int, count: Int) -> Int {
        guard count > 0 else { return 0 }
        return ((index % count) + count) % count
    }

    public static func panelFrame(pointer: CGPoint, visibleFrame: CGRect, preferredSize: Double) -> CGRect {
        let available = max(1, min(visibleFrame.width, visibleFrame.height) - 16)
        let size = min(max(320, preferredSize), available)
        let x = min(max(pointer.x - size / 2, visibleFrame.minX + 8), visibleFrame.maxX - size - 8)
        let y = min(max(pointer.y - size / 2, visibleFrame.minY + 8), visibleFrame.maxY - size - 8)
        return CGRect(x: x, y: y, width: size, height: size)
    }
}

/// Monotonic tickets prevent a late window query from painting another app's ring.
public struct RequestGate {
    public private(set) var generation: UInt64 = 0
    public init() {}
    @discardableResult public mutating func invalidate() -> UInt64 {
        generation &+= 1
        return generation
    }
    public func accepts(_ ticket: UInt64) -> Bool { ticket == generation }
}
