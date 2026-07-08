import Foundation
#if canImport(FamilyControls)
import FamilyControls
#endif
#if canImport(ManagedSettings)
import ManagedSettings
#endif

enum ManagedSettingsApplier {
    static let storeName = "UnscrollShield"

    #if canImport(ManagedSettings)
    private static let store = ManagedSettingsStore(named: ManagedSettingsStore.Name(storeName))
    #endif

    static func apply(selection: FamilyActivitySelection?) {
        #if canImport(ManagedSettings) && canImport(FamilyControls)
        if let selection = selection {
            store.shield.applications = selection.applicationTokens.isEmpty
                ? nil
                : selection.applicationTokens
            store.shield.applicationCategories = selection.categoryTokens.isEmpty
                ? nil
                : .specific(selection.categoryTokens)
        } else {
            store.shield.applications = nil
            store.shield.applicationCategories = nil
        }
        #endif
    }

    static func clear() {
        apply(selection: nil)
    }
}
