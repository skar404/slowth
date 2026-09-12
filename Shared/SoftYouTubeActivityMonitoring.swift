#if os(iOS) && canImport(DeviceActivity) && canImport(FamilyControls)
import DeviceActivity
import FamilyControls
import Foundation

/// Arms a fresh one-shot Device Activity event for the selected YouTube app.
/// A unique name on every arm prevents a delayed callback from an older app
/// transition from applying the shield during a newer Slowth session.
enum SoftYouTubeActivityMonitoring {
    static let thresholdSeconds = 1

    private static let activityPrefix = "softYouTubeRestore."
    private static let eventPrefix = "youtubeUsageThreshold."
    private static let legacyActivityName = "softYouTubeRestore"
    private static let retiredInstagramActivityName = "instagramUsageObservation"

    @discardableResult
    static func start() -> Bool {
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
            stop()
            RTLog.activityMonitor.notice(
                "Soft YouTube monitor not armed — current state is ineligible"
            )
            return false
        }

        stop()

        let generation = UUID().uuidString
        let activity = DeviceActivityName(activityPrefix + generation)
        let eventName = DeviceActivityEvent.Name(eventPrefix + generation)
        let schedule = DeviceActivitySchedule(
            intervalStart: DateComponents(hour: 0, minute: 0, second: 0),
            intervalEnd: DateComponents(hour: 23, minute: 59, second: 59),
            repeats: true
        )
        let event: DeviceActivityEvent
        if #available(iOS 17.4, *) {
            event = DeviceActivityEvent(
                applications: selection.applicationTokens,
                threshold: DateComponents(second: thresholdSeconds),
                includesPastActivity: false
            )
        } else {
            // The unique event name gives iOS 16–17.3 a fresh counter even
            // though includesPastActivity is unavailable on those versions.
            event = DeviceActivityEvent(
                applications: selection.applicationTokens,
                threshold: DateComponents(second: thresholdSeconds)
            )
        }

        SharedStore.setSoftYouTubeMonitorGeneration(generation)
        do {
            try DeviceActivityCenter().startMonitoring(
                activity,
                during: schedule,
                events: [eventName: event]
            )
            RTLog.activityMonitor.notice(
                "Soft YouTube monitor armed for \(thresholdSeconds, privacy: .public)s of YouTube use; generation=\(generation, privacy: .public)"
            )
            return true
        } catch {
            _ = SharedStore.clearSoftYouTubeMonitorGeneration(ifMatching: generation)
            RTLog.activityMonitor.error(
                "Could not arm soft YouTube monitor: \(String(describing: error), privacy: .public)"
            )
            return false
        }
    }

    static func stop() {
        let center = DeviceActivityCenter()
        let activities = center.activities.filter { activity in
            activity.rawValue == legacyActivityName
                || activity.rawValue.hasPrefix(activityPrefix)
                || activity.rawValue == retiredInstagramActivityName
        }
        if !activities.isEmpty {
            center.stopMonitoring(activities)
            RTLog.activityMonitor.notice(
                "Stopped \(activities.count, privacy: .public) soft/retired monitor(s)"
            )
        }
        SharedStore.setSoftYouTubeMonitorGeneration(nil)
        SharedStore.clearRetiredDeviceActivityState()
    }

    static func generation(
        for activity: DeviceActivityName,
        event: DeviceActivityEvent.Name
    ) -> String? {
        guard activity.rawValue.hasPrefix(activityPrefix),
              event.rawValue.hasPrefix(eventPrefix) else {
            return nil
        }
        let activityGeneration = String(activity.rawValue.dropFirst(activityPrefix.count))
        let eventGeneration = String(event.rawValue.dropFirst(eventPrefix.count))
        guard !activityGeneration.isEmpty, activityGeneration == eventGeneration else {
            return nil
        }
        return activityGeneration
    }

    static func stop(activity: DeviceActivityName, generation: String) {
        DeviceActivityCenter().stopMonitoring([activity])
        _ = SharedStore.clearSoftYouTubeMonitorGeneration(ifMatching: generation)
    }
}
#endif
