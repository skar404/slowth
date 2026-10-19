import Foundation
#if !PAUSE_COORDINATOR_TESTS
import DeviceActivity
#endif

/// DeviceActivity scheduling for durable ordinary pauses.
enum BlockingPauseMonitor {
    static func start(_ name: DeviceActivityName, lease: IOSPauseLease) throws {
        var calendar = Calendar(identifier: .gregorian); calendar.timeZone = TimeZone(secondsFromGMT: 0)!
        func components(_ date: Double) -> DateComponents {
            var c = calendar.dateComponents([.year, .month, .day, .hour, .minute, .second], from: Date(timeIntervalSince1970: date))
            c.calendar = calendar; c.timeZone = calendar.timeZone; return c
        }
        let end = ceil(lease.expiresAt)
        let schedule = DeviceActivitySchedule(intervalStart: components(end - 900), intervalEnd: components(end), repeats: false)
        try DeviceActivityCenter().startMonitoring(name, during: schedule)
    }
    static func stop(_ names: [DeviceActivityName]) {
        DeviceActivityCenter().stopMonitoring(names)
    }
}
