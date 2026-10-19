import Foundation
import Darwin
#if !PAUSE_COORDINATOR_TESTS
import FamilyControls
import ManagedSettings
import DeviceActivity
#endif

/// Coordinates durable, quota-bound pauses across the host and its extensions.
enum IOSPauseCoordinator {
    static let activityPrefix = "slowth.pause."
    static let sites = ["youtube", "instagram", "facebook", "x", "tiktok"]
    static let apps = ["youtube", "instagram", "facebook", "x"] + PauseOnlyApps.targets

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

    static func clock() -> IOSPauseClock { BlockingClock.clock() }
    static func restClock() -> IOSPauseClock { BlockingClock.restClock() }
    private static func database() throws -> IOSPauseDatabase { try BlockingStorage.database() }

    private static var inExtension: Bool {
        #if PAUSE_COORDINATOR_TESTS
        return CoordinatorTestEnvironment.inExtension
        #else
        return Bundle.main.bundleURL.pathExtension == "appex"
        #endif
    }

    static func protectionAuthorized(_ state: SharedState) -> Bool {
        let status = AuthorizationCenter.shared.authorizationStatus
        let approved = IOSProtectionAuthorization.approved(status)
        return IOSRestAuthorization.allows(inExtension: inExtension,
            localApproved: approved, sharedApproved: state.realtimeShieldEnabled)
    }

    /// A new/resumed recording starts with five safe seconds. Commit the shared
    /// grants before the recorder clears shields, including old waiting rests.
    static func beginRecordingGrace() throws {
        try database().transaction { ledger in
            let state = SharedStore.snapshot()
            guard state.broadcastActive, protectionAuthorized(state) else { throw IOSPauseError.unavailable }
            let now = restClock()
            if ledger.detectionRests == nil { ledger.detectionRests = [:] }
            for target in apps where !PauseOnlyApps.contains(target) && enabled(target, state: state) {
                guard let selected = selection(target, state: state), decoded(selected) != nil else { continue }
                ledger.detectionRests?[target] = .recordingGrace(target: target, selection: selected,
                    now: now, revision: ledger.revision)
            }
        }
    }

    @discardableResult
    static func requestRest(target: String, prioritize: Bool = false,
                            expectedSelection: Data? = nil, expectedRevision: Int? = nil) throws -> IOSDetectionDisposition {
        try database().transaction { ledger in
            let state = SharedStore.snapshot()
            let selected = selection(target, state: state)
            let paused = ledger.lease.map {
                $0.kind == "application" && $0.target == target && $0.phase == "active" &&
                !$0.expired(clock()) && valid($0, state: state)
            } ?? false
            let context = BlockingContext(target: target, enabled: enabled(target, state: state),
                recording: state.broadcastActive, pauseOnly: PauseOnlyApps.contains(target),
                activePause: paused, inferenceFailed: ledger.inferenceFailed(target, selection: selected),
                currentBinding: (expectedRevision == nil || expectedRevision == ledger.revision) &&
                    (expectedSelection == nil || expectedSelection == selected))
            switch BlockingRules.decide(context, .contentDetected).detection {
            case .unavailable: throw IOSPauseError.unavailable
            case .stale: throw IOSPauseError.stale
            case .suppress: return .suppressedByPause
            case .accept: break
            case nil: throw IOSPauseError.unavailable
            }
            ledger.requestDetectionRest(target: target, selection: selection(target, state: state),
                now: restClock(), fromShieldAction: prioritize)
            return .accepted
        }
    }

    /// Reconcile a stale system Shield without creating another rest or
    /// extending a grant. A newer detection replaces the record and fails this check.
    static func returnToApplicationAfterRest(target: String) throws -> Bool {
        try advanceRests()
        return try database().transaction { ledger in
            let state = SharedStore.snapshot()
            guard state.broadcastActive, protectionAuthorized(state),
                  enabled(target, state: state), ledger.lease == nil,
                  let rest = ledger.detectionRests?[target], rest.released != nil,
                  rest.releaseRevision == ledger.revision,
                  rest.selection == selection(target, state: state), decoded(rest.selection) != nil,
                  !ledger.inferenceFailed(target, selection: rest.selection) else { return false }
            write(target, selection: nil)
            return true
        }
    }

    /// Called by the foreground host and the recording extension. Completion
    /// persists even without recording; a grant still requires all normal checks.
    static func advanceRests() throws {
        #if DEBUG
        defer { publishRestDiagnostics() }
        #endif
        let ready = try database().transaction { ledger -> [IOSDetectionRest] in
            reconcile(&ledger, now: clock(), enforceApplications: true)
            let now = restClock()
            let state = SharedStore.snapshot()
            for target in Array((ledger.detectionRests ?? [:]).keys) {
                // Restart an unfinished running clock after reboot, even without
                // opening the host. Legacy unstarted records wait for Shield/open.
                if ledger.detectionRests?[target]?.started != nil {
                    ledger.detectionRests?[target]?.startIfNeeded(now)
                }
                ledger.detectionRests?[target]?.finishIfElapsed(now)
            }
            guard state.broadcastActive, protectionAuthorized(state), ledger.lease == nil else { return [] }
            return (ledger.detectionRests ?? [:]).values.filter {
                $0.completed == true && $0.released == nil && enabled($0.target, state: state) &&
                !ledger.inferenceFailed($0.target, selection: $0.selection) &&
                $0.selection == selection($0.target, state: state) && decoded($0.selection) != nil
            }
        }
        for rest in ready {
            // A competing process may already have granted this exact cycle.
            // Its persisted deadline must never be extended on retry.
            try? releaseRest(target: rest.target, id: rest.id)
        }
        // Repair a stale OS shield after a grant, but only when the recorder's
        // latest serialized request is clear. A new detection replaces the cycle;
        // classifier failure/recording stop requests protection and is preserved.
        try database().transaction { ledger in
            let state = SharedStore.snapshot()
            guard state.broadcastActive, protectionAuthorized(state), ledger.lease == nil else { return }
            for (target, rest) in ledger.detectionRests ?? [:] {
                guard rest.released != nil, rest.releaseRevision == ledger.revision,
                      enabled(target, state: state), rest.selection == selection(target, state: state),
                      !ledger.inferenceFailed(target, selection: rest.selection),
                      AppGroup.defaults.object(forKey: "pause.runtime.\(target).shield") as? Bool == false else { continue }
                write(target, selection: nil)
            }
        }
    }

    #if DEBUG
    private static func publishRestDiagnostics() {
        let source = Bundle.main.bundleIdentifier?.hasSuffix(".Broadcast") == true ? "broadcast" : "host"
        let defaults = AppGroup.defaults
        let key = "debug.rest." + source
        let now = restClock()
        if now.continuous - defaults.double(forKey: key + ".at") < 1 { return }
        guard let report = try? database().transaction({ ledger -> [String: Any] in
            var report: [String: Any] = ["recording": SharedStore.snapshot().broadcastActive,
                "authorized": protectionAuthorized(SharedStore.snapshot()),
                "localAuthorization": String(describing: AuthorizationCenter.shared.authorizationStatus), "pauseActive": ledger.lease != nil]
            for (target, rest) in ledger.detectionRests ?? [:] {
                report[target] = ["started": rest.started != nil, "remaining": rest.remaining(now),
                    "completed": rest.completed == true, "released": rest.released != nil,
                    "grace": rest.graceRemaining(now), "sameBoot": rest.started?.boot == now.boot,
                    "sameRevision": rest.releaseRevision == ledger.revision]
            }
            return report
        }) else { return }
        defaults.set(report, forKey: key)
        defaults.set(now.continuous, forKey: key + ".at")
    }
    #endif

    static func openRests() throws -> [IOSDetectionRest] {
        try advanceRests()
        return try database().transaction { ledger in
            let now = restClock()
            let state = SharedStore.snapshot()
            for target in Array((ledger.detectionRests ?? [:]).keys) {
                guard enabled(target, state: state), ledger.detectionRests?[target]?.selection == selection(target, state: state) else {
                    ledger.detectionRests?.removeValue(forKey: target); continue
                }
                ledger.detectionRests?[target]?.startIfNeeded(now)
            }
            let pausedTarget: String? = ledger.lease.flatMap { lease in
                lease.kind == "application" && lease.phase == "active" &&
                !lease.expired(clock()) && valid(lease, state: state) ? lease.target : nil
            }
            return (ledger.detectionRests ?? [:]).values.filter {
                $0.released == nil && $0.completed != true && $0.target != pausedTarget
            }.sorted {
                if $0.requestedOrder != $1.requestedOrder { return ($0.requestedOrder ?? -1) > ($1.requestedOrder ?? -1) }
                return $0.target < $1.target
            }
        }
    }

    static func releaseRest(target: String, id: String) throws {
        try database().transaction { ledger in
            reconcile(&ledger, now: clock(), enforceApplications: true)
            let now = restClock()
            let state = SharedStore.snapshot()
            guard var rest = ledger.detectionRests?[target], rest.id == id,
                  rest.released == nil, rest.completed == true || rest.remaining(now) == 0,
                  protectionAuthorized(state), state.broadcastActive, enabled(target, state: state),
                  rest.selection == selection(target, state: state),
                  !ledger.inferenceFailed(target, selection: rest.selection),
                  decoded(rest.selection) != nil, ledger.lease == nil else { throw IOSPauseError.unavailable }
            try rest.release(id: id, now: now, revision: ledger.revision)
            ledger.detectionRests?[target] = rest
        }
        // Commit the grant before touching the OS. A crash cannot leave an
        // unrecorded clear or let a repeated tap extend the five-second deadline.
        try database().transaction { ledger in
            let state = SharedStore.snapshot()
            guard let rest = ledger.detectionRests?[target], rest.id == id,
                  rest.graceRemaining(restClock()) > 0, rest.releaseRevision == ledger.revision,
                  protectionAuthorized(state), state.broadcastActive,
                  enabled(target, state: state), rest.selection == selection(target, state: state),
                  !ledger.inferenceFailed(target, selection: rest.selection),
                  ledger.lease == nil else { throw IOSPauseError.stale }
            write(target, selection: nil)
        }
    }

    static func restGrants() -> [String: IOSDetectionRest] {
        try? advanceRests()
        return (try? database().transaction { ledger in
            let state = SharedStore.snapshot()
            guard state.broadcastActive, ledger.lease == nil else { return [:] }
            return (ledger.detectionRests ?? [:]).filter { target, rest in
                enabled(target, state: state) && rest.released != nil &&
                !ledger.inferenceFailed(target, selection: rest.selection) &&
                rest.releaseRevision == ledger.revision && rest.selection == selection(target, state: state)
            }
        }) ?? [:]
    }

    static func setInferenceFailure(_ failed: Bool, state observed: SharedState, target affectedTarget: String? = nil) throws {
        try database().transaction { ledger in
            let current = SharedStore.snapshot()
            for target in apps where !PauseOnlyApps.contains(target) && (affectedTarget == nil || affectedTarget == target) {
                guard let selected = selection(target, state: observed),
                      selected == selection(target, state: current) else { continue }
                if failed && enabled(target, state: current) {
                    if ledger.inferenceFailures == nil { ledger.inferenceFailures = [:] }
                    ledger.inferenceFailures?[target] = selected
                } else {
                    ledger.inferenceFailures?.removeValue(forKey: target)
                }
            }
        }
    }

    static func recordingPolicy() throws -> (pausedTarget: String?, revision: Int) {
        var endedPause = false
        defer { if endedPause { refreshLiveActivity() } }
        return try database().transaction { ledger in
            let previous = ledger.lease
            reconcile(&ledger, now: clock(), enforceApplications: true)
            endedPause = previous != nil && ledger.lease == nil
            let target = ledger.lease.flatMap { $0.kind == "application" && $0.phase == "active" ? $0.target : nil }
            return (target, ledger.revision)
        }
    }

    /// Called after a successful settings write, before returning control to the UI.
    static func selectionDidChange(target: String, previousSelection: Data?) throws {
        let currentSelection = selection(target, state: SharedStore.snapshot())
        guard decoded(previousSelection)?.applicationTokens != decoded(currentSelection)?.applicationTokens else { return }
        var endedID: String?
        try database().transaction { ledger in
            let state = SharedStore.snapshot()
            if let lease = ledger.lease, lease.kind == "application", lease.target == target {
                endedID = lease.id
                ledger.finish(now: clock())
            }
            ledger.invalidateBinding(target)
            AppGroup.defaults.removeObject(forKey: "pause.runtime.\(target).shield")
            AppGroup.defaults.removeObject(forKey: "pause.runtime.\(target).at")
            // Replaces the whole named store, dropping the old token immediately.
            // A healthy recorder can clear the new binding on its next frame.
            write(target, selection: enabled(target, state: state) && protectionAuthorized(state)
                ? decoded(selection(target, state: state)) : nil)
        }
        if let endedID { BlockingPauseMonitor.stop([DeviceActivityName(activityPrefix + endedID)]) }
        refreshLiveActivity()
    }

    static func selection(_ target: String, state: SharedState) -> Data? {
        if PauseOnlyApps.contains(target) { return PauseOnlyApps.data(target) }
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
        if PauseOnlyApps.contains(target) { return PauseOnlyApps.selection(target) != nil }
        guard state.realtimeShieldEnabled else { return false }
        switch target {
        case "youtube": return state.realtimeYouTubeBlockingEnabled
        case "instagram": return state.realtimeInstagramBlockingEnabled
        case "facebook": return state.realtimeFacebookBlockingEnabled
        case "x": return state.realtimeXBlockingEnabled
        default: return false
        }
    }
    private static func write(_ target: String, selection: FamilyActivitySelection?) {
        BlockingShield.write(target, selection: selection)
    }

    static func hasSelectionConflict(_ target: String, state: SharedState) -> Bool {
        guard let actual = decoded(selection(target, state: state)) else { return false }
        return apps.filter { $0 != target }.contains { other in
            decoded(selection(other, state: state)).map { !$0.applicationTokens.isDisjoint(with: actual.applicationTokens) } ?? false
        }
    }

    static func inferenceUnavailable(_ target: String) -> Bool {
        let state = SharedStore.snapshot()
        guard state.broadcastActive, enabled(target, state: state) else { return false }
        return (try? database().transaction { ledger in
            ledger.inferenceFailed(target, selection: selection(target, state: state))
        }) ?? true
    }

    private static func valid(_ lease: IOSPauseLease, state: SharedState) -> Bool {
        guard !strictModeBlocksPauses(state) else { return false }
        if lease.kind == "safari" {
            return sites.contains(lease.target) && state.toggles[lease.target].map { $0.dictionary.values.contains(true) } == true
        }
        guard (lease.requiresRecording == false || state.broadcastActive), enabled(lease.target, state: state),
              let actual = decoded(selection(lease.target, state: state)),
              let bound = decoded(lease.selection), actual.applicationTokens == bound.applicationTokens else { return false }
        return !hasSelectionConflict(lease.target, state: state)
    }

    /// Current runtime wishes are updated even while the temporary overlay hides Shield.
    /// They are not user preferences. A stopped/stale recorder defaults to protection.
    private static func restore(_ lease: IOSPauseLease, state: SharedState, rest: IOSDetectionRest?, inferenceFailed: Bool = false) {
        guard lease.kind == "application" else { return }
        let target = lease.target
        let current = decoded(selection(target, state: state))
        let age = Date().timeIntervalSince1970 - AppGroup.defaults.double(forKey: "pause.runtime.\(target).at")
        var context = BlockingContext(target: target, enabled: enabled(target, state: state),
            recording: state.broadcastActive, pauseOnly: PauseOnlyApps.contains(target),
            inferenceFailed: inferenceFailed,
            pendingRest: rest != nil && rest?.released == nil && rest?.completed != true && rest?.selection == selection(target, state: state),
            soft: state.softYouTubeBlockingEnabled, deferred: state.youtubeShieldRestoreDeferred,
            validSelection: current != nil)
        context.runtimeFresh = age >= 0 && age <= 3
        context.runtimeWantsShield = AppGroup.defaults.object(forKey: "pause.runtime.\(target).shield") as? Bool ?? true
        let decision = BlockingRules.decide(context, .pauseEnded)
        write(target, selection: decision.shield == .block ? current : nil)
    }

    private static func reconcile(_ ledger: inout IOSPauseLedger, now: IOSPauseClock,
                                  enforceApplications: Bool) {
        guard let lease = ledger.lease else { return }
        let state = SharedStore.snapshot()
        let stalePreparation = lease.phase == "preparing" && now.continuous - lease.started.continuous > 15
        guard lease.expired(now) || !valid(lease, state: state) || lease.phase == "ending" || stalePreparation else { return }
        if lease.kind == "application" && !enforceApplications { return }
        if lease.phase != "preparing" { restore(lease, state: state, rest: ledger.detectionRests?[lease.target], inferenceFailed: ledger.inferenceFailed(lease.target, selection: selection(lease.target, state: state))) }
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
                let restHiddenByPause = ledger.lease.map {
                    $0.kind == "application" && $0.target == target && $0.phase == "active" &&
                    !$0.expired(now) && valid($0, state: state)
                } ?? false
                let rest = ledger.detectionRests?[target]
                let boundRest = rest?.selection == selection(target, state: state)
                let context = BlockingContext(target: target, enabled: enabled(target, state: state),
                    recording: state.broadcastActive, pauseOnly: PauseOnlyApps.contains(target),
                    activePause: restHiddenByPause,
                    inferenceFailed: ledger.inferenceFailed(target, selection: selection(target, state: state)),
                    pendingRest: boundRest && rest != nil && rest?.released == nil && rest?.completed != true,
                    graceActive: boundRest && rest?.releaseRevision == ledger.revision && (rest?.graceRemaining(restClock()) ?? 0) > 0,
                    requestedShield: requested != nil)
                let decision = BlockingRules.decide(context, .shieldRequest)
                if decision.shield == .block {
                    // Start only a bound detection cycle when protection is applied.
                    // Repeated writes/openings keep its original monotonic deadline.
                    if boundRest, rest != nil {
                        ledger.detectionRests?[target]?.startIfNeeded(restClock())
                    }
                    write(target, selection: decision.useRequestedSelection ? requested : decoded(selection(target, state: state)))
                } else {
                    write(target, selection: nil)
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
            requiresRecording: !PauseOnlyApps.contains(target) && state.broadcastActive)
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
            restore(previous, state: state, rest: ledger.detectionRests?[previous.target],
                inferenceFailed: ledger.inferenceFailed(previous.target, selection: selection(previous.target, state: state)))
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
                requiresRecording: !PauseOnlyApps.contains(target) && state.broadcastActive)
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
            try BlockingPauseMonitor.start(name, lease: lease)
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
                BlockingPauseMonitor.stop([name])
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
            let state = SharedStore.snapshot()
            restore(lease, state: state, rest: ledger.detectionRests?[lease.target],
                inferenceFailed: ledger.inferenceFailed(lease.target, selection: selection(lease.target, state: state)))
            ledger.finish(now: clock(), refundKnownNonGrant: refundKnownNonGrant)
        }
        BlockingPauseMonitor.stop([DeviceActivityName(activityPrefix + id)])
        refreshLiveActivity()
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
        static var approved: Bool { IOSProtectionAuthorization.approved(AuthorizationCenter.shared.authorizationStatus) }
    }
}
