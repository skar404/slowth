// Exercise production persisted-selection handling without Apple's token APIs.
import Foundation

typealias ApplicationToken = String
struct FamilyActivitySelection: Codable {
    var includeEntireCategory = false
    var applicationTokens = Set<String>()
    var categoryTokens = Set<String>()
    var webDomainTokens = Set<String>()
}
enum AppGroup {
    static let identifier = "slowth.grouped-selection.tests." + UUID().uuidString
    static let defaults = UserDefaults(suiteName: identifier)!
}
enum SharedStoreError: Error { case invalidValue, strictModeActive }
enum SharedStore {
    struct State {
        var isStrictModeActive = false
        var softYouTubeBlockingEnabled = false
        var youtubeSelectionData: Data?
    }
    static func snapshot() -> State { State() }
}

@main enum GroupedSelectionChecks {
    static func main() throws {
        defer { AppGroup.defaults.removePersistentDomain(forName: AppGroup.identifier) }
        for count in [0, 1, 49, 50, 51, 171] {
            let tokens = Set((0..<count).map { "app-\($0)" })
            let saved = FamilyActivitySelection(applicationTokens: tokens)
            let data = try JSONEncoder().encode(saved)
            AppGroup.defaults.set(data, forKey: GroupedApps.key)
            assert((GroupedApps.selection != nil) == (count > 0 && count <= 50))
            assert(GroupedApps.pickerSelection.includeEntireCategory)
            assert(GroupedApps.pickerSelection.applicationTokens == tokens,
                   "Oversized legacy lists must remain editable without dropping apps")
            assert(Set(GroupedApps.orderedTokens) == tokens)
            assert(GroupedApps.data == data, "Readiness checks must never rewrite a saved selection")
        }
        // A legacy selection can be corrected after relaunch, with its explicit
        // app preferences retained by migration and its supported subset usable.
        try GroupedApps.migrateSettings()
        assert(GroupedApps.configuration?.apps.count == 171)
        let corrected = FamilyActivitySelection(applicationTokens: ["app-0", "app-170"])
        AppGroup.defaults.set(try JSONEncoder().encode(corrected), forKey: GroupedApps.key)
        assert(GroupedApps.selection?.applicationTokens == corrected.applicationTokens)
        print("PASS: 50-app boundary, oversized persisted lists remain editable, correction restores readiness")
    }
}
