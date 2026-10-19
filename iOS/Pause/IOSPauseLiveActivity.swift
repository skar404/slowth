import ActivityKit
import Foundation

/// Presentation only. Never grants access or uses dismissal to change protection.
@available(iOS 16.2, *)
actor IOSPauseLiveActivity {
    static let shared = IOSPauseLiveActivity()

    static func content(_ lease: IOSPauseLease) -> ActivityContent<PauseActivityAttributes.ContentState> {
        var state = PauseActivityAttributes.ContentState(phase: lease.phase,
            startedAt: Date(timeIntervalSince1970: lease.started.wall),
            expiresAt: Date(timeIntervalSince1970: lease.expiresAt),
            service: PauseTargetDisplay.name(for: lease.target))
        state.target = lease.target
        var ledger = IOSPauseLedger()
        ledger.lease = lease
        state.switchTargets = IOSPauseCoordinator.applicationSwitchTargets(ledger,
            state: SharedStore.snapshot(), now: IOSPauseCoordinator.clock())
        let deadline = lease.phase == "preparing" ? lease.started.wall + 15 : lease.expiresAt
        return ActivityContent(state: state, staleDate: Date(timeIntervalSince1970: deadline))
    }

    func setChoosing(_ choosing: Bool, id: String, source: String) async throws {
        let ledger = try IOSPauseCoordinator.presentationSnapshot()
        guard let lease = ledger.lease, lease.id == id, lease.target == source,
              !IOSPauseCoordinator.applicationSwitchTargets(ledger, state: SharedStore.snapshot(),
                  now: IOSPauseCoordinator.clock()).isEmpty else { throw IOSPauseError.stale }
        for activity in Activity<PauseActivityAttributes>.activities where activity.attributes.pauseID == id {
            let content = Self.content(lease)
            var state = content.state
            state.choosingApp = choosing ? true : nil
            await activity.update(ActivityContent(state: state, staleDate: content.staleDate))
        }
    }

    /// Re-read committed state rather than rendering a potentially delayed caller snapshot.
    /// An extension may lose execution time or be unable to enumerate the host activity;
    /// the host repeats this reconciliation on foreground. staleDate makes that gap visible.
    func synchronize() async {
        guard let ledger = try? IOSPauseCoordinator.presentationSnapshot() else { return }
        for activity in Activity<PauseActivityAttributes>.activities {
            if let lease = ledger.lease, lease.id == activity.attributes.pauseID {
                var content = Self.content(lease)
                if activity.content.state.target == lease.target,
                   activity.content.state.choosingApp == true,
                   !(content.state.switchTargets ?? []).isEmpty {
                    var state = content.state
                    state.choosingApp = true
                    content = ActivityContent(state: state, staleDate: content.staleDate)
                }
                if activity.content.state != content.state {
                    await activity.update(content)
                }
            } else {
                var state = activity.content.state
                state.phase = "ended"
                await activity.end(ActivityContent(state: state, staleDate: nil), dismissalPolicy: .immediate)
            }
        }
    }
}
