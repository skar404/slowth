import ManagedSettings
import ManagedSettingsUI
import Foundation
#if canImport(FamilyControls)
import FamilyControls
#endif

// Handles the detected shield's Close app and Continue actions. Continue adds
// a short pause before granting the existing navigation grace period.
final class ShieldActionExtension: ShieldActionDelegate {
    override func handle(action: ShieldAction, for application: ApplicationToken, completionHandler: @escaping (ShieldActionResponse) -> Void) {
        respond(to: action, surface: surface(containing: application), completionHandler: completionHandler)
    }

    override func handle(action: ShieldAction, for webDomain: WebDomainToken, completionHandler: @escaping (ShieldActionResponse) -> Void) {
        respond(to: action, surface: surface(containing: webDomain), completionHandler: completionHandler)
    }

    override func handle(action: ShieldAction, for category: ActivityCategoryToken, completionHandler: @escaping (ShieldActionResponse) -> Void) {
        respond(to: action, surface: surface(containing: category), completionHandler: completionHandler)
    }

    private func respond(
        to action: ShieldAction,
        surface: ManagedSettingsApplier.Surface?,
        completionHandler: @escaping (ShieldActionResponse) -> Void
    ) {
        // Diagnostic marker: confirms the OS is actually invoking this
        // extension, independent of what happens afterwards.
        RTLog.shieldAction.notice("respond(to: \(String(describing: action), privacy: .public)) — extension invoked by OS")
        let now = Date()
        SharedStore.setLastShieldActionInvokedAt(now)

        switch action {
        case .primaryButtonPressed:
            if !SharedStore.snapshot().broadcastActive {
                if #available(iOS 26.5, *) {
                    SharedStore.requestRealtimeRecordingPrompt(at: now)
                    RTLog.shieldAction.notice("Open Slowth selected from recording-off shield")
                    completionHandler(.openParentalControlsApp)
                } else {
                    completionHandler(.close)
                }
                return
            }
            RTLog.shieldAction.notice("Close app selected")
            completionHandler(.close)

        case .secondaryButtonPressed:
            // Only a detection shield shown during an active broadcast can be
            // released. The recording-off shield remains fail-closed.
            guard SharedStore.snapshot().broadcastActive, let surface,
                  let sharedSurface = RealtimeShieldSurface(rawValue: surface.rawValue) else {
                completionHandler(.close)
                return
            }

            RTLog.shieldAction.notice("Continue selected — releasing shield after one-second pause")
            DispatchQueue.main.asyncAfter(deadline: .now() + 1) {
                SharedStore.requestShieldUnlock(surface: sharedSurface, at: Date())
                ManagedSettingsApplier.clear(surface: surface)
                // Clearing the shield dismisses it. Returning .none keeps the
                // monitored app open for the existing navigation grace period.
                RTLog.shieldAction.notice("Continue pause completed — requested grace unlock for \(surface.rawValue, privacy: .public)")
                completionHandler(.none)
            }

        default:
            completionHandler(.close)
        }
    }

    #if canImport(FamilyControls)
    private var selections: [(ManagedSettingsApplier.Surface, FamilyActivitySelection)] {
        ManagedSettingsApplier.Surface.allCases.compactMap { surface in
            let data = surface == .youtube
                ? SharedStore.youtubeSelectionData()
                : SharedStore.instagramSelectionData()
            guard let data,
                  let selection = try? JSONDecoder().decode(FamilyActivitySelection.self, from: data) else {
                return nil
            }
            return (surface, selection)
        }
    }

    private func surface(containing token: ApplicationToken) -> ManagedSettingsApplier.Surface? {
        selections.first { $0.1.applicationTokens.contains(token) }?.0
    }

    private func surface(containing token: WebDomainToken) -> ManagedSettingsApplier.Surface? {
        selections.first { $0.1.webDomainTokens.contains(token) }?.0
    }

    private func surface(containing token: ActivityCategoryToken) -> ManagedSettingsApplier.Surface? {
        selections.first { $0.1.categoryTokens.contains(token) }?.0
    }
    #else
    private func surface(containing token: ApplicationToken) -> ManagedSettingsApplier.Surface? { nil }
    private func surface(containing token: WebDomainToken) -> ManagedSettingsApplier.Surface? { nil }
    private func surface(containing token: ActivityCategoryToken) -> ManagedSettingsApplier.Surface? { nil }
    #endif
}
