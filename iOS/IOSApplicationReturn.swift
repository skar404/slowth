import Foundation

/// One automatic return after a new recording or pause in this Shield handoff.
struct IOSApplicationReturn {
    private var target: String?
    private var startedAt: Date?
    private var initialPauseID: String?
    private var observedRecordingOff = false

    mutating func arm(target: String?, recording: Bool, pauseID: String?, now: Date) {
        cancel()
        guard let target, IOSApplicationLink.url(for: target) != nil else { return }
        self.target = target
        startedAt = now
        initialPauseID = pauseID
        observedRecordingOff = !recording
    }

    mutating func cancel() { target = nil; startedAt = nil }

    mutating func take(now: Date, foreground: Bool, recording: Bool, ready: Bool,
                       evidenceAt: Date?, pauseID: String?, shieldCleared: Bool) -> URL? {
        guard let target, let startedAt else { return nil }
        let age = now.timeIntervalSince(startedAt)
        guard age >= 0, age < 120 else { cancel(); return nil }
        if !recording { observedRecordingOff = true }
        guard foreground, shieldCleared else { return nil }
        let newPause = pauseID != nil && pauseID != initialPauseID
        let freshRecording = observedRecordingOff && recording && ready && evidenceAt.map {
            $0 > startedAt && $0 <= now && now.timeIntervalSince($0) < 5
        } == true
        guard newPause || freshRecording else { return nil }
        cancel()
        return IOSApplicationLink.url(for: target)
    }
}
