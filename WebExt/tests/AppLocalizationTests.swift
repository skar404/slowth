import Foundation

// Run in a temporary .app containing the compiled localization resources.
@main
struct AppLocalizationTests {
    static func main() throws {
        if CommandLine.arguments.contains("--verify-saved") {
            precondition(AppLocalization.preference == "ru")
            precondition(AppLocalization.string("Language") == "Язык")
            return
        }
        let defaults = UserDefaults.standard
        let domain = Bundle.main.bundleIdentifier!
        precondition(domain.hasPrefix("test.slowth.localization."))
        defer { defaults.removePersistentDomain(forName: domain) }
        func choose(_ language: String) { defaults.set(language, forKey: AppLocalization.languageKey) }
        precondition(AppLocalization.availableLanguages.count == 46)
        for language in AppLocalization.availableLanguages {
            choose(language)
            precondition(!AppLocalization.languageName(language).isEmpty)
            precondition(AppLocalization.locale.identifier == language)
            let bundle = AppLocalization.bundle(in: .main, preference: language)
            precondition(AppLocalization.string("Help") == bundle.localizedString(forKey: "Help", value: nil, table: nil))
            precondition(AppLocalization.string("Language") != "Language" || ["en", "pcm"].contains(language))
        }
        choose("en")
        precondition(AppLocalization.string("Help") == "Help")
        precondition(AppLocalization.string("Server error (\(500))") == "Server error (500)")
        choose("ru")
        precondition(AppLocalization.string("Language") == "Язык")
        precondition(AppLocalization.string("System default") == "Как в системе")
        precondition(!AppLocalization.isRightToLeft)
        defaults.synchronize()
        let nextLaunch = Process()
        nextLaunch.executableURL = Bundle.main.executableURL!
        nextLaunch.arguments = ["--verify-saved"]
        try nextLaunch.run()
        nextLaunch.waitUntilExit()
        precondition(nextLaunch.terminationStatus == 0, "New process must load the saved language")
        choose("ar")
        precondition(AppLocalization.isRightToLeft)
        choose("en")
        precondition(!AppLocalization.isRightToLeft)
        precondition(AppLocalization.string("Language") == "Language", "Switching back must not retain the previous bundle")
        choose("")
        let system = AppLocalization.locale.identifier
        precondition(system == Bundle.main.preferredLocalizations.first)
        choose("unsupported-language")
        precondition(AppLocalization.locale.identifier == system)
        print("App language: 46 locales, immediate switching, interpolation, persistence, RTL and system fallback passed")
    }
}
