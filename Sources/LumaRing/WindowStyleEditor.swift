import AppKit

enum SectorColor: String, CaseIterable, Codable {
    case red, orange, amber, yellow, lime, green, mint, teal, sky, blue, violet, pink
    var color: NSColor {
        let hex: UInt32
        switch self {
        case .red: hex = 0xE45C5C
        case .orange: hex = 0xE98A42
        case .amber: hex = 0xCE9A35
        case .yellow: hex = 0xC7B63E
        case .lime: hex = 0x89AE46
        case .green: hex = 0x4F9C68
        case .mint: hex = 0x4DAA8B
        case .teal: hex = 0x459DAB
        case .sky: hex = 0x599FCB
        case .blue: hex = 0x607FCD
        case .violet: hex = 0x9572C5
        case .pink: hex = 0xCE72A1
        }
        return NSColor(srgbRed: CGFloat((hex >> 16) & 255) / 255, green: CGFloat((hex >> 8) & 255) / 255,
                       blue: CGFloat(hex & 255) / 255, alpha: 1)
    }
    var title: String {
        switch self {
        case .red: return L10n.text("红色", "Red")
        case .orange: return L10n.text("橙色", "Orange")
        case .amber: return L10n.text("琥珀色", "Amber")
        case .yellow: return L10n.text("黄色", "Yellow")
        case .lime: return L10n.text("草绿色", "Lime")
        case .green: return L10n.text("绿色", "Green")
        case .mint: return L10n.text("薄荷色", "Mint")
        case .teal: return L10n.text("青色", "Teal")
        case .sky: return L10n.text("天蓝色", "Sky")
        case .blue: return L10n.text("蓝色", "Blue")
        case .violet: return L10n.text("紫色", "Violet")
        case .pink: return L10n.text("粉色", "Pink")
        }
    }
}

@MainActor final class WindowStyleEditor: NSWindowController, NSWindowDelegate {
    let nameField = EditableNameField()
    private(set) var selectedColor: SectorColor?
    private(set) var colorButtons: [SectorColorButton] = []
    private let message = NSTextField(wrappingLabelWithString: L10n.text("名称留空时使用原标题。", "Leave the name empty to use the original title."))
    var onSave: ((String, SectorColor?) -> Bool)?
    var onCancel: (() -> Void)?

    init(record: WindowRecord) {
        let panel = RingPanel(contentRect: NSRect(x: 0, y: 0, width: 360, height: 330),
                              styleMask: [.titled, .closable, .nonactivatingPanel], backing: .buffered, defer: false)
        super.init(window: panel)
        panel.title = L10n.text("修改", "Edit")
        panel.level = NSWindow.Level(rawValue: NSWindow.Level.popUpMenu.rawValue + 2)
        panel.isReleasedWhenClosed = false
        panel.hidesOnDeactivate = false
        panel.isFloatingPanel = true
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
        panel.delegate = self
        let content = WindowEditorContent(frame: NSRect(x: 0, y: 0, width: 360, height: 330))
        panel.contentView = content
        func label(_ text: String, y: CGFloat) {
            let label = NSTextField(labelWithString: text)
            label.font = .systemFont(ofSize: 13, weight: .medium)
            label.frame = NSRect(x: 22, y: y, width: 180, height: 20)
            content.addSubview(label)
        }
        label(L10n.text("名称", "Name"), y: 280)
        nameField.stringValue = record.customName ?? ""
        nameField.placeholderString = record.title
        nameField.frame = NSRect(x: 22, y: 245, width: 316, height: 28)
        nameField.setAccessibilityLabel(L10n.text("轮盘显示名称", "Name in LumaRing"))
        content.addSubview(nameField)
        label(L10n.text("扇形颜色", "Sector Color"), y: 205)
        selectedColor = record.customColor
        for (index, color) in SectorColor.allCases.enumerated() {
            let button = SectorColorButton(color: color)
            button.frame = NSRect(x: 27 + (index % 6) * 54, y: 154 - (index / 6) * 44, width: 36, height: 36)
            button.tag = index; button.target = self; button.action = #selector(pickColor(_:))
            content.addSubview(button); colorButtons.append(button)
        }
        func button(_ title: String, frame: NSRect, action: Selector, key: String = "") {
            let button = NSButton(title: title, target: self, action: action)
            button.bezelStyle = .rounded; button.frame = frame; button.keyEquivalent = key
            content.addSubview(button)
        }
        button(L10n.text("默认颜色", "Default Color"), frame: NSRect(x: 226, y: 199, width: 118, height: 28), action: #selector(resetColor))
        message.frame = NSRect(x: 22, y: 57, width: 316, height: 35)
        message.font = .systemFont(ofSize: 11); message.textColor = .secondaryLabelColor
        content.addSubview(message)
        button(L10n.text("取消", "Cancel"), frame: NSRect(x: 166, y: 17, width: 82, height: 32), action: #selector(cancelEditing), key: "\u{1b}")
        button(L10n.text("保存", "Save"), frame: NSRect(x: 258, y: 17, width: 82, height: 32), action: #selector(saveEditing), key: "\r")
        panel.initialFirstResponder = nameField
        refreshColors()
    }
    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }
    func show(near anchor: CGRect, screen: CGRect) {
        guard let window else { return }
        let size = window.frame.size
        let proposedX = anchor.maxX + 12 + size.width <= screen.maxX ? anchor.maxX + 12 : anchor.minX - size.width - 12
        window.setFrameOrigin(CGPoint(x: min(max(proposedX, screen.minX + 8), screen.maxX - size.width - 8),
                                     y: min(max(anchor.midY - size.height / 2, screen.minY + 8), screen.maxY - size.height - 8)))
        window.makeKeyAndOrderFront(nil)
        window.makeFirstResponder(nameField); nameField.selectText(nil)
    }
    func dismiss() { window?.orderOut(nil) }
    func selectColor(_ color: SectorColor?) { selectedColor = color; refreshColors() }
    private func refreshColors() {
        for button in colorButtons { button.state = button.color == selectedColor ? .on : .off; button.needsDisplay = true }
    }
    @objc private func pickColor(_ sender: NSButton) { selectColor(SectorColor.allCases[sender.tag]) }
    @objc private func resetColor() { selectColor(nil) }
    @objc func saveEditing() {
        if onSave?(nameField.stringValue, selectedColor) != true {
            message.stringValue = L10n.text("未能保存修改。窗口可能已关闭，请取消后重试。", "Could not save changes. The window may have closed; cancel and try again.")
            message.textColor = .systemOrange
        }
    }
    @objc func cancelEditing() { onCancel?() }
    func windowShouldClose(_ sender: NSWindow) -> Bool { cancelEditing(); return false }
}

@MainActor final class SectorColorButton: NSButton {
    let color: SectorColor
    init(color: SectorColor) {
        self.color = color
        super.init(frame: .zero)
        title = ""; isBordered = false
        setAccessibilityLabel(color.title); toolTip = color.title
    }
    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }
    override func draw(_ dirtyRect: NSRect) {
        color.color.setFill()
        NSBezierPath(ovalIn: bounds.insetBy(dx: 4, dy: 4)).fill()
        if state == .on {
            NSColor.labelColor.setStroke()
            let outline = NSBezierPath(ovalIn: bounds.insetBy(dx: 1, dy: 1)); outline.lineWidth = 2; outline.stroke()
            let check = NSImage(systemSymbolName: "checkmark", accessibilityDescription: nil)
            check?.withSymbolConfiguration(.init(paletteColors: [.white]))?.draw(in: bounds.insetBy(dx: 10, dy: 10))
        }
    }
}

/// Clipboard shortcuts work even when the switcher's main menu has no Edit menu.
@MainActor final class EditableNameField: NSTextField {
    override func performKeyEquivalent(with event: NSEvent) -> Bool {
        guard event.modifierFlags.intersection([.command, .control, .option, .shift]) == .command,
              let editor = currentEditor() else { return super.performKeyEquivalent(with: event) }
        switch event.charactersIgnoringModifiers?.lowercased() {
        case "a": editor.selectAll(nil)
        case "c": editor.copy(nil)
        case "v": editor.paste(nil)
        case "x": editor.cut(nil)
        default: return super.performKeyEquivalent(with: event)
        }
        return true
    }
}

@MainActor private final class WindowEditorContent: NSView {
    override var isOpaque: Bool { true }
    override func draw(_ dirtyRect: NSRect) { NSColor.windowBackgroundColor.setFill(); dirtyRect.fill() }
}
