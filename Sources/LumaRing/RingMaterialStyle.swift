import Foundation

enum RingMaterialStyle: String, Codable, CaseIterable {
    case regular, clear, frosted

    static var supportsGlass: Bool {
        if #available(macOS 26.0, *) { return true }
        return false
    }
    static var defaultValue: Self { supportsGlass ? .regular : .frosted }
    var isAvailable: Bool { self == .frosted || Self.supportsGlass }
    var resolved: Self { isAvailable ? self : .frosted }

    var title: String {
        switch self {
        case .regular: return L10n.text("液态玻璃 · 常规", "Liquid Glass · Regular")
        case .clear: return L10n.text("液态玻璃 · 通透", "Liquid Glass · Clear")
        case .frosted: return L10n.text("磨砂", "Frosted")
        }
    }
}
