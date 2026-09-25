import AppKit

/// Keep accessibility targets stable across redraws. Removed targets are disabled
/// and release their action, even if an accessibility client still holds them.
@MainActor final class RingAccessibility {
    struct Entry {
        let id: String
        let label: String
        var help = ""
        let rect: CGRect
        var enabled = true
        let action: () -> Void
    }

    private var items: [String: RingAccessibleItem] = [:]

    func update(_ entries: [Entry], in view: NSView) {
        guard let window = view.window else { clear(in: view); return }
        var next: [String: RingAccessibleItem] = [:]
        let children = entries.map { entry in
            let item = items[entry.id] ?? RingAccessibleItem()
            item.setAccessibilityRole(.button)
            item.setAccessibilityLabel(entry.label)
            item.setAccessibilityHelp(entry.help)
            item.setAccessibilityEnabled(entry.enabled)
            item.setAccessibilityParent(view)
            item.setAccessibilityFrame(window.convertToScreen(view.convert(entry.rect, to: nil)))
            item.action = entry.action
            next[entry.id] = item
            return item
        }
        for (id, item) in items where next[id] == nil { item.invalidate() }
        items = next
        view.setAccessibilityElement(false)
        view.setAccessibilityChildren(children)
    }

    func clear(in view: NSView) {
        items.values.forEach { $0.invalidate() }
        items.removeAll()
        view.setAccessibilityChildren([])
    }
}

final class RingAccessibleItem: NSAccessibilityElement {
    var action: (() -> Void)?
    func invalidate() {
        action = nil
        setAccessibilityEnabled(false)
        setAccessibilityParent(nil)
    }
    override func accessibilityPerformPress() -> Bool {
        guard isAccessibilityEnabled(), let action else { return false }
        action()
        return true
    }
}
