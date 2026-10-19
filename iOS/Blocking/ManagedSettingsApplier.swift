import Foundation
#if canImport(FamilyControls)
import FamilyControls
#endif
#if canImport(ManagedSettings)
import ManagedSettings
#endif

// Independent named stores for each selected app. Application tokens are
// opaque, so each app has its own picker and shield.
enum ManagedSettingsApplier {
    enum Surface: String, CaseIterable {
        case youtube
        case instagram
        case facebook
        case x
        case tiktok
        case snapchat

    }

    static func apply(surface: Surface, selection requestedSelection: FamilyActivitySelection?) {
        #if canImport(ManagedSettings) && canImport(FamilyControls)
        // A recorder's clear request must never unlock a pause-only service.
        // Only the coordinator may temporarily remove its shield during a lease.
        let selection = PauseOnlyApps.contains(surface.rawValue)
            ? (IOSPauseCoordinator.protectionAuthorized(SharedStore.snapshot()) ? PauseOnlyApps.selection(surface.rawValue) : nil)
            : requestedSelection
        _ = IOSPauseCoordinator.intercept(target: surface.rawValue, requested: selection)
        #endif
    }

    static func clear(surface: Surface) {
        apply(surface: surface, selection: nil)
    }
}
