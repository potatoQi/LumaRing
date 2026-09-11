import AppKit

enum AppTheme: String, Codable, CaseIterable {
    case system, dark, light

    var title: String {
        switch self {
        case .system: return L10n.text("跟随系统", "System")
        case .dark: return L10n.text("深色", "Dark")
        case .light: return L10n.text("浅色", "Light")
        }
    }

    @MainActor func apply() {
        switch self {
        case .system: NSApplication.shared.appearance = nil
        case .dark: NSApplication.shared.appearance = NSAppearance(named: .darkAqua)
        case .light: NSApplication.shared.appearance = NSAppearance(named: .aqua)
        }
    }
}
