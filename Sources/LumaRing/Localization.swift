import Foundation

enum AppLanguage: String, CaseIterable {
    case english = "en"
    case simplifiedChinese = "zh-Hans"

    static let preferenceKey = "interfaceLanguage.v1"
    static var current: AppLanguage { load(from: .standard) }
    var title: String { self == .english ? "English" : "简体中文" }
    var locale: Locale { Locale(identifier: rawValue) }

    static func load(from defaults: UserDefaults) -> AppLanguage {
        // Preserve the interface language of existing installations.
        defaults.string(forKey: preferenceKey).flatMap(AppLanguage.init(rawValue:)) ?? .simplifiedChinese
    }

    func save(to defaults: UserDefaults) {
        defaults.set(rawValue, forKey: Self.preferenceKey)
    }
}

enum L10n {
    // Read from UserDefaults so bounded background workers can localize errors safely too.
    static func text(_ chinese: String, _ english: String, language: AppLanguage = .current) -> String {
        language == .english ? english : chinese
    }
}

extension Notification.Name {
    static let lumaRingLanguageDidChange = Notification.Name("local.lumaring.languageDidChange")
}
