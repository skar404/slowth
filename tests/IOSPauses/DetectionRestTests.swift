import Foundation

@main enum DetectionRestChecks {
    static func main() throws {
        func clock(_ seconds: Double, wall: Double = 100, boot: String = "A") -> IOSPauseClock {
            .init(wall: wall, continuous: seconds, boot: boot)
        }
        // Real-device regression: host is approved but extension reports no local grant.
        assert(IOSRestAuthorization.allows(inExtension: true, localApproved: false, sharedApproved: true))
        assert(!IOSRestAuthorization.allows(inExtension: true, localApproved: false, sharedApproved: false))
        assert(!IOSRestAuthorization.allows(inExtension: false, localApproved: false, sharedApproved: true))
        assert(IOSRestAuthorization.allows(inExtension: false, localApproved: true, sharedApproved: true))
        let duration = IOSDetectionRest.duration
        assert(duration == 60)
        // Reproduce denied kern.bootsessionuuid, as on sandboxed iOS devices.
        let fallback = IOSPauseClock.restBootIdentity(session: nil, bootTime: "100:0")
        assert(fallback == IOSPauseClock.restBootIdentity(session: nil, bootTime: "100:0"))
        // Host and extension permissions differ, but must use the same clock identity.
        let hostBoot = IOSPauseClock.restBootIdentity(session: "host-visible-uuid", bootTime: "100:0")
        assert(hostBoot == fallback)
        var crossProcessRest = IOSDetectionRest(target: "youtube")
        crossProcessRest.startIfNeeded(clock(1000, boot: hostBoot))
        crossProcessRest.finishIfElapsed(clock(1000 + duration, boot: fallback))
        assert(crossProcessRest.completed == true)
        try crossProcessRest.release(id: crossProcessRest.id, now: clock(1000 + duration, boot: fallback), revision: 0)
        assert(crossProcessRest.graceRemaining(clock(1000 + duration + 1, boot: hostBoot)) == 4)
        assert(fallback != IOSPauseClock.restBootIdentity(session: nil, bootTime: "200:0"))
        var fallbackRest = IOSDetectionRest(target: "youtube")
        fallbackRest.startIfNeeded(clock(1000, boot: fallback))
        assert(fallbackRest.remaining(clock(1001, boot: IOSPauseClock.restBootIdentity(session: nil, bootTime: "100:0"))) == duration - 1)
        assert(fallbackRest.remaining(clock(1000 + duration, boot: fallback)) == 0)
        var rest = IOSDetectionRest(target: "youtube")
        assert(rest.remaining(clock(10000)) == duration) // Legacy record awaits Shield application or host open.
        rest.startIfNeeded(clock(10000))
        rest.startIfNeeded(clock(10000 + duration / 2))
        assert(rest.remaining(clock(10000 + duration - 0.1)) > 0)
        assert(rest.remaining(clock(10000 + duration)) == 0)
        assert(rest.remaining(clock(10000 + duration / 2, wall: 999999)) == duration / 2)
        assert(rest.remaining(clock(10000 + duration / 2, wall: -999999)) == duration / 2)
        rest = try JSONDecoder().decode(IOSDetectionRest.self, from: JSONEncoder().encode(rest))
        assert(rest.remaining(clock(10000 + duration)) == 0) // Process restart / suspension.
        rest.startIfNeeded(clock(1, boot: "B"))
        assert(rest.remaining(clock(1, boot: "B")) == duration)
        do { try rest.release(id: rest.id, now: clock(duration + 0, boot: "B"), revision: 0); fatalError("Early release") } catch {}
        do { try rest.release(id: "old-cycle", now: clock(duration + 1, boot: "B"), revision: 0); fatalError("Stale release") } catch {}
        try rest.release(id: rest.id, now: clock(duration + 1, boot: "B"), revision: 0)
        do { try rest.release(id: rest.id, now: clock(duration + 2, boot: "B"), revision: 0); fatalError("Duplicate release") } catch {}
        rest.startIfNeeded(clock(duration + 3, boot: "B"))
        assert(rest.graceRemaining(clock(duration + 3, wall: 999999, boot: "B")) == 3)
        assert(rest.graceRemaining(clock(duration + 6, boot: "B")) == 0)
        assert(rest.graceRemaining(clock(1, boot: "C")) == 0)
        var startup = IOSDetectionRest.recordingGrace(target: "instagram", selection: nil,
            now: clock(2000), revision: 0)
        assert(startup.completed == true)
        assert(startup.graceRemaining(clock(2000)) == 5)
        assert(startup.graceRemaining(clock(2004.9)) > 0)
        startup = try JSONDecoder().decode(IOSDetectionRest.self, from: JSONEncoder().encode(startup))
        startup.startIfNeeded(clock(2001))
        assert(startup.graceRemaining(clock(2002, wall: 999999)) == 3)
        assert(startup.graceRemaining(clock(2005)) == 0)
        assert(startup.graceRemaining(clock(2006)) == 0)
        var routing = IOSPauseLedger()
        routing.detectionRests = ["instagram": startup]
        routing.requestDetectionRest(target: "instagram", selection: nil, now: clock(2020), fromShieldAction: true)
        assert(routing.detectionRests?["instagram"]?.id == startup.id)
        assert(routing.detectionRests?["instagram"]?.released?.continuous == 2000)
        assert(routing.detectionRests?["instagram"]?.graceRemaining(clock(2020)) == 0)
        // Only a fresh detector event may create the next cycle after grace.
        routing.requestDetectionRest(target: "instagram", selection: nil, now: clock(2021), fromShieldAction: false)
        let nextID = routing.detectionRests?["instagram"]?.id
        assert(nextID != startup.id)
        routing.detectionRests?["instagram"]?.startIfNeeded(clock(2022))
        routing.requestDetectionRest(target: "instagram", selection: nil, now: clock(2023), fromShieldAction: true)
        assert(routing.detectionRests?["instagram"]?.id == nextID)
        assert(routing.detectionRests?["instagram"]?.started?.continuous == 2022)
        var presentation = IOSRestPresentation()
        let pending = routing.detectionRests!["instagram"]!
        assert(presentation.shouldPresent(pending))
        presentation.acknowledge(pending)
        assert(!presentation.shouldPresent(pending)) // Dismissal / normal foreground refresh.
        routing.requestDetectionRest(target: "instagram", selection: nil, now: clock(2024), fromShieldAction: true)
        let requestedAgain = routing.detectionRests!["instagram"]!
        assert(presentation.shouldPresent(requestedAgain)) // Explicit Continue reopens same cycle.
        assert(requestedAgain.id == pending.id)
        assert(requestedAgain.remaining(clock(2025)) == pending.remaining(clock(2025)))
        presentation.acknowledge(requestedAgain) // Also acknowledge requests while already visible.
        assert(!presentation.shouldPresent(requestedAgain))
        assert(presentation.shouldPresent(IOSDetectionRest(target: "youtube")))
        var unsolicited = IOSDetectionRest(target: "youtube")
        assert(presentation.shouldPresent(unsolicited))
        presentation.acknowledge(unsolicited)
        assert(!presentation.shouldPresent(unsolicited)) // A nil request must still be remembered.
        unsolicited.requestedOrder = 2026
        assert(presentation.shouldPresent(unsolicited))
        var automatic = IOSDetectionRest(target: "instagram")
        automatic.finishIfElapsed(clock(10000))
        assert(automatic.completed != true) // No host open: no automatic completion.
        automatic.startIfNeeded(clock(10000))
        automatic.finishIfElapsed(clock(10000 + duration - 0.1))
        assert(automatic.completed != true)
        automatic.finishIfElapsed(clock(10000 + duration))
        assert(automatic.completed == true && automatic.released == nil) // Recording off: hide, no grant.
        automatic.startIfNeeded(clock(1, boot: "B"))
        assert(automatic.completed == true) // Completed rests never start again.
        try automatic.release(id: automatic.id, now: clock(10, boot: "B"), revision: 0)
        assert(automatic.graceRemaining(clock(13, boot: "B")) == 2)
        do { try automatic.release(id: automatic.id, now: clock(14, boot: "B"), revision: 0); fatalError("Extended automatic grant") } catch {}
        assert(automatic.graceRemaining(clock(15, boot: "B")) == 0)
        let url = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: url) }
        let db = IOSPauseDatabase(url: url)
        try db.transaction { ledger in
            ledger.detectionRests = ["youtube": rest, "instagram": IOSDetectionRest(target: "instagram")]
        }
        let saved = try IOSPauseDatabase(url: url).transaction { $0 }
        assert(saved.detectionRests?["youtube"]?.id == rest.id)
        assert(saved.detectionRests?["instagram"]?.started == nil)
        assert(saved.lease == nil && saved.spent.isEmpty && saved.savedLeaves == 0)
        print("Detection rest clock, persistence, independence and quota checks passed")
    }
}
