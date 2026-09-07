import Foundation
import CoreGraphics

public enum PreviewPlacement {
    /// Fit the largest possible preview beside the ring, preserving the requested aspect ratio.
    public static func frame(anchor: CGRect, avoiding occupied: CGRect, screen: CGRect,
                             preferredSize: CGSize = CGSize(width: 840, height: 630)) -> CGRect {
        let safe = screen.insetBy(dx: 8, dy: 8)
        let requested = CGSize(width: max(1, preferredSize.width), height: max(1, preferredSize.height))
        let gap = 12.0
        let free = [
            CGRect(x: max(safe.minX, occupied.maxX + gap), y: safe.minY,
                   width: max(0, safe.maxX - occupied.maxX - gap), height: safe.height),
            CGRect(x: safe.minX, y: safe.minY,
                   width: max(0, occupied.minX - gap - safe.minX), height: safe.height),
            CGRect(x: safe.minX, y: max(safe.minY, occupied.maxY + gap),
                   width: safe.width, height: max(0, safe.maxY - occupied.maxY - gap)),
            CGRect(x: safe.minX, y: safe.minY,
                   width: safe.width, height: max(0, occupied.minY - gap - safe.minY))
        ].map { $0.intersection(safe) }
        let candidates: [CGRect] = free.compactMap { area in
            guard !area.isNull, area.width > 0, area.height > 0 else { return nil }
            let scale = min(1, area.width / requested.width, area.height / requested.height)
            let size = CGSize(width: requested.width * scale, height: requested.height * scale)
            return CGRect(x: min(max(anchor.midX - size.width / 2, area.minX), area.maxX - size.width),
                          y: min(max(anchor.midY - size.height / 2, area.minY), area.maxY - size.height),
                          width: size.width, height: size.height)
        }
        let best = candidates.min { a, b in
            let areaA = a.width * a.height, areaB = b.width * b.height
            if abs(areaA - areaB) > 1 { return areaA > areaB }
            return pow(a.midX - anchor.midX, 2) + pow(a.midY - anchor.midY, 2)
                < pow(b.midX - anchor.midX, 2) + pow(b.midY - anchor.midY, 2)
        }
        if let best, best.width >= 200, best.height >= 150 { return best }
        // On exceptionally small screens there may be no readable non-overlapping placement.
        let scale = min(1, max(1, safe.width) / requested.width, max(1, safe.height) / requested.height)
        let size = CGSize(width: requested.width * scale, height: requested.height * scale)
        return CGRect(x: min(max(anchor.midX - size.width / 2, safe.minX), safe.maxX - size.width),
                      y: min(max(anchor.midY - size.height / 2, safe.minY), safe.maxY - size.height),
                      width: size.width, height: size.height)
    }
}
