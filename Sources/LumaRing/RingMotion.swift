import AppKit
import LumaRingCore

/// Presentation-only motion. Selection always uses the resting ring geometry.
@MainActor enum RingMotion {
    static var reduced: Bool { NSWorkspace.shared.accessibilityDisplayShouldReduceMotion }
    static let closingDuration = 0.12

    private static func restingTransform(_ view: NSView) -> CATransform3D {
        // Ring views use a fixed 480-point canvas inside a user-sized panel.
        // Preserve AppKit's frame/bounds scale when animating their backing layer.
        CATransform3DMakeScale(view.frame.width / max(1, view.bounds.width),
                              view.frame.height / max(1, view.bounds.height), 1)
    }

    static func pose(scale: CGFloat = 1, x: CGFloat = 0, y: CGFloat = 0, rotation: CGFloat = 0) -> CATransform3D {
        var transform = CATransform3DMakeTranslation(x, y, 0)
        transform = CATransform3DRotate(transform, rotation, 0, 0, 1)
        return CATransform3DScale(transform, scale, scale, 1)
    }

    static func center(_ view: NSView) {
        guard let layer = view.layer else { return }
        CATransaction.begin(); CATransaction.setDisableActions(true)
        layer.anchorPoint = CGPoint(x: 0.5, y: 0.5)
        layer.position = CGPoint(x: view.frame.midX, y: view.frame.midY)
        CATransaction.commit()
    }

    static func spring(_ layer: CALayer, to target: CATransform3D, from initial: CATransform3D? = nil,
                       delay: TimeInterval = 0, animated: Bool = true) {
        let start = initial ?? layer.presentation()?.transform ?? layer.transform
        CATransaction.begin(); CATransaction.setDisableActions(true)
        layer.transform = target
        CATransaction.commit()
        guard animated, !reduced else { layer.removeAnimation(forKey: "pose"); return }
        let animation = CASpringAnimation(keyPath: "transform")
        animation.mass = 1; animation.stiffness = 520; animation.damping = 30
        animation.fromValue = NSValue(caTransform3D: start)
        animation.toValue = NSValue(caTransform3D: target)
        animation.duration = animation.settlingDuration
        animation.beginTime = layer.convertTime(CACurrentMediaTime(), from: nil) + delay
        animation.fillMode = .backwards
        layer.add(animation, forKey: "pose")
    }

    static func fade(_ layer: CALayer, from: Float? = nil, to: Float, duration: TimeInterval, delay: TimeInterval = 0) {
        let start = from ?? layer.presentation()?.opacity ?? layer.opacity
        CATransaction.begin(); CATransaction.setDisableActions(true)
        layer.opacity = to
        CATransaction.commit()
        let animation = CABasicAnimation(keyPath: "opacity")
        animation.fromValue = start; animation.toValue = to
        animation.duration = duration
        animation.beginTime = layer.convertTime(CACurrentMediaTime(), from: nil) + delay
        animation.fillMode = .backwards
        animation.timingFunction = CAMediaTimingFunction(name: .easeOut)
        layer.add(animation, forKey: "opacity")
    }

    static func open(_ view: NSView) {
        view.wantsLayer = true
        center(view)
        guard let layer = view.layer else { return }
        let resting = restingTransform(view)
        spring(layer, to: resting, from: CATransform3DScale(resting, 0.86, 0.86, 1))
        fade(layer, from: 0, to: 1, duration: 0.14)
    }

    static func close(_ view: NSView) {
        guard let layer = view.layer else { return }
        if !reduced {
            let animation = CABasicAnimation(keyPath: "transform")
            animation.fromValue = NSValue(caTransform3D: layer.presentation()?.transform ?? layer.transform)
            animation.toValue = NSValue(caTransform3D: CATransform3DScale(restingTransform(view), 0.94, 0.94, 1))
            animation.duration = closingDuration
            animation.timingFunction = CAMediaTimingFunction(name: .easeIn)
            layer.add(animation, forKey: "pose")
        }
        fade(layer, to: 0, duration: closingDuration)
    }

    static func reset(_ view: NSView) {
        view.layer?.removeAllAnimations()
        CATransaction.begin(); CATransaction.setDisableActions(true)
        view.layer?.transform = restingTransform(view)
        view.layer?.opacity = 1
        CATransaction.commit()
    }
}

/// A small cached drawing surface, optionally backed by native glass.
/// AppKit owns layout; Core Animation owns only the visual offset and scale.
@MainActor final class RingTile: NSView {
    let artwork = RingArtwork()
    private let material: RingMaterial?
    private var target = CATransform3DIdentity

    init(glass: Bool) {
        material = glass ? RingMaterial() : nil
        super.init(frame: .zero)
        wantsLayer = true
        if let material {
            material.layer?.shadowOpacity = 0.10
            material.layer?.shadowRadius = 6
            addSubview(material); material.content.addSubview(artwork)
        }
        else { addSubview(artwork) }
    }
    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }
    override func hitTest(_ point: NSPoint) -> NSView? { nil }

    func place(in rect: CGRect, shape: CGPath? = nil) {
        if frame != rect {
            RingMotion.reset(self)
            target = CATransform3DIdentity
            frame = rect
        }
        material?.frame = bounds
        var translation = CGAffineTransform(translationX: -rect.minX, y: -rect.minY)
        if let path = shape?.copy(using: &translation) { material?.setShape(path) }
        artwork.frame = bounds
        // Existing drawing functions and accessibility frames share ring coordinates.
        artwork.bounds = rect
        RingMotion.center(self)
    }

    func update(highlighted: Bool, animated: Bool) {
        let angle = atan2(frame.midY - RingGeometry.center.y, frame.midX - RingGeometry.center.x)
        let lift: CGFloat = highlighted && !RingMotion.reduced ? (material == nil ? 3 : 2) : 0
        let scale: CGFloat = highlighted && !RingMotion.reduced ? (material == nil ? 1.12 : 1.025) : 1
        let next = RingMotion.pose(scale: scale, x: cos(angle) * lift, y: sin(angle) * lift)
        if !CATransform3DEqualToTransform(target, next), let layer {
            target = next
            RingMotion.spring(layer, to: next, animated: animated)
        }
        layer?.zPosition = highlighted ? 1 : 0
        artwork.needsDisplay = true
    }

    func reveal(index: Int, count: Int, secondary: Bool) {
        guard let layer else { return }
        let distance: CGFloat = secondary ? 24 : 20
        let angle = atan2(frame.midY - RingGeometry.center.y, frame.midX - RingGeometry.center.x)
        let delay = RingMotion.reduced ? 0 : Double(index) / Double(max(count - 1, 1)) * 0.045
        let initial = RingMotion.pose(scale: 0.72, x: -cos(angle) * distance,
            y: -sin(angle) * distance, rotation: secondary ? 0 : 0.06)
        RingMotion.spring(layer, to: target, from: initial, delay: delay)
        RingMotion.fade(layer, from: 0, to: 1, duration: 0.12, delay: delay)
    }
}
