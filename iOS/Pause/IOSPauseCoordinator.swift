import Foundation
import Darwin
import FamilyControls
import ManagedSettings
import DeviceActivity

/// Coordinates durable, quota-bound pauses across the host and its extensions.
enum IOSPauseCoordinator {
    static let activityPrefix = "slowth.pause."
    static let sites = ["youtube", "instagram", "facebook", "x", "tiktok"]
    static let apps = ["youtube", "instagram", "facebook", "x"]

    #if DEBUG
    static func setSavedLeavesForDebug(_ count: Int) throws {
        guard DebugMode.isEnabled else { throw IOSPauseError.unavailable }
        try database().transaction { ledger in
            try ledger.setSavedLeavesForDebug(count, now: clock(), currentZone: TimeZone.current.identifier)
        }
    }

    static func resetPausesForDebug() throws {
        guard DebugMode.isEnabled else { throw IOSPauseError.unavailable }
        if let id = try presentationSnapshot().lease?.id {
            // Use normal completion to restore protection and end monitoring/activity.
            try finish(id: id)
        }
        // Refuse a concurrent new lease rather than clearing it without restoration.
        try resetQuotaForDebug()
        refreshLiveActivity()
    }

    static func resetQuotaForDebug() throws {
        guard DebugMode.isEnabled else { throw IOSPauseError.unavailable }
        try database().transaction { ledger in
            try ledger.resetQuotaForDebug(now: clock())
        }
    }
    #endif

    static func setPauseMinutes(_ minutes: Int) throws {
        try database().transaction { ledger in
            try ledger.setPauseMinutes(minutes, strict: SharedStore.snapshot().isStrictModeActive)
        }
    }

    static func strictModeBlocksPauses(_ state: SharedState) -> Bool {
        IOSPauseStrictPolicy.blocksPause(strictModeActive: state.isStrictModeActive,
                                        allowsPauses: SharedStore.pausesAllowedInStrictMode)
    }

    static func clock() -> IOSPauseClock {
        var value = timeval(); var size = MemoryLayout<timeval>.size
        var mib: [Int32] = [CTL_KERN, KERN_BOOTTIME]
        let rc = sysctl(&mib, 2, &value, &size, nil, 0)
        return IOSPauseClock(wall: Date().timeIntervalSince1970,
            continuous: Double(clock_gettime_nsec_np(CLOCK_MONOTONIC_RAW)) / 1_000_000_000,
            boot: rc == 0 ? "\(value.tv_sec):\(value.tv_usec)" : UUID().uuidString)
    }

    private static func database() throws -> IOSPauseDatabase {
        guard let root = FileManager.default.containerURL(forSecurityApplicationGroupIdentifier: AppGroup.identifier) else { throw IOSPauseError.storage }
        let folder = root.appendingPathComponent("TemporaryPauses", isDirectory: true)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true,
            attributes: [.protectionKey: FileProtectionType.completeUntilFirstUserAuthentication])
        return IOSPauseDatabase(url: folder.appendingPathComponent("state.sqlite"))
    }

    static func selection(_ target: String, state: SharedState) -> Data? {
        switch target {
        case "youtube": return state.youtubeSelectionData
        case "instagram": return state.instagramSelectionData
        case "facebook": return state.facebookSelectionData
        case "x": return state.xSelectionData
        default: return nil
        }
    }
    private static func decoded(_ data: Data?) -> FamilyActivitySelection? {
        guard let data, let s = try? JSONDecoder().decode(FamilyActivitySelection.self, from: data),
              s.applicationTokens.count == 1, s.categoryTokens.isEmpty, s.webDomainTokens.isEmpty else { return nil }
        return s
    }
    static func enabled(_ target: String, state: SharedState) -> Bool {
        guard state.realtimeShieldEnabled else { return false }
        switch target {
        case "youtube": return state.realtimeYouTubeBlockingEnabled
        case "instagram": return state.realtimeInstagramBlockingEnabled
        case "facebook": return state.realtimeFacebookBlockingEnabled
        case "x": return state.realtimeXBlockingEnabled
        default: return false
        }
    }
    private static func store(_ target: String) -> ManagedSettingsStore {
        ManagedSettingsStore(named: .init("RealtimeShield.\(target)"))
    }
    private static func write(_ target: String, selection: FamilyActivitySelection?) {
        let s = store(target)
        s.shield.applications = selection.flatMap { $0.applicationTokens.isEmpty ? nil : $0.applicationTokens }
        s.shield.applicationCategories = selection.flatMap { $0.categoryTokens.isEmpty ? nil : .specific($0.categoryTokens) }
    }

    private static func valid(_ lease: IOSPauseLease, state: SharedState) -> Bool {
        guard !strictModeBlocksPauses(state) else { return false }
        if lease.kind == "safari" {
            return sites.contains(lease.target) && state.toggles[lease.target].map { $0.dictionary.values.contains(true) } == true
        }
        guard (lease.requiresRecording == false || state.broadcastActive), enabled(lease.target, state: state),
              let actual = decoded(selection(lease.target, state: state)),
              let bound = decoded(lease.selection), actual.applicationTokens == bound.applicationTokens else { return false }
        return !apps.filter { $0 != lease.target }.contains { other in
            decoded(selection(other, state: state)).map { !$0.applicationTokens.isDisjoint(with: actual.applicationTokens) } ?? false
        }
    }

    /// Current runtime wishes are updated even while the temporary overlay hides Shield.
    /// They are not user preferences. A stopped/stale recorder defaults to protection.
    private static func restore(_ lease: IOSPauseLease, state: SharedState) {
        guard lease.kind == "application" else { return }
        let target = lease.target
        guard enabled(target, state: state), let current = decoded(selection(target, state: state)) else {
            write(target, selection: nil); return
        }
        if !state.broadcastActive && target == "youtube" && state.softYouTubeBlockingEnabled && state.youtubeShieldRestoreDeferred {
            write(target, selection: nil); return
        }
        let d = AppGroup.defaults
        let age = Date().timeIntervalSince1970 - d.double(forKey: "pause.runtime.\(target).at")
        let wantsShield = d.object(forKey: "pause.runtime.\(target).shield") as? Bool ?? true
        let shield = !state.broadcastActive || age < 0 || age > 3 || wantsShield
        write(target, selection: shield ? current : nil)
    }

    private static func reconcile(_ ledger: inout IOSPauseLedger, now: IOSPauseClock,
                                  enforceApplications: Bool) {
        guard let lease = ledger.lease else { return }
        let state = SharedStore.snapshot()
        let stalePreparation = lease.phase == "preparing" && now.continuous - lease.started.continuous > 15
        guard lease.expired(now) || !valid(lease, state: state) || lease.phase == "ending" || stalePreparation else { return }
        if lease.kind == "application" && !enforceApplications { return }
        if lease.phase != "preparing" { restore(lease, state: state) }
        ledger.finish(now: now)
    }

    static func snapshot(enforceApplications: Bool = true) throws -> IOSPauseLedger {
        let result = try database().transaction { ledger in
            let now = clock()
            reconcile(&ledger, now: now, enforceApplications: enforceApplications)
            try ledger.accrueLeaves(now, currentZone: TimeZone.current.identifier)
            return ledger
        }
        refreshLiveActivity()
        return result
    }

    /// Read only: presentation must not itself change protection or spend attempts.
    static func presentationSnapshot() throws -> IOSPauseLedger {
        try database().transaction { $0 }
    }

    private static func refreshLiveActivity() {
        if #available(iOS 16.2, *) {
            Task { await IOSPauseLiveActivity.shared.synchronize() }
        }
    }

    /// All Shield writers pass through the same process-wide database lock.
    static func intercept(target: String, requested: FamilyActivitySelection?) -> Bool {
        // Never affect an installation that has not started a pause.
        guard AppGroup.defaults.bool(forKey: "pause.hasStarted") else { return false }
        var endedPause = false
        do {
            try database().transaction { ledger in
                let now = clock()
                let state = SharedStore.snapshot()
                let previous = ledger.lease
                // Read/reconcile before recording this request: a delayed clear must
                // not act as evidence that the broadcast extension is still alive.
                reconcile(&ledger, now: now, enforceApplications: true)
                endedPause = previous != nil && ledger.lease == nil
                if let previous, previous.kind == "application", previous.target == target,
                   ledger.lease == nil {
                    // Reconciliation already wrote the current policy. Do not undo it
                    // with the request that happened to discover the expired lease.
                    return
                }
                if Bundle.main.bundleIdentifier?.hasSuffix(".Broadcast") == true ||
                    Bundle.main.bundleIdentifier?.contains("Broadcast") == true {
                    AppGroup.defaults.set(requested != nil, forKey: "pause.runtime.\(target).shield")
                    AppGroup.defaults.set(now.wall, forKey: "pause.runtime.\(target).at")
                }
                if let lease = ledger.lease, lease.phase == "active", lease.kind == "application",
                   lease.target == target, !lease.expired(now), valid(lease, state: state) {
                    write(target, selection: nil)
                } else {
                    write(target, selection: requested)
                }
            }
            if endedPause { refreshLiveActivity() }
        } catch {
            // An unreadable coordinator must never authorize an unbounded clear.
            let state = SharedStore.snapshot()
            if enabled(target, state: state) {
                if let s = decoded(selection(target, state: state)) { write(target, selection: s) }
            } else { write(target, selection: requested) }
        }
        return true
    }

    static func canStartApplicationPause(target: String) -> Bool {
        guard FamilyControlsAuthStatus.approved, apps.contains(target),
              let ledger = try? snapshot(), ledger.lease == nil else { return false }
        let now = clock()
        guard let remaining = try? ledger.remaining(now, currentZone: TimeZone.current.identifier),
              remaining > 0 else { return false }
        let state = SharedStore.snapshot()
        let candidate = IOSPauseLease(id: "eligibility", kind: "application", target: target,
            selection: selection(target, state: state), started: now, day: "",
            requiresRecording: state.broadcastActive)
        return valid(candidate, state: state)
    }

    static func applicationSwitchTargets(_ ledger: IOSPauseLedger, state: SharedState,
                                         now: IOSPauseClock) -> [String] {
        guard FamilyControlsAuthStatus.approved,
              let lease = ledger.lease, lease.kind == "application", lease.phase == "active",
              lease.charged, !lease.expired(now), valid(lease, state: state) else { return [] }
        return apps.filter { target in
            guard target != lease.target else { return false }
            var candidate = lease
            candidate.target = target
            candidate.selection = selection(target, state: state)
            return valid(candidate, state: state)
        }
    }

    static func switchApplication(id: String, from previousTarget: String, to target: String) throws {
        guard FamilyControlsAuthStatus.approved else { throw IOSPauseError.unavailable }
        let db = try database()
        // Restore the previous target before committing the new owner. Only a
        // separate transaction may clear the new target after that commit. A
        // crash between these steps can leave protection on, never two grants.
        let revision = try db.transaction { ledger -> Int in
            let now = clock()
            let state = SharedStore.snapshot()
            guard let previous = ledger.lease,
                  applicationSwitchTargets(ledger, state: state, now: now).contains(target) else {
                throw IOSPauseError.invalidTarget
            }
            try ledger.switchApplication(id: id, from: previousTarget, to: target,
                selection: selection(target, state: state), now: now,
                strict: strictModeBlocksPauses(state))
            restore(previous, state: state)
            return ledger.revision
        }
        defer { refreshLiveActivity() }
        try db.transaction { ledger in
            guard ledger.revision == revision, let current = ledger.lease,
                  current.id == id, current.target == target, current.phase == "active",
                  !current.expired(clock()), valid(current, state: SharedStore.snapshot()) else {
                throw IOSPauseError.stale
            }
            write(target, selection: nil)
        }
    }

    static func startApplication(target: String, id: String) throws {
        guard FamilyControlsAuthStatus.approved else { throw IOSPauseError.unavailable }
        let db = try database()
        let now = clock()
        let lease = try db.transaction { ledger -> IOSPauseLease in
            reconcile(&ledger, now: now, enforceApplications: true)
            let state = SharedStore.snapshot()
            guard !strictModeBlocksPauses(state) else { throw IOSPauseError.strict }
            let candidate = IOSPauseLease(id: id, kind: "application", target: target,
                selection: selection(target, state: state), started: now, day: "",
                requiresRecording: state.broadcastActive)
            guard valid(candidate, state: state) else { throw IOSPauseError.invalidTarget }
            try ledger.prepare(id: id, kind: "application", target: target, selection: candidate.selection,
                now: now, currentZone: TimeZone.current.identifier, strict: strictModeBlocksPauses(state),
                requiresRecording: candidate.requiresRecording)
            return ledger.lease!
        }
        AppGroup.defaults.set(true, forKey: "pause.hasStarted")
        let name = DeviceActivityName(activityPrefix + id)
        var mayHaveGranted = false
        do {
            var calendar = Calendar(identifier: .gregorian); calendar.timeZone = TimeZone(secondsFromGMT: 0)!
            func components(_ date: Double) -> DateComponents {
                var c = calendar.dateComponents([.year, .month, .day, .hour, .minute, .second], from: Date(timeIntervalSince1970: date))
                c.calendar = calendar; c.timeZone = calendar.timeZone; return c
            }
            let end = ceil(lease.expiresAt)
            let schedule = DeviceActivitySchedule(intervalStart: components(end - 900), intervalEnd: components(end), repeats: false)
            try DeviceActivityCenter().startMonitoring(name, during: schedule)
            try db.transaction { ledger in
                guard let current = ledger.lease, current.id == id, valid(current, state: SharedStore.snapshot()) else { throw IOSPauseError.stale }
                try ledger.activate(id, now: clock(), strict: strictModeBlocksPauses(SharedStore.snapshot()))
            }
            try db.transaction { ledger in
                guard let current = ledger.lease, current.id == id, current.phase == "active",
                      !current.expired(clock()), valid(current, state: SharedStore.snapshot()) else { throw IOSPauseError.stale }
                mayHaveGranted = true
                write(target, selection: nil)
            }
        } catch {
            let original = error
            // If compensation fails, retain the monitor and durable lease for retry.
            if (try? finish(id: id, refundKnownNonGrant: !mayHaveGranted)) != nil {
                DeviceActivityCenter().stopMonitoring([name])
            }
            throw original
        }
    }

    static func finish(id: String, refundKnownNonGrant: Bool = false) throws {
        let db = try database()
        try db.transaction { ledger in
            guard ledger.lease?.id == id else { return }
            ledger.lease?.phase = "ending"
            ledger.revision += 1; ledger.changedAt = clock().wall
        }
        try db.transaction { ledger in
            guard let lease = ledger.lease, lease.id == id else { return }
            restore(lease, state: SharedStore.snapshot())
            ledger.finish(now: clock(), refundKnownNonGrant: refundKnownNonGrant)
        }
        DeviceActivityCenter().stopMonitoring([DeviceActivityName(activityPrefix + id)])
        refreshLiveActivity()
    }

    static func acceptsNavigationUnlock(at date: Date) -> Bool {
        guard AppGroup.defaults.bool(forKey: "pause.hasStarted") else { return true }
        return (try? database().transaction { $0.changedAt <= date.timeIntervalSince1970 }) ?? false
    }
    static func revision() -> Int {
        guard AppGroup.defaults.bool(forKey: "pause.hasStarted") else { return 0 }
        return (try? database().transaction { $0.revision }) ?? -1
    }
    static func navigationUnlock(target: String, expectedRevision: Int, request: () -> Void) -> Bool {
        return (try? database().transaction { ledger in
            guard ledger.revision == expectedRevision, SharedStore.snapshot().broadcastActive else { return false }
            let previous = ledger.lease
            reconcile(&ledger, now: clock(), enforceApplications: true)
            guard previous?.id == ledger.lease?.id else { return false }
            request()
            write(target, selection: nil)
            return true
        }) ?? false
    }
    static func callback(_ activity: DeviceActivityName) {
        guard activity.rawValue.hasPrefix(activityPrefix) else { return }
        _ = try? snapshot()
    }

    static func prepareSafari(target: String, id: String) throws {
        let now = clock()
        try database().transaction { ledger in
            reconcile(&ledger, now: now, enforceApplications: true)
            let state = SharedStore.snapshot()
            guard sites.contains(target), state.toggles[target].map({ $0.dictionary.values.contains(true) }) == true else { throw IOSPauseError.invalidTarget }
            try ledger.prepare(id: id, kind: "safari", target: target, selection: nil,
                now: now, currentZone: TimeZone.current.identifier, strict: strictModeBlocksPauses(state))
        }
        AppGroup.defaults.set(true, forKey: "pause.hasStarted")
    }

    static func safariState() -> [String: Any]? {
        guard let state = try? snapshot(enforceApplications: false),
              let lease = state.lease, lease.kind == "safari", !lease.expired(clock()) else { return nil }
        return ["id": lease.id, "target": lease.target, "phase": lease.phase,
                "startedAt": lease.started.wall, "expiresAt": lease.expiresAt, "revision": state.revision]
    }

    static func acknowledgeSafari(_ id: String) throws {
        try database().transaction { ledger in
            guard let lease = ledger.lease, lease.id == id, lease.kind == "safari",
                  valid(lease, state: SharedStore.snapshot()), !lease.expired(clock()) else { throw IOSPauseError.stale }
            if lease.phase == "active" { return }
            try ledger.activate(id, now: clock(), strict: strictModeBlocksPauses(SharedStore.snapshot()))
        }
        refreshLiveActivity()
    }

    static func cancelSafariPreparation(_ id: String) throws {
        try database().transaction { ledger in
            guard let lease = ledger.lease, lease.id == id, lease.kind == "safari", lease.phase == "preparing" else { return }
            ledger.finish(now: clock())
        }
        refreshLiveActivity()
    }

    private enum FamilyControlsAuthStatus {
        static var approved: Bool { AuthorizationCenter.shared.authorizationStatus == .approved }
    }
}
