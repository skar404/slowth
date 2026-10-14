import ActivityKit
import UIKit

@MainActor enum PauseActivityHost {
    /// Called only by the explicit start action, never from polling or dismissal.
    static func start(id: String) async -> String? {
        guard #available(iOS 16.2, *) else { return nil }
        await IOSPauseLiveActivity.shared.synchronize()
        guard UIApplication.shared.applicationState == .active,
              let ledger = try? IOSPauseCoordinator.presentationSnapshot(),
              let lease = ledger.lease, lease.id == id else { return nil }
        guard ActivityAuthorizationInfo().areActivitiesEnabled else {
            return String(localized: "Live Activity unavailable. The pause still follows its own timer.", table: "PauseActivity")
        }
        guard !Activity<PauseActivityAttributes>.activities.contains(where: { $0.attributes.pauseID == id }) else { return nil }
        let labels = ["youtube":"YouTube", "instagram":"Instagram", "facebook":"Facebook", "x":"X", "tiktok":"TikTok"]
        do {
            _ = try Activity.request(attributes: PauseActivityAttributes(pauseID: id,
                service: labels[lease.target] ?? lease.target, safari: lease.kind == "safari"),
                content: IOSPauseLiveActivity.content(lease), pushType: nil)
            // The pause may have ended while ActivityKit was being called.
            await IOSPauseLiveActivity.shared.synchronize()
            return nil
        } catch {
            return String(localized: "Live Activity unavailable. The pause still follows its own timer.", table: "PauseActivity")
        }
    }
}
