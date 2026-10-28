import Foundation

@main enum LedgerChecks {
    static func main() throws {
        let now = IOSPauseClock(wall: 1_792_022_400, continuous: 1000, boot: "A")
        func after(_ seconds: Double) -> IOSPauseClock {
            .init(wall: now.wall + seconds, continuous: now.continuous + seconds, boot: now.boot)
        }
        func prepare(_ state: inout IOSPauseLedger, id: String, at time: IOSPauseClock = now) throws {
            try state.prepare(id: id, kind: "safari", target: "youtube", selection: nil,
                              now: time, currentZone: "UTC", strict: false)
        }
        func expectError(_ block: () throws -> Void) {
            do { try block(); fatalError("Expected rejection") } catch { }
        }
        func check(_ condition: @autoclosure () throws -> Bool) throws {
            let result = try condition()
            assert(result)
        }
        var state = IOSPauseLedger()
        try prepare(&state, id: "a")
        try check(state.remaining(now, currentZone: "UTC") == 3) // Preparation isn't spent.
        expectError { try prepare(&state, id: "b") }
        try state.activate("a", now: now, strict: false)
        expectError { try state.activate("a", now: now, strict: false) }
        try check(state.remaining(now, currentZone: "UTC") == 2)
        assert(state.lease!.expiresAt - state.lease!.started.wall == 60)
        assert(!state.lease!.expired(after(59.9)))
        assert(state.lease!.expired(after(60)))
        assert(state.lease!.expired(.init(wall: now.wall + 10, continuous: 10, boot: "B")))
        assert(state.lease!.expired(.init(wall: now.wall + 3600, continuous: 1001, boot: "A")))
        state.finish(now: after(20))
        try check(state.remaining(now, currentZone: "UTC") == 2)
        for id in ["b", "c"] {
            try prepare(&state, id: id)
            try state.activate(id, now: now, strict: false)
            state.finish(now: now)
        }
        expectError { try prepare(&state, id: "d") }
        try check(state.remaining(after(86400), currentZone: "Pacific/Honolulu") == 3)
        try prepare(&state, id: "next", at: after(86400))
        try state.activate("next", now: after(86400), strict: false)
        state.finish(now: after(86400))
        expectError { try prepare(&state, id: "clock-back") }
        var failed = IOSPauseLedger()
        try prepare(&failed, id: "failed")
        expectError { try failed.activate("failed", now: after(20), strict: false) }
        failed.finish(now: after(20))
        try check(failed.remaining(now, currentZone: "UTC") == 3)
        try prepare(&failed, id: "strict")
        expectError { try failed.activate("strict", now: now, strict: true) }
        failed.finish(now: now)
        try prepare(&failed, id: "compensated")
        try failed.activate("compensated", now: now, strict: false)
        failed.finish(now: now, refundKnownNonGrant: true)
        failed.finish(now: now, refundKnownNonGrant: true)
        try check(failed.remaining(now, currentZone: "UTC") == 3)

        // Strict-mode opt-in permits the normal quota-bound lifecycle; opting
        // out blocks both preparation and activation, including mid-preparation.
        for strict in [false, true] {
            for allowed in [false, true] {
                let blocked = IOSPauseStrictPolicy.blocksPause(strictModeActive: strict, allowsPauses: allowed)
                var candidate = IOSPauseLedger()
                if strict && !allowed {
                    expectError {
                        try candidate.prepare(id: "policy", kind: "application", target: "youtube", selection: nil,
                                              now: now, currentZone: "UTC", strict: blocked)
                    }
                    assert(candidate.lease == nil)
                } else {
                    try candidate.prepare(id: "policy", kind: "application", target: "youtube", selection: nil,
                                          now: now, currentZone: "UTC", strict: blocked)
                    let prepared = candidate
                    try candidate.activate("policy", now: now, strict: blocked)
                    try check(candidate.remaining(now, currentZone: "UTC") == 2)
                    var revoked = prepared
                    expectError {
                        try revoked.activate("policy", now: now,
                            strict: IOSPauseStrictPolicy.blocksPause(strictModeActive: true, allowsPauses: false))
                    }
                }
            }
        }

        // Debug reset must not silently end or extend an active lease.
        var reset = state
        try reset.resetQuotaForDebug(now: after(86400))
        try check(reset.remaining(after(86400), currentZone: "UTC") == 3)
        assert(reset.zone == state.zone && reset.lastID == state.lastID)
        try prepare(&reset, id: "reset-active", at: after(86400))
        expectError { try reset.resetQuotaForDebug(now: after(86400)) }
        assert(reset.lease?.id == "reset-active")

        // New recording-independent leases survive persistence; older records remain readable.
        var offline = IOSPauseLedger()
        try offline.prepare(id: "offline", kind: "application", target: "youtube", selection: nil,
            now: now, currentZone: "UTC", strict: false, requiresRecording: false)
        let encoded = try JSONEncoder().encode(offline)
        let restored = try JSONDecoder().decode(IOSPauseLedger.self, from: encoded)
        assert(restored.lease?.requiresRecording == false)
        var legacy = try JSONSerialization.jsonObject(with: encoded) as! [String: Any]
        var legacyLease = legacy["lease"] as! [String: Any]
        legacyLease.removeValue(forKey: "requiresRecording")
        legacy["lease"] = legacyLease
        let legacyRestored = try JSONDecoder().decode(IOSPauseLedger.self,
            from: JSONSerialization.data(withJSONObject: legacy))
        assert(legacyRestored.lease?.requiresRecording == nil)

        // Switching keeps one charged lease, its exact deadline and reward history.
        var switching = IOSPauseLedger()
        let tokenA = Data([1]), tokenB = Data([2])
        try switching.setPauseSeconds(180, strict: false)
        try switching.prepare(id: "switch", kind: "application", target: "youtube", selection: tokenA,
            now: now, currentZone: "UTC", strict: false, requiresRecording: false)
        expectError {
            try switching.switchApplication(id: "switch", from: "youtube", to: "instagram",
                selection: tokenB, now: now, strict: false)
        }
        try switching.activate("switch", now: now, strict: false)
        let originalSwitch = switching
        try switching.switchApplication(id: "switch", from: "youtube", to: "instagram",
            selection: tokenB, now: after(30), strict: false)
        assert(switching.lease!.target == "instagram" && switching.lease!.selection == tokenB)
        assert(switching.lease!.expiresAt == originalSwitch.lease!.expiresAt)
        assert(switching.lease!.started.wall == originalSwitch.lease!.started.wall)
        assert(switching.lease!.requiresRecording == false && switching.lease!.charged)
        assert(switching.spent == originalSwitch.spent && switching.savedLeaves == originalSwitch.savedLeaves)
        assert(switching.revision == originalSwitch.revision + 1 && switching.changedAt == after(30).wall)
        for (id, source, strict, at) in [
            ("old-id", "instagram", false, after(31)),
            ("switch", "youtube", false, after(31)),
            ("switch", "instagram", true, after(31)),
            ("switch", "instagram", false, after(300))
        ] {
            expectError {
                try switching.switchApplication(id: id, from: source, to: "facebook",
                    selection: tokenA, now: at, strict: strict)
            }
        }
        let switchData = try JSONEncoder().encode(switching)
        switching = try JSONDecoder().decode(IOSPauseLedger.self, from: switchData)
        try switching.switchApplication(id: "switch", from: "instagram", to: "youtube",
            selection: tokenA, now: after(40), strict: false)
        assert(switching.lease!.expiresAt == originalSwitch.lease!.expiresAt && switching.spent == originalSwitch.spent)
        var safariSwitch = originalSwitch
        safariSwitch.lease!.kind = "safari"
        expectError {
            try safariSwitch.switchApplication(id: "switch", from: "youtube", to: "instagram",
                selection: tokenB, now: after(31), strict: false)
        }
        // No quota gate: switching the last daily pause must remain possible.
        switching.spent[switching.lease!.day] = 3
        try switching.switchApplication(id: "switch", from: "youtube", to: "instagram",
            selection: tokenB, now: after(50), strict: false)
        try check(switching.remaining(after(50), currentZone: "UTC") == 0)

        // Pause-only apps use the same quota/deadline without requiring a recorder.
        // Switching to the other service must not create a second grant or charge.
        for (source, destination) in [("tiktok", "snapchat"), ("snapchat", "tiktok")] {
            var pauseOnly = IOSPauseLedger()
            try pauseOnly.prepare(id: source, kind: "application", target: source, selection: tokenA,
                now: now, currentZone: "UTC", strict: false, requiresRecording: false)
            try pauseOnly.activate(source, now: now, strict: false)
            let deadline = pauseOnly.lease!.expiresAt
            try pauseOnly.switchApplication(id: source, from: source, to: destination,
                selection: tokenB, now: after(15), strict: false)
            assert(pauseOnly.lease!.target == destination && pauseOnly.lease!.selection == tokenB)
            assert(pauseOnly.lease!.requiresRecording == false && pauseOnly.lease!.expiresAt == deadline)
            try check(pauseOnly.remaining(after(15), currentZone: "UTC") == 2)
            expectError {
                try pauseOnly.switchApplication(id: source, from: destination, to: source,
                    selection: tokenA, now: after(16), strict: true)
            }
            assert(pauseOnly.lease!.expired(after(180)))
            pauseOnly.finish(now: after(180))
            assert(pauseOnly.lease == nil)
            try check(pauseOnly.remaining(after(180), currentZone: "UTC") == 2)
        }

        // Duration defaults/migration and persisted per-lease deadlines.
        var durationChoice = IOSPauseLedger()
        assert(durationChoice.pauseSeconds == 60)
        assert(IOSPauseLedger.pauseSecondOptions == [30, 60, 180])
        for seconds in IOSPauseLedger.pauseSecondOptions {
            try durationChoice.setPauseSeconds(seconds, strict: false)
            try prepare(&durationChoice, id: "duration-\(seconds)")
            try durationChoice.activate("duration-\(seconds)", now: now, strict: false)
            let duration = Double(seconds)
            let deadline = durationChoice.lease!.expiresAt
            assert(deadline == now.wall + duration)
            assert(!durationChoice.lease!.expired(after(duration - 0.1)))
            assert(durationChoice.lease!.expired(after(duration)))
            try durationChoice.setPauseSeconds(seconds == 30 ? 60 : 30, strict: false)
            assert(durationChoice.lease!.expiresAt == deadline)
            let persisted = try JSONDecoder().decode(IOSPauseLedger.self,
                from: JSONEncoder().encode(durationChoice))
            assert(persisted.lease!.expiresAt == deadline)
            assert(persisted.pauseSeconds == durationChoice.pauseSeconds)
            durationChoice.finish(now: after(duration))
        }
        expectError { try durationChoice.setPauseSeconds(300, strict: false) }
        expectError { try durationChoice.setPauseSeconds(10, strict: false) }
        for seconds in IOSPauseLedger.pauseSecondOptions {
            expectError { try durationChoice.setPauseSeconds(seconds, strict: true) }
        }
        var oldDurationRecord = try JSONSerialization.jsonObject(with: encoded) as! [String: Any]
        oldDurationRecord.removeValue(forKey: "selectedPauseMinutes")
        oldDurationRecord.removeValue(forKey: "selectedPauseSeconds")
        var oldLease = oldDurationRecord["lease"] as! [String: Any]
        oldLease.removeValue(forKey: "durationSeconds")
        oldDurationRecord["lease"] = oldLease
        let oldDuration = try JSONDecoder().decode(IOSPauseLedger.self,
            from: JSONSerialization.data(withJSONObject: oldDurationRecord))
        assert(oldDuration.pauseSeconds == 60 && oldDuration.lease!.effectiveDuration == 180)
        for (legacyMinutes, expected) in [(1, 60), (3, 180), (5, 60)] {
            oldDurationRecord["selectedPauseMinutes"] = legacyMinutes
            oldLease["durationSeconds"] = 300
            oldDurationRecord["lease"] = oldLease
            let migrated = try JSONDecoder().decode(IOSPauseLedger.self,
                from: JSONSerialization.data(withJSONObject: oldDurationRecord))
            assert(migrated.pauseSeconds == expected && migrated.lease!.effectiveDuration == 300)
        }

        // Rewards settle completed calendar days once, including days away.
        var rewards = IOSPauseLedger()
        try rewards.accrueLeaves(now, currentZone: "UTC")
        assert(rewards.savedLeaves == 0)
        try prepare(&rewards, id: "reward-pause")
        try rewards.activate("reward-pause", now: now, strict: false)
        rewards.finish(now: after(180))
        try rewards.accrueLeaves(after(86400), currentZone: "Pacific/Honolulu")
        assert(rewards.savedLeaves == 2)
        try rewards.accrueLeaves(after(86400), currentZone: "UTC")
        try rewards.accrueLeaves(now, currentZone: "UTC")
        assert(rewards.savedLeaves == 2)
        try rewards.accrueLeaves(after(86400 * 11), currentZone: "UTC")
        assert(rewards.savedLeaves == 32)
        try check(rewards.remaining(after(86400 * 11), currentZone: "UTC") == 3)
        let rewardData = try JSONEncoder().encode(rewards)
        var rewardReloaded = try JSONDecoder().decode(IOSPauseLedger.self, from: rewardData)
        try rewardReloaded.accrueLeaves(after(86400 * 11), currentZone: "UTC")
        assert(rewardReloaded.savedLeaves == 32)
        var oldRecord = try JSONSerialization.jsonObject(with: rewardData) as! [String: Any]
        oldRecord.removeValue(forKey: "leafRewards")
        var migrated = try JSONDecoder().decode(IOSPauseLedger.self,
            from: JSONSerialization.data(withJSONObject: oldRecord))
        try migrated.accrueLeaves(after(86400 * 11), currentZone: "UTC")
        assert(migrated.savedLeaves == 0) // No invented historical rewards.

        // Midnight preparation/activation/refund is settled only after finish.
        let dayKey = try rewards.day(now, zone: "UTC")
        let midnight = ISO8601DateFormatter().date(from: dayKey + "T00:00:00Z")!.timeIntervalSince1970
        let edge = IOSPauseClock(wall: midnight + 86395, continuous: 2000, boot: "A")
        let next = IOSPauseClock(wall: edge.wall + 10, continuous: 2010, boot: "A")
        var crossing = IOSPauseLedger()
        try prepare(&crossing, id: "midnight", at: edge)
        try crossing.accrueLeaves(next, currentZone: "UTC")
        assert(crossing.savedLeaves == 0)
        try crossing.activate("midnight", now: next, strict: false)
        crossing.finish(now: next, refundKnownNonGrant: true)
        assert(crossing.savedLeaves == 3)
        try crossing.accrueLeaves(next, currentZone: "UTC")
        assert(crossing.savedLeaves == 3)

        let dir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        // Debug edits persist without changing the active lease or daily quota.
        let editURL = dir.appendingPathComponent("edited-rewards.sqlite")
        var edited = IOSPauseLedger()
        try prepare(&edited, id: "edited-reward")
        try edited.activate("edited-reward", now: now, strict: false)
        let stableEncoder = JSONEncoder()
        stableEncoder.outputFormatting = .sortedKeys
        let originalLease = try stableEncoder.encode(edited.lease)
        let originalSpent = edited.spent
        for count in [3, 2, 1, 0, 1_000_000, 12] {
            try edited.setSavedLeavesForDebug(count, now: now, currentZone: "UTC")
            assert(edited.savedLeaves == count && edited.spent == originalSpent)
            try check(stableEncoder.encode(edited.lease) == originalLease)
            try IOSPauseDatabase(url: editURL).transaction { $0 = edited }
            try check(IOSPauseDatabase(url: editURL).transaction { $0.savedLeaves == count })
        }
        expectError { try edited.setSavedLeavesForDebug(-1, now: now, currentZone: "UTC") }
        expectError { try edited.setSavedLeavesForDebug(Int.max, now: now, currentZone: "UTC") }
        assert(edited.savedLeaves == 12)
        edited.finish(now: after(180))
        try edited.accrueLeaves(after(86400), currentZone: "UTC")
        assert(edited.savedLeaves == 14)
        try edited.setSavedLeavesForDebug(7, now: after(86400 * 2), currentZone: "UTC")
        try edited.accrueLeaves(after(86400 * 2), currentZone: "UTC")
        assert(edited.savedLeaves == 7) // Prior rewards were settled before replacement.
        try edited.accrueLeaves(after(86400 * 3), currentZone: "UTC")
        assert(edited.savedLeaves == 10)
        print("PASS: debug reward editing, bounds, persistence, unchanged active pause and later accrual")

        let url = dir.appendingPathComponent("state.sqlite")
        _ = try IOSPauseDatabase(url: url).transaction { $0 }
        DispatchQueue.concurrentPerform(iterations: 20) { n in
            _ = try? IOSPauseDatabase(url: url).transaction {
                try $0.prepare(id: "\(n)", kind: n % 2 == 0 ? "application" : "safari", target: "youtube", selection: nil,
                    now: now, currentZone: "UTC", strict: false)
                try $0.activate("\(n)", now: now, strict: false)
            }
        }
        let reopened = try IOSPauseDatabase(url: url).transaction { $0 }
        assert(reopened.lease != nil && reopened.spent.values.reduce(0, +) == 1)
        expectError {
            try IOSPauseDatabase(url: url).transaction { ledger in
                ledger.finish(now: now)
                throw IOSPauseError.storage
            }
        }
        try check(IOSPauseDatabase(url: url).transaction { $0.lease != nil })
        let switchURL = dir.appendingPathComponent("switch.sqlite")
        try IOSPauseDatabase(url: switchURL).transaction { $0 = originalSwitch }
        let switchTime = after(30)
        DispatchQueue.concurrentPerform(iterations: 20) { n in
            try? IOSPauseDatabase(url: switchURL).transaction {
                try $0.switchApplication(id: "switch", from: "youtube", to: n % 2 == 0 ? "instagram" : "facebook",
                    selection: tokenB, now: switchTime, strict: false)
            }
        }
        let concurrentSwitch = try IOSPauseDatabase(url: switchURL).transaction { $0 }
        assert(concurrentSwitch.revision == originalSwitch.revision + 1)
        assert(concurrentSwitch.spent == originalSwitch.spent)
        assert(concurrentSwitch.lease!.expiresAt == originalSwitch.lease!.expiresAt)
        print("PASS: app switching, unchanged deadline/quota, stale selection, strict mode, persistence and concurrent switch requests")

        let rewardURL = dir.appendingPathComponent("rewards.sqlite")
        try IOSPauseDatabase(url: rewardURL).transaction {
            try $0.accrueLeaves(now, currentZone: "UTC")
        }
        let fiveDaysLater = after(86400 * 5)
        DispatchQueue.concurrentPerform(iterations: 20) { _ in
            try! IOSPauseDatabase(url: rewardURL).transaction {
                try $0.accrueLeaves(fiveDaysLater, currentZone: "UTC")
            }
        }
        try check(IOSPauseDatabase(url: rewardURL).transaction { $0.savedLeaves == 15 })

        // DST changes are calendar days, not fixed 24-hour periods.
        var dst = IOSPauseLedger()
        let iso = ISO8601DateFormatter()
        let beforeDST = IOSPauseClock(wall: iso.date(from: "2026-03-08T05:00:00Z")!.timeIntervalSince1970,
                                      continuous: 0, boot: "A")
        let afterDST = IOSPauseClock(wall: iso.date(from: "2026-03-09T04:00:00Z")!.timeIntervalSince1970,
                                     continuous: 82800, boot: "A")
        try dst.accrueLeaves(beforeDST, currentZone: "America/New_York")
        try dst.accrueLeaves(afterDST, currentZone: "America/New_York")
        assert(dst.savedLeaves == 3)
        print("PASS: leaf rewards, migration, midnight refund, DST, persistence and concurrent accrual")
        print("PASS: quota, idempotency, reservation, strict gate, real-time expiry, reboot, clock changes, compensation, persistence, concurrent writers and rollback")
    }
}
