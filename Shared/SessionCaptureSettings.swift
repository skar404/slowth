#if DEBUG
import Foundation

enum SessionCaptureSettings {
    static let storageKey = "debugSessionCapture.enabled"
    static let intervalKey = "debugSessionCapture.intervalSeconds"
    static let storageLimitKey = "debugSessionCapture.storageLimitGiB"

    enum StorageLimit: Int, CaseIterable {
        case unlimited = 0
        case one = 1
        case two = 2
        case five = 5
        case ten = 10
        case twenty = 20
        case fifty = 50

        var bytes: Int? {
            self == .unlimited ? nil : rawValue * 1_024 * 1_024 * 1_024
        }
    }

    static func captureLimits(defaults: UserDefaults = AppGroup.defaults) -> SessionCapture.Limits {
        let selection = StorageLimit(rawValue: defaults.integer(forKey: storageLimitKey)) ?? .unlimited
        return SessionCapture.Limits(totalBytes: selection.bytes)
    }

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
