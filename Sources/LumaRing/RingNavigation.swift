import AppKit
import LumaRingCore

enum RingNavigation: Equatable {
    case step(Int), toggleSecondary, activate

    static let keyCodes: [CGKeyCode] = [48, 50, 36, 76]

    static func command(for event: NSEvent, reserving shortcuts: [Shortcut] = []) -> Self? {
        guard event.type == .keyDown, !shortcuts.contains(where: { $0.matches(event) }),
              event.modifierFlags.intersection([.command, .control]).isEmpty else { return nil }
        // Option can navigate favorites unless the chord is reserved for invocation.
        switch event.keyCode {
        case 48: return .step(event.modifierFlags.contains(.shift) ? -1 : 1)
        case 50: return .toggleSecondary // Physical ` / ~ key, left of 1.
        case 36, 76: return .activate
        default: return nil
        }
    }

    var repeats: Bool { if case .step = self { return true }; return false }

    static func next(current: Int?, pageStart: Int, total: Int, direction: Int) -> Int? {
        guard total > 0 else { return nil }
        return RingGeometry.wrapped(current.map { $0 + direction } ?? (direction > 0 ? pageStart : pageStart - 1), count: total)
    }
}
