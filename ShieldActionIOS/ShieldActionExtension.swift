import ManagedSettings
import ManagedSettingsUI
import Foundation
#if canImport(FamilyControls)
import FamilyControls
#endif

// Application buttons only navigate or close; the host owns rest/pause controls.
final class ShieldActionExtension: ShieldActionDelegate {
    override func handle(action: ShieldAction, for application: ApplicationToken, completionHandler: @escaping (ShieldActionResponse) -> Void) {
        let now = Date()
        SharedStore.setLastShieldActionInvokedAt(now)
        guard action == .primaryButtonPressed else {
            completionHandler(.close)
            return
        }
        if #available(iOS 26.5, *) {
            SharedStore.requestRealtimeRecordingPrompt(at: now, target: surface(containing: application)?.rawValue)
            completionHandler(.openParentalControlsApp)
        } else {
            completionHandler(.close)
        }
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

        // Unknown tokens must not inherit recording-based actions or grace unlocks.
        guard let surface else {
            if action == .primaryButtonPressed, #available(iOS 26.5, *) {
                SharedStore.requestRealtimeRecordingPrompt(at: now)
                completionHandler(.openParentalControlsApp)
            } else {
                completionHandler(.close)
            }
            return
        }

        // Pause-only apps never use the recording navigation grace path.
        if PauseOnlyApps.contains(surface.rawValue) {
            if action == .primaryButtonPressed {
                if #available(iOS 26.5, *) {
                    SharedStore.requestRealtimeRecordingPrompt(at: now, target: surface.rawValue)
                    completionHandler(.openParentalControlsApp)
                    return
                }
            }
            completionHandler(.close)
            return
        }

        if IOSPauseCoordinator.inferenceUnavailable(surface.rawValue) {
            if action == .primaryButtonPressed || action == .secondaryButtonPressed {
                if #available(iOS 26.5, *) {
                    SharedStore.requestRealtimeRecordingPrompt(at: now, target: surface.rawValue)
                    completionHandler(.openParentalControlsApp)
                    return
                }
            }
            completionHandler(.close)
            return
        }

        switch action {
        case .primaryButtonPressed:
            if !SharedStore.snapshot().broadcastActive {
                if #available(iOS 26.5, *) {
                    SharedStore.requestRealtimeRecordingPrompt(at: now, target: surface.rawValue)
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
            guard SharedStore.snapshot().broadcastActive,
                  let sharedSurface = RealtimeShieldSurface(rawValue: surface.rawValue) else {
                completionHandler(.close)
                return
            }

            do {
                if try IOSPauseCoordinator.returnToApplicationAfterRest(target: sharedSurface.rawValue) {
                    completionHandler(.none)
                    return
                }
                try IOSPauseCoordinator.requestRest(target: sharedSurface.rawValue, prioritize: true)
                // The watchdog can finish the rest while this request is handled.
                // Recheck before opening a host that no longer has a rest to show.
                if try IOSPauseCoordinator.returnToApplicationAfterRest(target: sharedSurface.rawValue) {
                    completionHandler(.none)
                    return
                }
                if #available(iOS 26.5, *) { completionHandler(.openParentalControlsApp) }
                else { completionHandler(.close) }
            } catch { completionHandler(.close) }

        default:
            completionHandler(.close)
        }
    }

    #if canImport(FamilyControls)
    private var selections: [(ManagedSettingsApplier.Surface, FamilyActivitySelection)] {
        ManagedSettingsApplier.Surface.allCases.compactMap { surface in
            let data = PauseOnlyApps.contains(surface.rawValue) ? PauseOnlyApps.data(surface.rawValue)
                : surface == .youtube
                ? SharedStore.youtubeSelectionData()
                : surface == .x ? SharedStore.xSelectionData()
                : surface == .facebook ? SharedStore.facebookSelectionData()
                : SharedStore.instagramSelectionData()
            guard let data,
                  let selection = try? JSONDecoder().decode(FamilyActivitySelection.self, from: data) else {
                return nil
            }
            return (surface, selection)
        }
    }

    private func surface(containing token: ApplicationToken) -> ManagedSettingsApplier.Surface? {
        PauseOnlyApps.refreshSelections()
        if let target = PauseOnlyApps.target(containing: token) ?? PauseOnlyApps.systemTarget(containing: token) {
            PauseOnlyApps.recordRouting("action", token: token, target: target)
            RTLog.shieldAction.notice("Pause-only action target=\(target, privacy: .public)")
            return ManagedSettingsApplier.Surface(rawValue: target)
        }
        let result = selections.first { $0.1.applicationTokens.contains(token) }?.0
        PauseOnlyApps.recordRouting("action", token: token, target: result?.rawValue)
        RTLog.shieldAction.notice("Standard action target=\(result?.rawValue ?? "unmatched", privacy: .public)")
        return result
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
