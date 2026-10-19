import Foundation
#if !PAUSE_COORDINATOR_TESTS
import FamilyControls
import ManagedSettings
#endif

/// The only system Shield writer. Call from the coordinator's transaction;
/// never use this adapter to bypass pause/rest validation.
enum BlockingShield {
    static func write(_ target: String, selection: FamilyActivitySelection?) {
        let store = ManagedSettingsStore(named: .init("RealtimeShield.\(target)"))
        if selection == nil, store.shield.applications == nil, store.shield.applicationCategories == nil { return }
        store.shield.applications = selection.flatMap { $0.applicationTokens.isEmpty ? nil : $0.applicationTokens }
        store.shield.applicationCategories = selection.flatMap { $0.categoryTokens.isEmpty ? nil : .specific($0.categoryTokens) }
    }
}
