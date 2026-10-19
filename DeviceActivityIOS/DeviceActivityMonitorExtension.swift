import DeviceActivity
import FamilyControls
import Foundation

final class DeviceActivityMonitorExtension: DeviceActivityMonitor {
    override func intervalDidStart(for activity: DeviceActivityName) {
        IOSPauseCoordinator.callback(activity)
    }

    override func intervalDidEnd(for activity: DeviceActivityName) {
        IOSPauseCoordinator.callback(activity)
    }

    override func eventDidReachThreshold(
        _ event: DeviceActivityEvent.Name,
        activity: DeviceActivityName
    ) {
        super.eventDidReachThreshold(event, activity: activity)

        BlockingCoordinator.usageThreshold(event, activity: activity)
    }
}
