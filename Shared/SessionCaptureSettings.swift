#if DEBUG
import Foundation

enum SessionCaptureSettings {
    static let storageKey = "debugSessionCapture.enabled"
    static let intervalKey = "debugSessionCapture.intervalSeconds"

    static func resolve(debug: Bool, optedIn: Bool, interval: Double) -> Double? {
        guard debug, optedIn else { return nil }
        return interval == 0.5 ? 0.5 : 1
    }

    static var interval: Double? {
        return resolve(debug: DebugMode.isEnabled,
                       optedIn: AppGroup.defaults.bool(forKey: storageKey),
                       interval: AppGroup.defaults.double(forKey: intervalKey))
    }

    static var isEnabled: Bool { interval != nil }

    static var rootDirectory: URL? {
        FileManager.default.containerURL(forSecurityApplicationGroupIdentifier: AppGroup.identifier)?
            .appendingPathComponent("RealtimeShieldSessions", isDirectory: true)
    }
}
#endif
