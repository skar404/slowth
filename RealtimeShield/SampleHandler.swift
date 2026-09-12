import Foundation
import ReplayKit
#if canImport(FamilyControls)
import FamilyControls
#endif

// The hierarchical SurfaceDetector is the sole runtime classifier. It first
// predicts the app, then app-specific content. Blocking scores are joint
// probabilities: P(app) × P(content | app).
final class SampleHandler: RPBroadcastSampleHandler {
    private var classifier: SurfaceClassifier?
    private var metadata: SurfaceModelMetadata?
    private var lastInferenceTimestamp: CMTime?
    private var receivedVideoFrames = 0
    private var inferenceCount = 0
    private var lastPrediction: SurfacePrediction?
    private var lastInferenceDurationMS: Double?
    private var inferenceDurationsMS: [Double] = []
    private var peakFootprintMB: Double = 0
    private var classifierStatus = "not started"
    private var classifierError: String?
    private var lastDiagnosticsWrite = Date.distantPast
    private var lastTelemetryLog = Date.distantPast
    private var youtubeShieldLatched = false
    private var instagramShieldLatched = false
    private var youtubeGraceUntil: Date?
    private var instagramGraceUntil: Date?
    private var lastHandledYouTubeUnlockAt: Date?
    private var lastHandledInstagramUnlockAt: Date?
    private var youtubeShortsStreak = 0
    private var instagramReelsStreak = 0
    private var instagramStoriesStreak = 0
    private var youtubeShortsVotes: [Bool] = []
    private var instagramReelsVotes: [Bool] = []
    private var instagramStoriesVotes: [Bool] = []
    private var youtubeShortsEvidence: [DebugCaptureFramePixels] = []
    private var instagramReelsEvidence: [DebugCaptureFramePixels] = []
    private var instagramStoriesEvidence: [DebugCaptureFramePixels] = []
    private var youtubeCandidateEvents = 0
    private var instagramCandidateEvents = 0
    private var instagramStoriesCandidateEvents = 0
    private var broadcastSessionID = UUID()

    private static let unlockGraceSeconds: TimeInterval = 2

    override func broadcastStarted(withSetupInfo setupInfo: [String: NSObject]?) {
        RTLog.sampleHandler.notice("broadcastStarted — loading hierarchical SurfaceDetector")
        SoftYouTubeActivityMonitoring.stop()
        SharedStore.setBroadcastActive(true)
        resetSessionState()
        let sharedState = SharedStore.snapshot()
        if sharedState.realtimeShieldEnabled {
            loadClassifier()
        } else {
            classifierStatus = "disabled"
        }
        publishDiagnostics(force: true)
        prepareEnabledSurfacesForActiveBroadcast(sharedState)
    }

    override func broadcastPaused() {
        RTLog.sampleHandler.notice("broadcastPaused — applying at-rest shield policy")
        SharedStore.setBroadcastActive(false)
        resetStreaks()
        prepareEnabledSurfacesAfterBroadcastStops()
        publishDiagnostics(force: true)
        reshieldEnabledSurfaces()
    }

    override func broadcastResumed() {
        RTLog.sampleHandler.notice("broadcastResumed — restoring SurfaceDetector state")
        SoftYouTubeActivityMonitoring.stop()
        SharedStore.setBroadcastActive(true)
        resetStreaks()
        resetLatchesForActiveBroadcast()
        lastInferenceTimestamp = nil
        let sharedState = SharedStore.snapshot()
        if sharedState.realtimeShieldEnabled && classifier == nil {
            loadClassifier()
        }
        publishDiagnostics(force: true)
        prepareEnabledSurfacesForActiveBroadcast(sharedState)
    }

    override func broadcastFinished() {
        RTLog.sampleHandler.notice("broadcastFinished — applying at-rest shield policy")
        SharedStore.setBroadcastActive(false)
        resetStreaks()
        prepareEnabledSurfacesAfterBroadcastStops()
        publishDiagnostics(force: true)
        reshieldEnabledSurfaces()
    }

    override func processSampleBuffer(
        _ sampleBuffer: CMSampleBuffer,
        with sampleBufferType: RPSampleBufferType
    ) {
        guard sampleBufferType == .video else { return }
        let sharedState = SharedStore.snapshot()
        guard sharedState.realtimeShieldEnabled else { return }

        if classifier == nil && classifierStatus == "disabled" {
            loadClassifier()
        }
        receivedVideoFrames += 1
        let now = Date()
        consumeUnlockRequests(at: now)

        guard let classifier else {
            failCloseEnabledSurfaces(sharedState)
            publishDiagnostics(force: false)
            return
        }

        let timestamp = CMSampleBufferGetPresentationTimeStamp(sampleBuffer)
        let interval = metadata?.inferenceIntervalSeconds ?? 0.25
        if let previous = lastInferenceTimestamp,
           timestamp.isValid,
           previous.isValid,
           CMTimeGetSeconds(CMTimeSubtract(timestamp, previous)) < interval {
            publishDiagnostics(force: false)
            return
        }
        lastInferenceTimestamp = timestamp

        guard let pixelBuffer = CMSampleBufferGetImageBuffer(sampleBuffer) else {
            failInference("sample has no pixel buffer", sharedState: sharedState)
            return
        }

        let startedAt = CFAbsoluteTimeGetCurrent()
        do {
            let prediction = try classifier.predict(pixelBuffer: pixelBuffer)
            guard let youtubeThreshold = classifier.metadata.threshold(for: .youtubeShorts),
                  let instagramReelsThreshold = classifier.metadata.threshold(for: .instagramReels),
                  let instagramStoriesThreshold = classifier.metadata.threshold(
                      for: .instagramStories
                  ) else {
                throw SurfaceClassifierError.invalidMetadata
            }
            let durationMS = (CFAbsoluteTimeGetCurrent() - startedAt) * 1_000
            recordInference(prediction, durationMS: durationMS)

            let youtubeVerdict = prediction.probability(for: .youtubeShorts) >= youtubeThreshold
            let instagramReelsVerdict = sharedState.realtimeInstagramReelsBlockingEnabled
                && prediction.probability(for: .instagramReels) >= instagramReelsThreshold
            let instagramStoriesVerdict = sharedState.realtimeInstagramStoriesBlockingEnabled
                && prediction.probability(for: .instagramStories) >= instagramStoriesThreshold
            recordDebugEvidence(
                classifier: classifier,
                prediction: prediction,
                youtubeVerdict: youtubeVerdict,
                instagramReelsVerdict: instagramReelsVerdict,
                instagramStoriesVerdict: instagramStoriesVerdict,
                observationWindowFrames: classifier.metadata.effectiveObservationWindowFrames,
                capturedAt: now
            )
            updateCandidateStreaks(
                youtubeVerdict: youtubeVerdict,
                instagramReelsVerdict: instagramReelsVerdict,
                instagramStoriesVerdict: instagramStoriesVerdict,
                requiredHits: classifier.metadata.requiredConsecutiveHits,
                observationWindowFrames: classifier.metadata.effectiveObservationWindowFrames
            )
            enforceYouTube(
                verdict: youtubeVerdict,
                requiredHits: classifier.metadata.requiredConsecutiveHits,
                sharedState: sharedState,
                now: now
            )
            enforceInstagram(
                reelsVerdict: instagramReelsVerdict,
                storiesVerdict: instagramStoriesVerdict,
                requiredHits: classifier.metadata.requiredConsecutiveHits,
                sharedState: sharedState,
                now: now
            )
            classifierStatus = "ready"
            classifierError = nil
        } catch {
            self.classifier = nil
            metadata = nil
            failInference(error.localizedDescription, sharedState: sharedState)
        }
        publishDiagnostics(force: classifierStatus == "failed")
    }

    private func resetSessionState() {
        broadcastSessionID = UUID()
        resetStreaks()
        resetLatchesForActiveBroadcast()
        receivedVideoFrames = 0
        inferenceCount = 0
        lastPrediction = nil
        lastInferenceDurationMS = nil
        inferenceDurationsMS.removeAll(keepingCapacity: true)
        peakFootprintMB = 0
        lastInferenceTimestamp = nil
        youtubeCandidateEvents = 0
        instagramCandidateEvents = 0
        instagramStoriesCandidateEvents = 0
    }

    private func resetStreaks() {
        youtubeShortsStreak = 0
        instagramReelsStreak = 0
        instagramStoriesStreak = 0
        youtubeShortsVotes.removeAll(keepingCapacity: true)
        instagramReelsVotes.removeAll(keepingCapacity: true)
        instagramStoriesVotes.removeAll(keepingCapacity: true)
        youtubeShortsEvidence.removeAll(keepingCapacity: true)
        instagramReelsEvidence.removeAll(keepingCapacity: true)
        instagramStoriesEvidence.removeAll(keepingCapacity: true)
    }

    private func resetLatchesForActiveBroadcast() {
        youtubeShieldLatched = false
        instagramShieldLatched = false
        youtubeGraceUntil = nil
        instagramGraceUntil = nil
        lastHandledYouTubeUnlockAt = SharedStore.shieldUnlockRequestedAt(surface: .youtube)
        lastHandledInstagramUnlockAt = SharedStore.shieldUnlockRequestedAt(surface: .instagram)
    }

    private func prepareEnabledSurfacesForActiveBroadcast(_ sharedState: SharedState) {
        if sharedState.realtimeYouTubeBlockingEnabled {
            classifier == nil ? applyShield(surface: .youtube) : ManagedSettingsApplier.clear(surface: .youtube)
        } else {
            ManagedSettingsApplier.clear(surface: .youtube)
        }
        if sharedState.realtimeInstagramBlockingEnabled {
            classifier == nil ? applyShield(surface: .instagram) : ManagedSettingsApplier.clear(surface: .instagram)
        } else {
            ManagedSettingsApplier.clear(surface: .instagram)
        }
    }

    private func prepareEnabledSurfacesAfterBroadcastStops() {
        let sharedState = SharedStore.snapshot()
        let shouldDeferYouTubeRestore = sharedState.realtimeShieldEnabled
            && sharedState.realtimeYouTubeBlockingEnabled
            && sharedState.softYouTubeBlockingEnabled
        SharedStore.setYouTubeShieldRestoreDeferred(shouldDeferYouTubeRestore)
        youtubeShieldLatched = sharedState.realtimeYouTubeBlockingEnabled
            && !shouldDeferYouTubeRestore
        instagramShieldLatched = sharedState.realtimeInstagramBlockingEnabled
        if shouldDeferYouTubeRestore {
            if SharedStore.isSlowthAppForeground() {
                SoftYouTubeActivityMonitoring.stop()
                RTLog.sampleHandler.notice(
                    "Soft YouTube blocking active — Slowth is foregrounded; monitor will arm after leaving"
                )
            } else if SoftYouTubeActivityMonitoring.start() {
                RTLog.sampleHandler.notice(
                    "Soft YouTube blocking active — waiting for 1s of YouTube use"
                )
            } else {
                // A failed monitor must not turn soft mode into an unlimited
                // unlock. Restore the ordinary at-rest shield immediately.
                SharedStore.setYouTubeShieldRestoreDeferred(false)
                youtubeShieldLatched = sharedState.realtimeYouTubeBlockingEnabled
                RTLog.sampleHandler.error(
                    "Soft YouTube monitor failed to arm — applying shield immediately"
                )
            }
        } else {
            SoftYouTubeActivityMonitoring.stop()
        }
    }

    private func recordInference(_ prediction: SurfacePrediction, durationMS: Double) {
        inferenceCount += 1
        lastPrediction = prediction
        lastInferenceDurationMS = durationMS
        inferenceDurationsMS.append(durationMS)
        if inferenceDurationsMS.count > 256 {
            inferenceDurationsMS.removeFirst(inferenceDurationsMS.count - 256)
        }
    }

    private func updateCandidateStreaks(
        youtubeVerdict: Bool,
        instagramReelsVerdict: Bool,
        instagramStoriesVerdict: Bool,
        requiredHits: Int,
        observationWindowFrames: Int
    ) {
        let previousYouTubeHits = youtubeShortsStreak
        let previousReelsHits = instagramReelsStreak
        let previousStoriesHits = instagramStoriesStreak
        youtubeShortsStreak = appendVote(
            youtubeVerdict, to: &youtubeShortsVotes, window: observationWindowFrames
        )
        instagramReelsStreak = appendVote(
            instagramReelsVerdict, to: &instagramReelsVotes, window: observationWindowFrames
        )
        instagramStoriesStreak = appendVote(
            instagramStoriesVerdict, to: &instagramStoriesVotes, window: observationWindowFrames
        )
        if previousYouTubeHits < requiredHits && youtubeShortsStreak >= requiredHits {
            youtubeCandidateEvents += 1
            RTLog.sampleHandler.notice("Surface candidate — youtube/shorts")
        }
        if previousReelsHits < requiredHits && instagramReelsStreak >= requiredHits {
            instagramCandidateEvents += 1
            RTLog.sampleHandler.notice("Surface candidate — instagram/reels")
        }
        if previousStoriesHits < requiredHits && instagramStoriesStreak >= requiredHits {
            instagramStoriesCandidateEvents += 1
            RTLog.sampleHandler.notice("Surface candidate — instagram/stories")
        }
    }

    private func appendVote(_ vote: Bool, to votes: inout [Bool], window: Int) -> Int {
        votes.append(vote)
        if votes.count > window {
            votes.removeFirst(votes.count - window)
        }
        return votes.reduce(0) { $0 + ($1 ? 1 : 0) }
    }

    private func recordDebugEvidence(
        classifier: SurfaceClassifier,
        prediction: SurfacePrediction,
        youtubeVerdict: Bool,
        instagramReelsVerdict: Bool,
        instagramStoriesVerdict: Bool,
        observationWindowFrames: Int,
        capturedAt: Date
    ) {
        guard DebugCaptureSettings.isEnabled else {
            youtubeShortsEvidence.removeAll(keepingCapacity: true)
            instagramReelsEvidence.removeAll(keepingCapacity: true)
            instagramStoriesEvidence.removeAll(keepingCapacity: true)
            return
        }

        let oldestInference = max(inferenceCount - observationWindowFrames + 1, 0)
        youtubeShortsEvidence.removeAll { $0.inferenceIndex < oldestInference }
        instagramReelsEvidence.removeAll { $0.inferenceIndex < oldestInference }
        instagramStoriesEvidence.removeAll { $0.inferenceIndex < oldestInference }
        guard youtubeVerdict || instagramReelsVerdict || instagramStoriesVerdict else { return }

        do {
            let image = try classifier.copyModelInputBGRA()
            let appProbabilities = Dictionary(
                uniqueKeysWithValues: SurfaceApp.allCases.map { app in
                    (app.rawValue, prediction.appProbabilities[app] ?? 0)
                }
            )
            let contentProbabilities: [String: Double] = [
                "youtube_shorts": prediction.youtubeContentProbabilities[.shorts] ?? 0,
                "youtube_normal": prediction.youtubeContentProbabilities[.normal] ?? 0,
                "instagram_reels": prediction.instagramContentProbabilities[.reels] ?? 0,
                "instagram_stories": prediction.instagramContentProbabilities[.stories] ?? 0,
                "instagram_normal": prediction.instagramContentProbabilities[.normal] ?? 0,
            ]
            let jointProbabilities = Dictionary(
                uniqueKeysWithValues: SurfaceClass.allCases.map { surface in
                    (surface.rawValue, prediction.probability(for: surface))
                }
            )

            func frame(for surface: SurfaceClass) -> DebugCaptureFramePixels {
                DebugCaptureFramePixels(
                    capturedAt: capturedAt,
                    inferenceIndex: inferenceCount,
                    probability: prediction.probability(for: surface),
                    appProbabilities: appProbabilities,
                    contentProbabilities: contentProbabilities,
                    jointProbabilities: jointProbabilities,
                    data: image.data,
                    width: image.width,
                    height: image.height,
                    bytesPerRow: image.bytesPerRow
                )
            }

            if youtubeVerdict {
                youtubeShortsEvidence.append(frame(for: .youtubeShorts))
            }
            if instagramReelsVerdict {
                instagramReelsEvidence.append(frame(for: .instagramReels))
            }
            if instagramStoriesVerdict {
                instagramStoriesEvidence.append(frame(for: .instagramStories))
            }
        } catch {
            DebugCaptureFileStore.setLastError(error.localizedDescription)
            RTLog.sampleHandler.error(
                "Debug evidence copy failed — \(error.localizedDescription, privacy: .public)"
            )
        }
    }

    private func queueDebugCapture(
        kind: DebugCaptureKind,
        evidence: [DebugCaptureFramePixels],
        threshold: Double,
        requiredHits: Int,
        detectedAt: Date
    ) {
        guard DebugCaptureSettings.isEnabled else { return }
        let frames = Array(evidence.suffix(requiredHits))
        guard frames.count == requiredHits, let metadata else { return }
        DebugCaptureWriter.enqueue(DebugCaptureEvent(
            eventID: UUID(),
            broadcastSessionID: broadcastSessionID,
            kind: kind,
            detectedAt: detectedAt,
            modelVersion: metadata.modelVersion,
            threshold: threshold,
            requiredHits: requiredHits,
            observationWindowFrames: metadata.effectiveObservationWindowFrames,
            frames: frames
        ))
    }

    private func enforceYouTube(
        verdict: Bool,
        requiredHits: Int,
        sharedState: SharedState,
        now: Date
    ) {
        guard sharedState.realtimeYouTubeBlockingEnabled else {
            youtubeShieldLatched = false
            youtubeShortsVotes.removeAll(keepingCapacity: true)
            youtubeShortsStreak = 0
            ManagedSettingsApplier.clear(surface: .youtube)
            return
        }
        if !isWithinGrace(youtubeGraceUntil, at: now) {
            if !youtubeShieldLatched && youtubeShortsStreak >= requiredHits {
                youtubeShieldLatched = true
                RTLog.sampleHandler.notice("YouTube Shorts detected — shielding youtube")
                SharedStore.setLastYouTubeShortsDetectionAt(now)
                if let threshold = metadata?.threshold(for: .youtubeShorts) {
                    queueDebugCapture(
                        kind: .youtubeShorts,
                        evidence: youtubeShortsEvidence,
                        threshold: threshold,
                        requiredHits: requiredHits,
                        detectedAt: now
                    )
                }
                publishDiagnostics(force: true)
                applyShield(surface: .youtube)
            }
        }
        if !youtubeShieldLatched {
            ManagedSettingsApplier.clear(surface: .youtube)
        }
    }

    private func enforceInstagram(
        reelsVerdict: Bool,
        storiesVerdict: Bool,
        requiredHits: Int,
        sharedState: SharedState,
        now: Date
    ) {
        guard sharedState.realtimeInstagramBlockingEnabled else {
            instagramShieldLatched = false
            instagramReelsVotes.removeAll(keepingCapacity: true)
            instagramStoriesVotes.removeAll(keepingCapacity: true)
            instagramReelsStreak = 0
            instagramStoriesStreak = 0
            ManagedSettingsApplier.clear(surface: .instagram)
            return
        }
        let detectedReels = reelsVerdict && instagramReelsStreak >= requiredHits
        let detectedStories = storiesVerdict && instagramStoriesStreak >= requiredHits
        if !isWithinGrace(instagramGraceUntil, at: now) {
            if !instagramShieldLatched && (detectedReels || detectedStories) {
                instagramShieldLatched = true
                let content = detectedStories ? "stories" : "reels"
                RTLog.sampleHandler.notice(
                    "Instagram \(content, privacy: .public) detected — shielding instagram"
                )
                if detectedStories {
                    SharedStore.setLastInstagramStoriesDetectionAt(now)
                    if let threshold = metadata?.threshold(for: .instagramStories) {
                        queueDebugCapture(
                            kind: .instagramStories,
                            evidence: instagramStoriesEvidence,
                            threshold: threshold,
                            requiredHits: requiredHits,
                            detectedAt: now
                        )
                    }
                } else {
                    SharedStore.setLastInstagramReelsDetectionAt(now)
                    if let threshold = metadata?.threshold(for: .instagramReels) {
                        queueDebugCapture(
                            kind: .instagramReels,
                            evidence: instagramReelsEvidence,
                            threshold: threshold,
                            requiredHits: requiredHits,
                            detectedAt: now
                        )
                    }
                }
                publishDiagnostics(force: true)
                applyShield(surface: .instagram)
            }
        }
        if !instagramShieldLatched {
            ManagedSettingsApplier.clear(surface: .instagram)
        }
    }

    private func loadClassifier() {
        do {
            let loaded = try SurfaceClassifier()
            classifier = loaded
            metadata = loaded.metadata
            classifierStatus = "ready"
            classifierError = nil
            RTLog.sampleHandler.notice(
                "SurfaceDetector loaded — version=\(loaded.metadata.modelVersion, privacy: .public) availableMemoryMB=\(RealtimeShieldMemory.availableMB, privacy: .public)"
            )
        } catch {
            classifier = nil
            metadata = nil
            classifierStatus = "failed"
            classifierError = error.localizedDescription
            RTLog.sampleHandler.error(
                "SurfaceDetector load failed — fail-closing enabled surfaces: \(error.localizedDescription, privacy: .public)"
            )
        }
    }

    private func failInference(_ message: String, sharedState: SharedState) {
        classifierStatus = "failed"
        classifierError = message
        resetStreaks()
        publishDiagnostics(force: true)
        failCloseEnabledSurfaces(sharedState)
        RTLog.sampleHandler.error(
            "SurfaceDetector inference failed — fail-closing enabled surfaces: \(message, privacy: .public)"
        )
    }

    private func failCloseEnabledSurfaces(_ sharedState: SharedState) {
        if sharedState.realtimeYouTubeBlockingEnabled {
            youtubeShieldLatched = true
            applyShield(surface: .youtube)
        }
        if sharedState.realtimeInstagramBlockingEnabled {
            instagramShieldLatched = true
            applyShield(surface: .instagram)
        }
    }

    private func consumeUnlockRequests(at now: Date) {
        if let requestedAt = SharedStore.shieldUnlockRequestedAt(surface: .youtube),
           lastHandledYouTubeUnlockAt.map({ requestedAt > $0 }) ?? true {
            lastHandledYouTubeUnlockAt = requestedAt
            youtubeShieldLatched = false
            youtubeShortsVotes.removeAll(keepingCapacity: true)
            youtubeShortsEvidence.removeAll(keepingCapacity: true)
            youtubeShortsStreak = 0
            youtubeGraceUntil = now.addingTimeInterval(Self.unlockGraceSeconds)
            ManagedSettingsApplier.clear(surface: .youtube)
            RTLog.sampleHandler.notice("YouTube shield released for navigation grace")
        }

        let sharedState = SharedStore.snapshot()
        if sharedState.realtimeInstagramBlockingEnabled,
           let requestedAt = SharedStore.shieldUnlockRequestedAt(surface: .instagram),
           lastHandledInstagramUnlockAt.map({ requestedAt > $0 }) ?? true {
            lastHandledInstagramUnlockAt = requestedAt
            instagramShieldLatched = false
            instagramReelsVotes.removeAll(keepingCapacity: true)
            instagramStoriesVotes.removeAll(keepingCapacity: true)
            instagramReelsEvidence.removeAll(keepingCapacity: true)
            instagramStoriesEvidence.removeAll(keepingCapacity: true)
            instagramReelsStreak = 0
            instagramStoriesStreak = 0
            instagramGraceUntil = now.addingTimeInterval(Self.unlockGraceSeconds)
            ManagedSettingsApplier.clear(surface: .instagram)
            RTLog.sampleHandler.notice("Instagram shield released for navigation grace")
        }
    }

    private func isWithinGrace(_ deadline: Date?, at now: Date) -> Bool {
        guard let deadline else { return false }
        return now < deadline
    }

    private func p95(_ values: [Double]) -> Double? {
        let sorted = values.sorted()
        guard !sorted.isEmpty else { return nil }
        let index = min(Int(ceil(Double(sorted.count) * 0.95)) - 1, sorted.count - 1)
        return sorted[max(index, 0)]
    }

    private func publishDiagnostics(force: Bool) {
        let now = Date()
        guard force || now.timeIntervalSince(lastDiagnosticsWrite) >= 2 else { return }
        lastDiagnosticsWrite = now
        let currentFootprint = RealtimeShieldMemory.currentFootprintMB
        if let currentFootprint {
            peakFootprintMB = max(peakFootprintMB, currentFootprint)
        }
        let appProbabilities = lastPrediction.map { prediction in
            Dictionary(
                uniqueKeysWithValues: SurfaceApp.allCases.map { app in
                    (app.rawValue, prediction.appProbabilities[app] ?? 0)
                }
            )
        }
        let contentProbabilities: [String: Double]? = lastPrediction.flatMap { prediction in
            switch prediction.topApp {
            case .youtube:
                return Dictionary(
                    uniqueKeysWithValues: YouTubeContent.allCases.map { content in
                        (content.rawValue, prediction.youtubeContentProbabilities[content] ?? 0)
                    }
                )
            case .instagram:
                return Dictionary(
                    uniqueKeysWithValues: InstagramContent.allCases.map { content in
                        (content.rawValue, prediction.instagramContentProbabilities[content] ?? 0)
                    }
                )
            case .other:
                return ["normal": 1]
            case nil:
                return nil
            }
        }
        let jointProbabilities = lastPrediction.map { prediction in
            Dictionary(
                uniqueKeysWithValues: SurfaceClass.allCases.map { surface in
                    (surface.rawValue, prediction.probability(for: surface))
                }
            )
        }
        let diagnostics = RealtimeShieldDiagnostics(
            modelStatus: classifierStatus,
            modelVersion: metadata?.modelVersion,
            receivedVideoFrames: receivedVideoFrames,
            inferenceCount: inferenceCount,
            lastApp: lastPrediction?.topApp?.rawValue,
            lastContent: lastPrediction?.topContent,
            appProbabilities: appProbabilities,
            contentProbabilities: contentProbabilities,
            jointProbabilities: jointProbabilities,
            confidenceThresholds: metadata?.confidenceThresholds,
            requiredConsecutiveHits: metadata?.requiredConsecutiveHits,
            lastInferenceDurationMS: lastInferenceDurationMS,
            inferenceP95MS: p95(inferenceDurationsMS),
            youtubeShortsStreak: youtubeShortsStreak,
            instagramReelsStreak: instagramReelsStreak,
            instagramStoriesStreak: instagramStoriesStreak,
            youtubeCandidateEvents: youtubeCandidateEvents,
            instagramCandidateEvents: instagramCandidateEvents,
            instagramStoriesCandidateEvents: instagramStoriesCandidateEvents,
            youtubeShieldLatched: youtubeShieldLatched,
            instagramShieldLatched: instagramShieldLatched,
            youtubeGraceRemainingSeconds: youtubeGraceUntil.map { max($0.timeIntervalSince(now), 0) },
            instagramGraceRemainingSeconds: instagramGraceUntil.map { max($0.timeIntervalSince(now), 0) },
            lastClassifierError: classifierError,
            availableMemoryMB: RealtimeShieldMemory.availableMB,
            currentFootprintMB: currentFootprint,
            peakFootprintMB: peakFootprintMB > 0 ? peakFootprintMB : nil,
            updatedAt: now
        )
        SharedStore.setRealtimeShieldDiagnostics(diagnostics)

        if force || now.timeIntervalSince(lastTelemetryLog) >= 10 {
            lastTelemetryLog = now
            let encoder = JSONEncoder()
            encoder.outputFormatting = [.sortedKeys]
            if let data = try? encoder.encode(diagnostics),
               let json = String(data: data, encoding: .utf8) {
                RTLog.sampleHandler.notice("metrics \(json, privacy: .public)")
            }
        }
    }

    private func reshieldEnabledSurfaces() {
        let sharedState = SharedStore.snapshot()
        if sharedState.realtimeShieldEnabled
            && sharedState.realtimeYouTubeBlockingEnabled
            && !sharedState.youtubeShieldRestoreDeferred {
            applyShield(surface: .youtube)
        } else {
            ManagedSettingsApplier.clear(surface: .youtube)
        }
        if sharedState.realtimeInstagramBlockingEnabled {
            applyShield(surface: .instagram)
        } else {
            ManagedSettingsApplier.clear(surface: .instagram)
        }
    }

    private func applyShield(surface: ManagedSettingsApplier.Surface) {
        #if canImport(FamilyControls)
        let sharedState = SharedStore.snapshot()
        guard sharedState.realtimeShieldEnabled else {
            ManagedSettingsApplier.clear(surface: surface)
            return
        }
        if surface == .youtube && !sharedState.realtimeYouTubeBlockingEnabled {
            ManagedSettingsApplier.clear(surface: .youtube)
            return
        }
        if surface == .instagram && !sharedState.realtimeInstagramBlockingEnabled {
            ManagedSettingsApplier.clear(surface: .instagram)
            return
        }
        let data = surface == .youtube
            ? SharedStore.youtubeSelectionData()
            : SharedStore.instagramSelectionData()
        guard let data,
              let selection = try? JSONDecoder().decode(
                  FamilyActivitySelection.self,
                  from: data
              ) else {
            RTLog.sampleHandler.error(
                "applyShield(\(surface.rawValue, privacy: .public)): no decodable selection stored"
            )
            return
        }
        ManagedSettingsApplier.apply(surface: surface, selection: selection)
        #endif
    }
}
