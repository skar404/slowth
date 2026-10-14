#if os(iOS) || PAUSE_TESTS
import Foundation
import SQLite3

enum IOSPauseError: Error { case unavailable, busy, exhausted, strict, invalidTarget, stale, storage }

enum IOSPauseStrictPolicy {
    static func blocksPause(strictModeActive: Bool, allowsPauses: Bool) -> Bool {
        strictModeActive && !allowsPauses
    }
}

struct IOSPauseClock: Codable {
    var wall: Double
    var continuous: Double
    var boot: String
}

struct IOSPauseLease: Codable {
    static let duration: TimeInterval = 180
    var id: String
    var kind: String
    var target: String
    var selection: Data?
    var started: IOSPauseClock
    var day: String
    var phase: String = "preparing"
    var charged = false
    // Missing in older records: those pauses required recording.
    var requiresRecording: Bool? = nil
    // Nil preserves the three-minute deadline for records from older builds.
    var durationSeconds: TimeInterval?
    var effectiveDuration: TimeInterval { durationSeconds ?? Self.duration }
    var expiresAt: Double { started.wall + effectiveDuration }
    func expired(_ now: IOSPauseClock) -> Bool {
        let elapsed = now.continuous - started.continuous
        return now.boot != started.boot || elapsed < 0 || elapsed >= effectiveDuration ||
            abs((now.wall - started.wall) - elapsed) > 3
    }
}

struct IOSPauseLedger: Codable {
    var version = 1
    var zone: String?
    var latestDay: String?
    var spent: [String: Int] = [:]
    var lease: IOSPauseLease?
    var lastID: String?
    var revision = 0
    var changedAt: Double = 0
    // Optional so existing version-1 records decode without a migration.
    var leafRewards: LeafRewards?
    var selectedPauseMinutes: Int?
    static let pauseMinuteOptions = [1, 3, 5]
    var pauseMinutes: Int {
        guard let value = selectedPauseMinutes, Self.pauseMinuteOptions.contains(value) else { return 3 }
        return value
    }

    mutating func setPauseMinutes(_ minutes: Int, strict: Bool) throws {
        guard Self.pauseMinuteOptions.contains(minutes) else { throw IOSPauseError.invalidTarget }
        guard !strict else { throw IOSPauseError.strict }
        selectedPauseMinutes = minutes
    }

    struct LeafRewards: Codable {
        var total: Int = 0
        var nextDay: String
    }

    var savedLeaves: Int { leafRewards?.total ?? 0 }

    mutating func accrueLeaves(_ now: IOSPauseClock, currentZone: String) throws {
        let rewardZone = zone ?? currentZone
        let today = try day(now, zone: rewardZone)
        guard var rewards = leafRewards else {
            zone = rewardZone
            leafRewards = LeafRewards(nextDay: max(today, latestDay ?? today))
            return
        }
        // A cross-midnight lease can still be activated or refunded. Settle its
        // day only after completion, so the reward uses the final charge.
        let end = min(today, lease?.day ?? today)
        guard end > rewards.nextDay else { return }
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.calendar = Calendar(identifier: .gregorian)
        formatter.timeZone = TimeZone(identifier: rewardZone)
        formatter.dateFormat = "yyyy-MM-dd"
        guard let startDate = formatter.date(from: rewards.nextDay),
              let endDate = formatter.date(from: end) else { throw IOSPauseError.storage }
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = formatter.timeZone
        let days = calendar.dateComponents([.day], from: startDate, to: endDate).day ?? 0
        let used = spent.filter { $0.key >= rewards.nextDay && $0.key < end }
            .values.reduce(0) { $0 + min(3, max(0, $1)) }
        rewards.total += max(0, days * 3 - used)
        rewards.nextDay = end
        leafRewards = rewards
    }

    func day(_ now: IOSPauseClock, zone: String) throws -> String {
        guard let tz = TimeZone(identifier: zone) else { throw IOSPauseError.storage }
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = tz
        let c = calendar.dateComponents([.year, .month, .day], from: Date(timeIntervalSince1970: now.wall))
        return String(format: "%04d-%02d-%02d", c.year!, c.month!, c.day!)
    }

    func remaining(_ now: IOSPauseClock, currentZone: String) throws -> Int {
        let key = try day(now, zone: zone ?? currentZone)
        if let latestDay, key < latestDay { return 0 }
        return max(0, 3 - spent[key, default: 0])
    }

    mutating func prepare(id: String, kind: String, target: String, selection: Data?,
                          now: IOSPauseClock, currentZone: String, strict: Bool,
                          requiresRecording: Bool? = nil) throws {
        if lease?.id == id || lastID == id { throw IOSPauseError.stale }
        guard !strict else { throw IOSPauseError.strict }
        guard lease == nil else { throw IOSPauseError.busy }
        guard try remaining(now, currentZone: currentZone) > 0 else { throw IOSPauseError.exhausted }
        try accrueLeaves(now, currentZone: currentZone)
        zone = zone ?? currentZone
        let key = try day(now, zone: zone!)
        lease = IOSPauseLease(id: id, kind: kind, target: target, selection: selection, started: now, day: key)
        lease?.requiresRecording = requiresRecording
        let seconds = TimeInterval(pauseMinutes * 60)
        lease?.durationSeconds = seconds
        revision += 1
        changedAt = now.wall
    }

    mutating func activate(_ id: String, now: IOSPauseClock, strict: Bool) throws {
        guard !strict else { throw IOSPauseError.strict }
        guard var value = lease, value.id == id, value.phase == "preparing",
              !value.expired(now), now.continuous - value.started.continuous < 15 else { throw IOSPauseError.stale }
        value.phase = "active"
        value.charged = true
        // The lease starts on the initiating tap; preparation never extends it.
        spent[value.day, default: 0] += 1
        latestDay = max(latestDay ?? value.day, value.day)
        lease = value
        revision += 1
    }

    mutating func switchApplication(id: String, from previousTarget: String, to target: String,
                                    selection: Data?, now: IOSPauseClock, strict: Bool) throws {
        guard !strict else { throw IOSPauseError.strict }
        guard var value = lease, value.id == id, value.kind == "application",
              value.phase == "active", value.charged, value.target == previousTarget,
              !value.expired(now) else { throw IOSPauseError.stale }
        guard !target.isEmpty, target != previousTarget, selection != nil else { throw IOSPauseError.invalidTarget }
        value.target = target
        value.selection = selection
        lease = value
        revision += 1
        changedAt = now.wall
    }

    mutating func finish(now: IOSPauseClock, refundKnownNonGrant: Bool = false) {
        guard let value = lease else { return }
        if refundKnownNonGrant && value.charged { spent[value.day, default: 0] = max(0, spent[value.day, default: 0] - 1) }
        lastID = value.id
        lease = nil
        revision += 1
        changedAt = now.wall
        try? accrueLeaves(now, currentZone: TimeZone.current.identifier)
        // Never prune charges for days whose rewards have not been settled.
        if spent.count > 8 {
            for key in spent.keys.sorted().dropLast(8) where key < (leafRewards?.nextDay ?? "") {
                spent.removeValue(forKey: key)
            }
        }
    }

    #if DEBUG || PAUSE_TESTS
    mutating func setSavedLeavesForDebug(_ count: Int, now: IOSPauseClock, currentZone: String) throws {
        guard (0...1_000_000).contains(count) else { throw IOSPauseError.invalidTarget }
        try accrueLeaves(now, currentZone: currentZone)
        leafRewards?.total = count
    }

    mutating func resetQuotaForDebug(now: IOSPauseClock) throws {
        guard lease == nil else { throw IOSPauseError.busy }
        spent.removeAll()
        latestDay = nil
        revision += 1
        changedAt = now.wall
    }
    #endif
}

/// A single SQLite row and BEGIN IMMEDIATE coordinate all extension processes.
/// OS writes inside a transaction still aren't atomic with SQLite; on crash,
/// the durable active/ending intent is reconciled again. No fallback defaults.
final class IOSPauseDatabase {
    let url: URL
    init(url: URL) { self.url = url }

    func transaction<T>(_ edit: (inout IOSPauseLedger) throws -> T) throws -> T {
        var connection: OpaquePointer?
        guard sqlite3_open_v2(url.path, &connection, SQLITE_OPEN_READWRITE | SQLITE_OPEN_CREATE | SQLITE_OPEN_FULLMUTEX, nil) == SQLITE_OK,
              let db = connection else {
            if let connection { sqlite3_close(connection) }; throw IOSPauseError.storage
        }
        defer { sqlite3_close(db) }
        sqlite3_busy_timeout(db, 2000)
        func execute(_ sql: String) throws {
            guard sqlite3_exec(db, sql, nil, nil, nil) == SQLITE_OK else { throw IOSPauseError.storage }
        }
        try execute("PRAGMA synchronous=FULL")
        try execute("CREATE TABLE IF NOT EXISTS state (id INTEGER PRIMARY KEY CHECK(id=1), value BLOB NOT NULL)")
        try execute("BEGIN IMMEDIATE")
        do {
            var query: OpaquePointer?
            guard sqlite3_prepare_v2(db, "SELECT value FROM state WHERE id=1", -1, &query, nil) == SQLITE_OK else { throw IOSPauseError.storage }
            var ledger = IOSPauseLedger()
            var old: Data?
            let step = sqlite3_step(query)
            if step == SQLITE_ROW, let bytes = sqlite3_column_blob(query, 0) {
                old = Data(bytes: bytes, count: Int(sqlite3_column_bytes(query, 0)))
            }
            sqlite3_finalize(query)
            guard step == SQLITE_ROW || step == SQLITE_DONE else { throw IOSPauseError.storage }
            if let old { ledger = try JSONDecoder().decode(IOSPauseLedger.self, from: old) }
            guard ledger.version == 1 else { throw IOSPauseError.storage }
            let result = try edit(&ledger)
            let encoder = JSONEncoder(); encoder.outputFormatting = [.sortedKeys]
            let data = try encoder.encode(ledger)
            if data != old {
                var insert: OpaquePointer?
                guard sqlite3_prepare_v2(db, "INSERT OR REPLACE INTO state(id,value) VALUES(1,?)", -1, &insert, nil) == SQLITE_OK else { throw IOSPauseError.storage }
                defer { sqlite3_finalize(insert) }
                let bound = data.withUnsafeBytes { ptr in
                    sqlite3_bind_blob(insert, 1, ptr.baseAddress, Int32(ptr.count), unsafeBitCast(-1, to: sqlite3_destructor_type.self))
                }
                guard bound == SQLITE_OK, sqlite3_step(insert) == SQLITE_DONE else { throw IOSPauseError.storage }
            }
            try execute("COMMIT")
            return result
        } catch {
            try? execute("ROLLBACK")
            throw error
        }
    }
}
#endif
