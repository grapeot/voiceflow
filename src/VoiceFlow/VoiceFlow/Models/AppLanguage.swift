import Foundation

enum AppLanguage: String, CaseIterable, Identifiable {
    case system
    case english
    case simplifiedChinese

    var id: String { rawValue }

    var localizedTitleKey: String {
        switch self {
        case .system:
            "settings.language.system"
        case .english:
            "settings.language.english"
        case .simplifiedChinese:
            "settings.language.simplifiedChinese"
        }
    }

    var locale: Locale? {
        switch self {
        case .system:
            nil
        case .english:
            Locale(identifier: "en")
        case .simplifiedChinese:
            Locale(identifier: "zh-Hans")
        }
    }

    var bundle: Bundle {
        switch self {
        case .system:
            .main
        case .english:
            Bundle.localizedBundle(named: "en")
        case .simplifiedChinese:
            Bundle.localizedBundle(named: "zh-Hans")
        }
    }
}

private extension Bundle {
    static func localizedBundle(named languageIdentifier: String) -> Bundle {
        guard let path = Bundle.main.path(forResource: languageIdentifier, ofType: "lproj"),
              let bundle = Bundle(path: path) else {
            return .main
        }
        return bundle
    }
}
