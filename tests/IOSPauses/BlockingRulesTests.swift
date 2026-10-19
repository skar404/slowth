// Frozen pre-refactor decisions, exhaustively compared to the pure rules.
@main enum BlockingRuleChecks {
    static func main() {
        for bits in 0..<(1 << 12) {
            func flag(_ bit: Int) -> Bool { bits & (1 << bit) != 0 }
            let c = BlockingContext(enabled: flag(0), recording: flag(1),
                foreground: flag(2), pauseOnly: flag(3), activePause: flag(4),
                inferenceFailed: flag(5), pendingRest: flag(6), graceActive: flag(7),
                soft: flag(8), deferred: flag(9), validSelection: flag(10),
                currentGeneration: flag(11), requestedShield: flag(10),
                runtimeFresh: flag(11), runtimeWantsShield: flag(2))
            let request: Bool
            if !c.activePause && !c.pauseOnly && c.enabled &&
                ((c.recording && c.inferenceFailed) || c.pendingRest) {
                request = true
            } else if c.activePause || (!c.pauseOnly && c.enabled && c.recording && c.graceActive) {
                request = false
            } else { request = c.requestedShield }
            assert((BlockingRules.decide(c, .shieldRequest).shield == .block) == request)
            let restore: Bool
            if !c.enabled || !c.validSelection { restore = false }
            else if c.recording && c.inferenceFailed { restore = true }
            else if c.pendingRest || c.pauseOnly { restore = true }
            else if !c.recording && c.soft && c.deferred { restore = false }
            else { restore = !c.recording || !c.runtimeFresh || c.runtimeWantsShield }
            assert((BlockingRules.decide(c, .pauseEnded).shield == .block) == restore)
            let eligible = c.enabled && c.soft && c.deferred && !c.recording &&
                !c.foreground && c.validSelection && c.currentGeneration
            assert((BlockingRules.decide(c, .usageThreshold).shield == .block) == eligible)
            assert((BlockingRules.decide(c, .monitorEligibility).monitor == .start) == eligible)
        }
        assert(BlockingRules.softModeRejection(enabling: true, strict: true,
            initialActivation: false, youtubeEnabled: true) == .strict)
        assert(BlockingRules.softModeRejection(enabling: true, strict: true,
            initialActivation: true, youtubeEnabled: true) == nil)
        assert(BlockingRules.softModeRejection(enabling: true, strict: false,
            initialActivation: false, youtubeEnabled: false) == .youtubeDisabled)
        var c = BlockingContext(soft: true)
        assert(BlockingRules.decide(c, .hostOpened).deferred == true)
        c.deferred = true
        assert(BlockingRules.decide(c, .hostClosed).monitor == .start)
        c.foreground = true
        c.currentGeneration = false
        assert(BlockingRules.decide(c, .usageThreshold).shield == .keep)
        c.foreground = false
        c.currentGeneration = true
        c.recording = true
        assert(BlockingRules.decide(c, .usageThreshold).shield == .keep)
        c.recording = false
        c.soft = false
        assert(BlockingRules.decide(c, .hostClosed).monitor == .stop)
        assert(BlockingRules.decide(c, .hostOpened).deferred == false)
        assert(BlockingRules.decide(c, .monitorFailed).shield == .block)
        c.soft = true
        let first = BlockingRules.decide(c, .usageThreshold)
        c.deferred = first.deferred!
        assert(BlockingRules.decide(c, .usageThreshold).shield == .keep)
        c.activePause = true
        c.inferenceFailed = true
        c.recording = true
        assert(BlockingRules.decide(c, .shieldRequest).shield == .clear)
        c.activePause = false
        assert(BlockingRules.decide(c, .shieldRequest).shield == .block)
        print("PASS: 4096 policy combinations and soft-mode transition sequences")
    }
}
