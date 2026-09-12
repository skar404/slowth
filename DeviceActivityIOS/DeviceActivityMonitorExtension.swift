import DeviceActivity
import FamilyControls
import Foundation

final class DeviceActivityMonitorExtension: DeviceActivityMonitor {
    override func eventDidReachThreshold(
        _ event: DeviceActivityEvent.Name,
        activity: DeviceActivityName
    ) {
        super.eventDidReachThreshold(event, activity: activity)

        guard let generation = SoftYouTubeActivityMonitoring.generation(
            for: activity,
            event: event
        ) else {
            RTLog.activityMonitor.notice("Ignoring unrelated Device Activity event")
            return
        }

        guard SharedStore.softYouTubeMonitorGeneration() == generation else {
            DeviceActivityCenter().stopMonitoring([activity])
            RTLog.activityMonitor.notice(
                "Ignoring stale soft YouTube callback; generation=\(generation, privacy: .public)"
            )
            return
        }

        let state = SharedStore.snapshot()
        guard state.realtimeShieldEnabled,
              state.realtimeYouTubeBlockingEnabled,
              state.softYouTubeBlockingEnabled,
              state.youtubeShieldRestoreDeferred,
              !state.broadcastActive,
              !SharedStore.isSlowthAppForeground(),
              let data = state.youtubeSelectionData,
              let selection = try? JSONDecoder().decode(
                  FamilyActivitySelection.self,
                  from: data
              ),
              selection.applicationTokens.count == 1 else {
            SoftYouTubeActivityMonitoring.stop(activity: activity, generation: generation)
            RTLog.activityMonitor.notice(
                "Ignoring soft YouTube callback — current state is ineligible"
            )
            return
        }

        ManagedSettingsApplier.apply(surface: .youtube, selection: selection)
        // The host can enter foreground while this extension is running. Check
        // again after the write so every ordering of that race ends unshielded
        // when Slowth is visible.
        guard !SharedStore.isSlowthAppForeground(),
              SharedStore.softYouTubeMonitorGeneration() == generation else {
            ManagedSettingsApplier.clear(surface: .youtube)
            SoftYouTubeActivityMonitoring.stop(activity: activity, generation: generation)
            RTLog.activityMonitor.notice(
                "Removed YouTube shield because Slowth became active during callback"
            )
            return
        }
        SharedStore.setYouTubeShieldRestoreDeferred(false)
        SoftYouTubeActivityMonitoring.stop(activity: activity, generation: generation)
        RTLog.activityMonitor.notice(
            "YouTube shield applied after \(SoftYouTubeActivityMonitoring.thresholdSeconds, privacy: .public)s usage threshold"
        )
    }
}
