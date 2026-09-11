import AppKit

/// Fully opaque white/black surface following the app's effective appearance.
@MainActor final class RingMaterial: NSView {
    private let shape = CAShapeLayer()
    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        wantsLayer = true
        layer?.addSublayer(shape)
        layer?.shadowColor = NSColor.black.cgColor
        layer?.shadowOpacity = 0.15
        layer?.shadowRadius = 9
        layer?.shadowOffset = CGSize(width: 0, height: -3)
        updateColor()
    }
    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }
    override func viewDidChangeEffectiveAppearance() { super.viewDidChangeEffectiveAppearance(); updateColor() }
    private func updateColor() {
        let dark = effectiveAppearance.bestMatch(from: [.aqua, .darkAqua]) == .darkAqua
        CATransaction.begin(); CATransaction.setDisableActions(true)
        shape.fillColor = (dark ? NSColor.black : NSColor.white).cgColor
        CATransaction.commit()
    }
    func setShape(_ path: CGPath) {
        CATransaction.begin(); CATransaction.setDisableActions(true)
        shape.path = path
        layer?.shadowPath = path
        CATransaction.commit()
    }
    override func hitTest(_ point: NSPoint) -> NSView? { nil }
}

@MainActor final class RingArtwork: NSView {
    var render: (() -> Void)?
    override var isOpaque: Bool { false }
    override func draw(_ dirtyRect: NSRect) { render?() }
    override func hitTest(_ point: NSPoint) -> NSView? { nil }
}
