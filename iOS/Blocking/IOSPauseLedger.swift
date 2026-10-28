#if os(iOS) || PAUSE_TESTS
import Foundation

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

    static func restBootIdentity(session: String?, bootTime: String?) -> String {
        // Prefer the same public source in every process. The host may have
        // access to bootsessionuuid while its sandboxed extensions do not.
        if let bootTime { return "boottime:" + bootTime }
        if let session, !session.isEmpty { return session }
        // Both kernel queries failed: refuse to shorten a rest across an
        // unidentifiable reboot. Never use a process-specific cached identity.
        return UUID().uuidString
    }
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

/// Mandatory detection rest; independent of pause quotas and strict-mode policy.
enum IOSRestAuthorization {
    static func allows(inExtension: Bool, localApproved: Bool, sharedApproved: Bool) -> Bool {
        // Extensions cannot independently query the host's Screen Time grant.
        // Revocation synchronized by the host still disables every rest grant.
        sharedApproved && (inExtension || localApproved)
    }
}

struct IOSDetectionRest: Codable, Identifiable {
    static let duration: TimeInterval = BlockingRules.restSeconds // Legacy records keep their original minute.
    var id = UUID().uuidString
    var target: String
    var selection: Data?
    var started: IOSPauseClock?
    var released: IOSPauseClock?
    var releaseRevision: Int?
    var requestedOrder: Double?
    var completed: Bool?
    var graceSeconds: TimeInterval?
    var durationSeconds: TimeInterval?
    var effectiveDuration: TimeInterval { durationSeconds ?? Self.duration }

    static func recordingGrace(target: String, selection: Data?, now: IOSPauseClock, revision: Int) -> Self {
        Self(target: target, selection: selection, started: now, released: now,
             releaseRevision: revision, completed: true, graceSeconds: BlockingRules.navigationGraceSeconds)
    }
    func remaining(_ now: IOSPauseClock) -> Double {
        guard let started, started.boot == now.boot, now.continuous >= started.continuous else { return effectiveDuration }
        return max(0, effectiveDuration - (now.continuous - started.continuous))
    }
    func graceRemaining(_ now: IOSPauseClock) -> Double {
        guard let released, released.boot == now.boot, now.continuous >= released.continuous else { return 0 }
        return max(0, (graceSeconds ?? BlockingRules.navigationGraceSeconds) - (now.continuous - released.continuous))
    }
    mutating func finishIfElapsed(_ now: IOSPauseClock) {
        if remaining(now) == 0 { completed = true }
    }
    mutating func release(id expectedID: String, now: IOSPauseClock, revision: Int) throws {
        guard id == expectedID, released == nil, completed == true || remaining(now) == 0 else { throw IOSPauseError.stale }
        completed = true
        released = now
        releaseRevision = revision
    }
    /// Applying Shield and opening the host share one idempotent clock start.
    mutating func startIfNeeded(_ now: IOSPauseClock) {
        guard released == nil, completed != true else { return }
        if started == nil || started?.boot != now.boot || now.continuous < started!.continuous { started = now }
    }
}

/// A dismissed sheet stays dismissed until a new explicit shield request arrives.
struct IOSRestPresentation {
    private struct Request: Equatable { var order: Double? }
    private var presented: [String: Request] = [:]

    func shouldPresent(_ rest: IOSDetectionRest) -> Bool {
        presented[rest.id] != Request(order: rest.requestedOrder)
    }

    mutating func acknowledge(_ rest: IOSDetectionRest) {
        presented[rest.id] = Request(order: rest.requestedOrder)
    }
}

/// Tracks transitions, not elapsed time: no votes/latches cross a pause or binding.
struct IOSRecorderBindings {
    private var selections: [String: Data] = [:]
    private(set) var pausedTarget: String?
    private(set) var revision = -1
    mutating func update(_ current: [String: Data], pausedTarget next: String?, revision nextRevision: Int) -> Set<String> {
        var changed = Set(selections.keys).union(current.keys).filter {
            BlockingRules.decide(BlockingContext(bindingChanged: revision != nextRevision || selections[$0] != current[$0]), .observation).resetObservations
        }
        if pausedTarget != next {
            if let pausedTarget { changed.insert(pausedTarget) }
            if let next { changed.insert(next) }
        }
        selections = current
        revision = nextRevision
        pausedTarget = next
        return changed
    }
}

enum IOSDetectionDisposition { case accepted, suppressedByPause }

struct IOSPauseLedger: Codable {
    // Optional for old ledgers. Failures are bound to the exact app selection;
    // a completed rest is never permission to bypass a failed classifier.
    var inferenceFailures: [String: Data]?
    func inferenceFailed(_ target: String, selection: Data?) -> Bool {
        guard let selection else { return false }
        return inferenceFailures?[target] == selection
    }

    mutating func invalidateBinding(_ target: String) {
        detectionRests?.removeValue(forKey: target)
        inferenceFailures?.removeValue(forKey: target)
    }

    struct RestProgress: Codable {
        var day: String
        var count: Int
    }
    var detectionRestProgress: [String: RestProgress]?
    var detectionRestZone: String?
    static let restSecondSteps = [5, 5, 5, 10, 10, 15, 20, 30, 40, 60]

    private mutating func nextRestDuration(target: String, now: IOSPauseClock, currentZone: String) -> TimeInterval {
        guard now.wall.isFinite,
              let today = try? day(now, zone: detectionRestZone ?? currentZone) else { return 60 }
        detectionRestZone = detectionRestZone ?? currentZone
        var progress = detectionRestProgress?[target] ?? RestProgress(day: today, count: 0)
        // A backward wall-clock or time-zone change must not reset escalation.
        if today > progress.day { progress = RestProgress(day: today, count: 0) }
        let index = min(max(0, progress.count), Self.restSecondSteps.count - 1)
        let duration = Self.restSecondSteps[index]
        progress.count = min(index + 1, Self.restSecondSteps.count - 1)
        if detectionRestProgress == nil { detectionRestProgress = [:] }
        detectionRestProgress?[target] = progress
        return TimeInterval(duration)
    }

    var detectionRests: [String: IOSDetectionRest]?
    mutating func requestDetectionRest(target: String, selection: Data?, now: IOSPauseClock,
                                       fromShieldAction: Bool, currentZone: String = TimeZone.current.identifier) {
        if let existing = detectionRests?[target], existing.selection == selection,
           (fromShieldAction && (existing.released == nil || existing.releaseRevision == revision)) ||
           (existing.released == nil && existing.completed != true) ||
           (existing.releaseRevision == revision && existing.graceRemaining(now) > 0) {
            if fromShieldAction { detectionRests?[target]?.requestedOrder = now.continuous }
            return
        }
        if detectionRests == nil { detectionRests = [:] }
        let duration = nextRestDuration(target: target, now: now, currentZone: currentZone)
        detectionRests?[target] = IOSDetectionRest(target: target, selection: selection,
            requestedOrder: fromShieldAction ? now.continuous : nil, durationSeconds: duration)
    }

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
    var selectedPauseMinutes: Int? // Legacy preference, decoded without changing active leases.
    var selectedPauseSeconds: Int?
    static let pauseSecondOptions = [30, 60, 180]
    var pauseSeconds: Int {
        if let value = selectedPauseSeconds {
            return Self.pauseSecondOptions.contains(value) ? value : 60
        }
        return selectedPauseMinutes == 3 ? 180 : 60
    }

    mutating func setPauseSeconds(_ seconds: Int, strict: Bool) throws {
        guard Self.pauseSecondOptions.contains(seconds) else { throw IOSPauseError.invalidTarget }
        guard !strict else { throw IOSPauseError.strict }
        selectedPauseSeconds = seconds
        selectedPauseMinutes = nil
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
        let seconds = TimeInterval(pauseSeconds)
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

#endif
