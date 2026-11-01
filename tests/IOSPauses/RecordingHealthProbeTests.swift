import Foundation
import Darwin
@main
struct RecordingHealthProbeTests {
    static func main() throws {
        func check(_ value: @autoclosure () throws -> Bool) rethrows { let result = try value(); assert(result) }
        let suite = "RecordingHealthProbeTests.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suite)!
        let lock = FileManager.default.temporaryDirectory.appendingPathComponent(suite)
        defer { defaults.removePersistentDomain(forName: suite); try? FileManager.default.removeItem(at: lock) }
        let store = RecordingHealthStore(defaults: defaults, lockURL: lock)
        var recoveries = 0
        func poll(_ p: RecordingHealthStore.Probe, _ now: Double) throws -> RecordingHealthStore.Result {
            try store.poll(p, now: now) { recoveries += 1 }
        }
        try check(try store.begin(now: 0) == nil)
        let first = try store.start()
        let p = try store.begin(now: 0)!
        try check(try poll(p, 2.999) == .waiting)
        try check(try store.respond(session: first))
        try check(try poll(p, 3) == .responded)
        assert(recoveries == 0 && defaults.bool(forKey: "broadcastActive"))
        let old = try store.begin(now: 20)!
        let new = try store.begin(now: 20)!
        try check(try poll(old, 31) == .superseded)
        // An old reply must not satisfy a new challenge.
        try check(try poll(new, 22.999) == .waiting)
        try check(try poll(new, 23) == .recovered)
        assert(recoveries == 1 && !defaults.bool(forKey: "broadcastActive"))
        try check(try !store.respond(session: first))
        try check(try poll(new, 31) != .recovered)
        let second = try store.start()
        let stale = try store.begin(now: 40)!
        let third = try store.start()
        try check(try poll(stale, 60) == .superseded)
        try check(try !store.stop(session: second))
        assert(defaults.bool(forKey: "broadcastActive"))
        try check(try store.stop(session: third))
        try check(try store.stop(session: third)) // pause followed by finish remains safe.
        try check(try store.begin(now: 70) == nil)
        // Legacy persisted flag without a session (upgrade from an older build).
        defaults.set(true, forKey: "broadcastActive")
        defaults.removeObject(forKey: RecordingHealthStore.sessionKey)
        let legacy = try store.begin(now: 80)!
        try check(try poll(legacy, 83) == .recovered)
        assert(recoveries == 2)
        // No frames are needed to prove liveness; latest reply wins over timeout.
        let live = try store.start()
        let slow = try store.begin(now: 100)!
        try check(try store.respond(session: live))
        try check(try poll(slow, 120) == .responded)
        // A last-moment reply and timeout race must have exactly one winner.
        for _ in 0..<20 {
            let session = try store.start()
            let race = try store.begin(now: 200)!
            let group = DispatchGroup()
            let resultsLock = NSLock()
            var replied = false
            var recovered = false
            for action in 0..<2 {
                group.enter()
                DispatchQueue.global().async {
                    if action == 0 {
                        let result = try! store.respond(session: session)
                        resultsLock.lock(); replied = result; resultsLock.unlock()
                    } else {
                        let result = try! store.poll(race, now: 203, recover: {})
                        resultsLock.lock(); recovered = result == .recovered; resultsLock.unlock()
                    }
                    group.leave()
                }
            }
            group.wait()
            assert(replied != recovered)
            assert(defaults.bool(forKey: "broadcastActive") == replied)
        }
        // A suspended lock owner cannot hang the host or cause a false recovery.
        _ = try store.start()
        let lockedProbe = try store.begin(now: 300)!
        let descriptor = open(lock.path, O_RDWR)
        assert(descriptor >= 0 && flock(descriptor, LOCK_EX) == 0)
        do {
            _ = try store.poll(lockedProbe, now: 303, recover: { fatalError("Must not recover without lock") })
            fatalError("Expected bounded lock contention")
        } catch RecordingHealthStore.StorageError.busy { }
        flock(descriptor, LOCK_UN)
        close(descriptor)
        assert(defaults.bool(forKey: "broadcastActive"))
        var window = RecordingHealthWindow()
        assert(!window.observe(active: true, now: 0))
        assert(window.observe(active: true, now: 0.25))
        assert(!window.observe(active: false, now: 1))
        assert(!window.observe(active: true, now: 20))
        assert(window.observe(active: true, now: 20.25))
        assert(!window.observe(active: true, now: 25))
        assert(!window.observe(active: true, now: 24))
        print("Recording health: liveness, recovery, stale replies/sessions, stop, legacy upgrade, foreground gaps passed")
    }
}
