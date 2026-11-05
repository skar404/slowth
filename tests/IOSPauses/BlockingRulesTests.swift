// Frozen pre-refactor decisions, exhaustively compared to the pure rules.
@main enum BlockingRuleChecks {
    static func main() {
        for videos in [false, true] {
            for stories in [false, true] {
                let config = AppBlockingConfiguration.migrate(tokens: ["a", "b"],
                    rules: .init(shortVideos: videos, stories: stories),
                    exceptions: [.init(token: "a", allowShortVideos: true)], softTokens: ["b"])
                assert(!config.settings(for: "a").shortVideos)
                assert(config.settings(for: "a").stories == stories)
                assert(config.settings(for: "b").shortVideos == videos && config.settings(for: "b").soft)
                let new = config.settings(for: "new")
                assert(new.shortVideos && new.stories && !new.soft)
                var edited = config
                edited.set(.init(token: "a", shortVideos: false, stories: false, soft: true))
                assert(edited.settings(for: "b") == config.settings(for: "b"))
                assert(edited.settings(for: "a").weakens(.init(token: "a")))
            }
        }
        var session = GroupedSoftSession(generation: "new", events: ["one": "a", "two": "b"])
        assert(session.consume("one", generation: "old") == nil && session.events.count == 2)
        assert(session.consume("one", generation: "new") == "a" && session.events.count == 1)
        assert(session.consume("one", generation: "new") == nil)
        assert(session.consume("two", generation: "new") == "b" && session.events.isEmpty)
        assert(GroupedContentRules().shortVideos && GroupedContentRules().stories)
        for shortVideos in [false, true] {
            for stories in [false, true] {
                let rules = GroupedContentRules(shortVideos: shortVideos, stories: stories)
                assert(rules.hasEnabledContent == (shortVideos || stories))
                for source in 0..<6 {
                    for hits in [0, 2, 3, 5] {
                        var videoHits = [0, 0, 0, 0]
                        var storyHits = [0, 0]
                        if source < 4 { videoHits[source] = hits }
                        else { storyHits[source - 4] = hits }
                        let expected = hits >= 3 && (source < 4 ? shortVideos : stories)
                        assert(rules.detects(shortVideoHits: videoHits, storyHits: storyHits, requiredHits: 3) == expected)
                    }
                }
                // Cached evidence from a disabled family cannot trigger a rest.
                assert(rules.detects(shortVideoHits: [100], storyHits: [100], requiredHits: 3) == rules.hasEnabledContent)
                assert(!rules.detects(shortVideoHits: [], storyHits: [], requiredHits: 3))
            }
        }
        print("PASS: grouped content filters independently gate four video and two story sources, thresholds and stale evidence")
        var expiredRecorder = BlockingContext(recording: false, requestedShield: false, recorderRequest: true)
        assert(BlockingRules.decide(expiredRecorder, .shieldRequest).shield == .block)
        expiredRecorder.activePause = true
        assert(BlockingRules.decide(expiredRecorder, .shieldRequest).shield == .clear)
        expiredRecorder.activePause = false
        expiredRecorder.enabled = false
        assert(BlockingRules.decide(expiredRecorder, .shieldRequest).shield == .clear)
        expiredRecorder.enabled = true
        expiredRecorder.recorderRequest = false
        assert(BlockingRules.decide(expiredRecorder, .shieldRequest).shield == .clear)

        // Stopped Broadcast exception is scoped to YouTube and a live soft grant.
        for target in ["youtube", "instagram", "facebook", "x", "tiktok", "snapchat"] {
            for bits in 0..<(1 << 5) {
                func flag(_ bit: Int) -> Bool { bits & (1 << bit) != 0 }
                let c = BlockingContext(target: target, activePause: flag(0),
                    pendingRest: flag(1), soft: flag(2), deferred: flag(3),
                    requestedShield: flag(4), recorderRequest: true)
                let expectedBlock = !c.activePause && (c.pendingRest || c.requestedShield ||
                    target != "youtube" || !c.soft || !c.deferred)
                assert((BlockingRules.decide(c, .shieldRequest).shield == .block) == expectedBlock)
            }
        }

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
