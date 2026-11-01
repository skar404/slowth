#if os(iOS) || RECORDING_HEALTH_TESTS
import Foundation
import Darwin

/// Cross-process recording ownership and request/reply liveness. The lock is held
/// only during short state transitions, never while waiting for a response.
struct RecordingHealthStore {
    static let requestKey = "recordingHealthProbe.request"
    static let responseKey = "recordingHealthProbe.response"
    static let sessionKey = "recordingHealth.session"
    static let historyKey = "recordingHealthProbe.history"
    static let timeout: TimeInterval = 3
    let defaults: UserDefaults
    let lockURL: URL

    struct Probe {
        let id: String
        let session: String?
        let started: TimeInterval
    }
    enum Result: String { case waiting, responded, stopped, superseded, recovered }
    enum StorageError: Error { case unavailable, busy }

    private func locked<T>(_ work: () throws -> T) throws -> T {
        var descriptor = open(lockURL.path, O_CREAT | O_EXCL | O_RDWR, S_IRUSR | S_IWUSR)
        let created = descriptor >= 0
        if descriptor < 0 && errno == EEXIST { descriptor = open(lockURL.path, O_RDWR) }
        guard descriptor >= 0 else { throw StorageError.unavailable }
        defer { close(descriptor) }
        #if os(iOS)
        if created {
            try FileManager.default.setAttributes([.protectionKey: FileProtectionType.completeUntilFirstUserAuthentication],
                                                  ofItemAtPath: lockURL.path)
        }
        #else
        _ = created
        #endif
        let deadline = ProcessInfo.processInfo.systemUptime + 0.25
        while flock(descriptor, LOCK_EX | LOCK_NB) != 0 {
            guard errno == EWOULDBLOCK || errno == EINTR else { throw StorageError.unavailable }
            guard ProcessInfo.processInfo.systemUptime < deadline else { throw StorageError.busy }
            usleep(2_000)
        }
        defer { flock(descriptor, LOCK_UN) }
        defaults.synchronize()
        defer { defaults.synchronize() }
        return try work()
    }

    func start() throws -> String {
        try locked {
            let session = UUID().uuidString
            defaults.set(session, forKey: Self.sessionKey)
            defaults.set(true, forKey: "broadcastActive")
            defaults.set(false, forKey: "youtubeShieldRestoreDeferred")
            defaults.removeObject(forKey: "softYouTubeMonitorGeneration")
            return session
        }
    }

    /// Old callbacks cannot stop a newly started recording.
    func stop(session: String) throws -> Bool {
        try locked {
            guard defaults.string(forKey: Self.sessionKey) == session else { return false }
            defaults.set(false, forKey: "broadcastActive")
            // Retain ownership across ReplayKit pause -> finish callbacks.
            // A resume/start replaces it; timeout recovery revokes it entirely.
            return true
        }
    }

    func respond(session: String) throws -> Bool {
        try locked {
            guard defaults.bool(forKey: "broadcastActive"),
                  defaults.string(forKey: Self.sessionKey) == session else { return false }
            if let id = defaults.string(forKey: Self.requestKey),
               defaults.string(forKey: Self.responseKey) != id {
                defaults.set(id, forKey: Self.responseKey)
            }
            return true
        }
    }

    func begin(now: TimeInterval) throws -> Probe? {
        try locked {
            guard defaults.bool(forKey: "broadcastActive") else { return nil }
            let probe = Probe(id: UUID().uuidString,
                              session: defaults.string(forKey: Self.sessionKey), started: now)
            defaults.set(probe.id, forKey: Self.requestKey)
            record("probe-start \(probe.id)")
            return probe
        }
    }

    /// Caller must provide uninterrupted foreground time. Re-check ownership and
    /// the latest reply under the same lock used by start/stop/respond. Restore
    /// protection before allowing a new recorder to acquire ownership.
    func poll(_ probe: Probe, now: TimeInterval, recover: () -> Void) throws -> Result {
        try locked {
            guard defaults.string(forKey: Self.sessionKey) == probe.session,
                  defaults.string(forKey: Self.requestKey) == probe.id else { return .superseded }
            guard defaults.bool(forKey: "broadcastActive") else { return .stopped }
            if defaults.string(forKey: Self.responseKey) == probe.id {
                record("recorder-responded \(probe.id)")
                return .responded
            }
            guard now - probe.started >= Self.timeout else { return .waiting }
            defaults.set(false, forKey: "broadcastActive")
            defaults.removeObject(forKey: Self.sessionKey)
            defaults.set(false, forKey: "youtubeShieldRestoreDeferred")
            defaults.synchronize()
            recover()
            record("recovered-unresponsive-recording \(probe.id)")
            return .recovered
        }
    }

    private func record(_ text: String) {
        var history = defaults.stringArray(forKey: Self.historyKey) ?? []
        history.append("\(Date().ISO8601Format()) \(text)")
        defaults.set(Array(history.suffix(30)), forKey: Self.historyKey)
    }

    #if !RECORDING_HEALTH_TESTS
    static func shared() throws -> Self {
        guard let root = FileManager.default.containerURL(forSecurityApplicationGroupIdentifier: AppGroup.identifier) else {
            throw StorageError.unavailable
        }
        return Self(defaults: AppGroup.defaults, lockURL: root.appendingPathComponent("recording-health.lock"))
    }
    #endif
}

/// Discard a probe after app suspension, a clock discontinuity or a long main
/// thread stall. A timeout must represent consecutive foreground observations.
struct RecordingHealthWindow {
    private var previous: TimeInterval?
    mutating func observe(active: Bool, now: TimeInterval) -> Bool {
        defer { previous = active ? now : nil }
        guard active, let previous else { return false }
        return now >= previous && now - previous <= 2
    }
}
#endif
