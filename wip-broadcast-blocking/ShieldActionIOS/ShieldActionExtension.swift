import ManagedSettings
import ManagedSettingsUI
import Foundation

// Handles taps on the custom Shield screen buttons (see
// UnscrollShieldConfigIOS's ShieldConfigurationExtension for the UI side).
// "Remove block" clears the shield immediately and turns off
// broadcastBlockingEnabled so the still-running broadcast session's
// SampleHandler doesn't just re-shield on the next detected frame.
final class ShieldActionExtension: ShieldActionDelegate {
    override func handle(action: ShieldAction, for application: ApplicationToken, completionHandler: @escaping (ShieldActionResponse) -> Void) {
        respond(to: action, completionHandler: completionHandler)
    }

    override func handle(action: ShieldAction, for webDomain: WebDomainToken, completionHandler: @escaping (ShieldActionResponse) -> Void) {
        respond(to: action, completionHandler: completionHandler)
    }

    override func handle(action: ShieldAction, for category: ActivityCategoryToken, completionHandler: @escaping (ShieldActionResponse) -> Void) {
        respond(to: action, completionHandler: completionHandler)
    }

    private func respond(to action: ShieldAction, completionHandler: @escaping (ShieldActionResponse) -> Void) {
        // Diagnostic marker: if this never shows up as "recently invoked" in
        // the app's Broadcast Blocking section after tapping a shield button,
        // the OS isn't launching this extension at all (provisioning/
        // registration problem) rather than the clear-shield logic failing.
        SharedStore.setLastShieldActionInvokedAt(Date())
        print("ShieldActionExtension: handling \(action)")

        switch action {
        case .primaryButtonPressed:
            completionHandler(.close)
        case .secondaryButtonPressed:
            ManagedSettingsApplier.clear()
            SharedStore.setBroadcastBlockingEnabled(false)
            print("ShieldActionExtension: cleared shield, disabled broadcast blocking")
            completionHandler(.close)
        @unknown default:
            completionHandler(.close)
        }
    }
}
