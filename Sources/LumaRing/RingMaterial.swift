import AppKit
import Combine

/// One system material and one contour shared by every ring. Artwork belongs
/// inside the effect so AppKit can adapt its appearance along with the glass.
@MainActor final class RingMaterial: NSView {
    let content = NSView()
    private var effect: NSView?
    private var style: RingMaterialStyle?
    private var subscription: AnyCancellable?
    private let clipping = NSView()
    private let mask = CAShapeLayer()
    private let rim = CAShapeLayer()
    private var path: CGPath?

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        wantsLayer = true
        clipping.wantsLayer = true
        clipping.layer?.mask = mask
        addSubview(clipping)
        rim.fillColor = nil
        layer?.addSublayer(rim)
        layer?.shadowColor = NSColor.black.cgColor
        layer?.shadowOpacity = 0.24
        layer?.shadowRadius = 12
        layer?.shadowOffset = CGSize(width: 0, height: -4)
        NSWorkspace.shared.notificationCenter.addObserver(self, selector: #selector(updateContrast),
            name: NSWorkspace.accessibilityDisplayOptionsDidChangeNotification, object: nil)
        updateContrast()
        subscription = Preferences.shared.$options.map(\.ringMaterial).removeDuplicates()
            .sink { [weak self] in self?.setStyle($0) }
    }
    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }
    deinit { NSWorkspace.shared.notificationCenter.removeObserver(self) }

    func setStyle(_ requested: RingMaterialStyle) {
        let value = requested.resolved
        guard style != value else { return }
        style = value
        if #available(macOS 26.0, *), value != .frosted, let glass = effect as? NSGlassEffectView {
            glass.style = value == .clear ? .clear : .regular
            return
        }
        if #available(macOS 26.0, *), let glass = effect as? NSGlassEffectView { glass.contentView = nil }
        content.removeFromSuperview()
        effect?.removeFromSuperview()
        let replacement: NSView
        if #available(macOS 26.0, *), value != .frosted {
            let glass = NSGlassEffectView()
            glass.style = value == .clear ? .clear : .regular
            glass.contentView = content
            replacement = glass
        } else {
            let frost = Self.makeFrostedEffect()
            frost.addSubview(content)
            replacement = frost
        }
        effect = replacement
        clipping.addSubview(replacement)
        if let path {
            self.path = nil
            setShape(path)
        }
    }

    static func makeFrostedEffect() -> NSVisualEffectView {
        let frost = NSVisualEffectView()
        frost.material = .popover
        frost.blendingMode = .behindWindow
        // The action ring deliberately never becomes key.
        frost.state = .active
        return frost
    }

    override func viewDidChangeEffectiveAppearance() { super.viewDidChangeEffectiveAppearance(); updateContrast() }
    @objc private func updateContrast() {
        let dark = effectiveAppearance.bestMatch(from: [.aqua, .darkAqua]) == .darkAqua
        let contrast = NSWorkspace.shared.accessibilityDisplayShouldIncreaseContrast
        CATransaction.begin(); CATransaction.setDisableActions(true)
        rim.strokeColor = (dark ? NSColor.white : NSColor.black).withAlphaComponent(contrast ? 0.5 : 0.18).cgColor
        rim.lineWidth = contrast ? 1.5 : 0.75
        CATransaction.commit()
    }

    func setShape(_ path: CGPath) {
        guard self.path != path, let effect else { return }
        self.path = path
        let rect = path.boundingBoxOfPath.integral
        var translation = CGAffineTransform(translationX: -rect.minX, y: -rect.minY)
        CATransaction.begin(); CATransaction.setDisableActions(true)
        clipping.frame = rect
        effect.frame = clipping.bounds
        mask.frame = clipping.bounds
        mask.path = path.copy(using: &translation)
        if #available(macOS 26.0, *), let glass = effect as? NSGlassEffectView {
            // Native circular glass for the primary/launcher disks; the joined
            // secondary contour is clipped once, without overlapping materials.
            glass.cornerRadius = path == CGPath(ellipseIn: path.boundingBoxOfPath, transform: nil) ? rect.width / 2 : 0
        }
        content.frame = effect.bounds
        content.bounds = rect
        rim.path = path
        layer?.shadowPath = path
        CATransaction.commit()
    }

    override func hitTest(_ point: NSPoint) -> NSView? { nil }
}

@MainActor final class RingArtwork: NSView {
    var render: (() -> Void)?
    override var isOpaque: Bool { false }
    override func viewDidChangeEffectiveAppearance() { super.viewDidChangeEffectiveAppearance(); needsDisplay = true }
    override func draw(_ dirtyRect: NSRect) { render?() }
    override func hitTest(_ point: NSPoint) -> NSView? { nil }
}
