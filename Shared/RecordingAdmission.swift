import Foundation

/// A rejected ReplayKit entry must never reach callbacks that mutate blocking state.
/// Selection removal does not revoke an already admitted, running session.
struct RecordingAdmission {
    private(set) var active = false
    private(set) var admitted = false

    mutating func enter(hasSelection: Bool) -> Bool {
        admitted = hasSelection
        active = hasSelection
        return hasSelection
    }

    mutating func pause() { active = false }
    mutating func finish() { active = false; admitted = false }
}
