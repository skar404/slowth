import Foundation
#if canImport(FamilyControls)
import FamilyControls
#endif
#if canImport(ManagedSettings)
import ManagedSettings
#endif

// Two independent named stores — one per app the user picked into the
// "Choose YouTube app" / "Choose Instagram app" slots — so each can be
// shielded/unshielded independently based on which content classifier fired.
// ApplicationTokens are opaque (no bundle-ID introspection), which is why
// there are two separate slots/stores instead of one combined selection.
enum ManagedSettingsApplier {
    enum Surface: String, CaseIterable {
        case youtube
        case instagram

        var storeName: String { "RealtimeShield.\(rawValue)" }
    }

    #if canImport(ManagedSettings)
    private static var stores: [Surface: ManagedSettingsStore] = [
        .youtube: ManagedSettingsStore(named: ManagedSettingsStore.Name(Surface.youtube.storeName)),
        .instagram: ManagedSettingsStore(named: ManagedSettingsStore.Name(Surface.instagram.storeName))
    ]
    #endif

    static func apply(surface: Surface, selection: FamilyActivitySelection?) {
        #if canImport(ManagedSettings) && canImport(FamilyControls)
        guard let store = stores[surface] else { return }
        if let selection = selection {
            store.shield.applications = selection.applicationTokens.isEmpty
                ? nil
                : selection.applicationTokens
            store.shield.applicationCategories = selection.categoryTokens.isEmpty
                ? nil
                : .specific(selection.categoryTokens)
            RTLog.shield.notice("apply(\(surface.rawValue, privacy: .public)): shielded \(selection.applicationTokens.count) app token(s), \(selection.categoryTokens.count) categor(y/ies)")
        } else {
            store.shield.applications = nil
            store.shield.applicationCategories = nil
            RTLog.shield.notice("apply(\(surface.rawValue, privacy: .public), nil): cleared shield")
        }
        #endif
    }

    static func clear(surface: Surface) {
        apply(surface: surface, selection: nil)
    }
}
