import Foundation

enum ShieldLocalization {
    private static let languageKey = "shieldAppLanguage"

    // Called only by the containing iOS app. Mirror the language selected by
    // iOS for Slowth; this is not a separate user-selectable language setting.
    static func syncAppLanguage() {
        let language = Bundle.main.preferredLocalizations.first ?? "en"
        let defaults = AppGroup.defaults
        guard defaults.string(forKey: languageKey) != language else { return }
        defaults.set(language, forKey: languageKey)
        defaults.synchronize()
    }

    // Shield runs in a separate process, whose language preference can differ
    // from Slowth's per-app preference. Read it on every configuration request
    // and select an explicit .lproj from the extension's own resources.
    static func bundle(in resources: Bundle) -> Bundle {
        let defaults = AppGroup.defaults
        defaults.synchronize()
        let languages = resources.localizations.filter { $0 != "Base" }
        let language: String
        if let appLanguage = defaults.string(forKey: languageKey),
           languages.contains(appLanguage) {
            language = appLanguage
        } else {
            language = Bundle.preferredLocalizations(
                from: languages,
                forPreferences: Locale.preferredLanguages
            ).first ?? "en"
        }
        if let url = resources.url(forResource: language, withExtension: "lproj"),
           let bundle = Bundle(url: url) {
            return bundle
        }
        if let url = resources.url(forResource: "en", withExtension: "lproj"),
           let bundle = Bundle(url: url) {
            return bundle
        }
        return resources
    }
}
