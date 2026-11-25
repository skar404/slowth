import Foundation

// Only the macOS host app writes this preference. iOS and extension language
// selection continue to follow the system's per-app settings.
enum AppLocalization {
    static let languageKey = "macAppLanguage"

    static var availableLanguages: [String] {
        Bundle.main.localizations.filter { $0 != "Base" }.sorted {
            languageName($0).localizedStandardCompare(languageName($1)) == .orderedAscending
        }
    }

    static func languageName(_ identifier: String) -> String {
        Locale(identifier: identifier).localizedString(forIdentifier: identifier) ?? identifier
    }

    static var preference: String {
        #if os(macOS)
        return UserDefaults.standard.string(forKey: languageKey) ?? ""
        #else
        return ""
        #endif
    }

    static func language(in resources: Bundle, preference: String) -> String {
        if !preference.isEmpty && resources.localizations.contains(preference) {
            return preference
        }
        return resources.preferredLocalizations.first(where: { $0 != "Base" }) ?? "en"
    }

    static var locale: Locale {
        Locale(identifier: language(in: .main, preference: preference))
    }

    static var isRightToLeft: Bool {
        locale.language.characterDirection == .rightToLeft
    }

    static func bundle(in resources: Bundle, preference: String) -> Bundle {
        let identifier = language(in: resources, preference: preference)
        if let url = resources.url(forResource: identifier, withExtension: "lproj"),
           let localized = Bundle(url: url) {
            return localized
        }
        return resources
    }

    static func string(_ value: String.LocalizationValue) -> String {
        String(localized: value, bundle: bundle(in: .main, preference: preference), locale: locale)
    }
}
