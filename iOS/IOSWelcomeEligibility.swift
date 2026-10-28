import Foundation

/// The legacy handled flag controls automatic presentation only.
enum IOSWelcomeEligibility {
    static func isConfigured() -> Bool { SharedStore.hasRecordingSelection() }
}
