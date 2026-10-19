import Foundation
import ReplayKit
#if canImport(FamilyControls)
import FamilyControls
#endif

// Release uses Flat 11 scores; Debug can compare hierarchical/cascade models.
// Observation storage is pure; timing, routing and enforcement stay here.
final class SampleHandler: RPBroadcastSampleHandler {
    // ReplayKit callbacks and the rest watchdog share classifier/latch state.
    private let processingLock = NSRecursiveLock()
    private var restWatchdog: DispatchSourceTimer?
    private var classifier: (any SurfaceClassifying)?
    private var metadata: SurfaceModelMetadata?
    private var lastInferenceTimestamp: Double?
    private var timestampClock = CascadeTimestampClock()
    private var receivedVideoFrames = 0
    private var inferenceCount = 0
    private var lastPrediction: SurfacePrediction?
    private var cascadeEvidenceBoundary = CascadeEvidenceBoundary()
    private var lastInferenceDurationMS: Double?
    private var inferenceDurationsMS: [Double] = []
    private var peakFootprintMB: Double = 0
    private var classifierStatus = "not started"
    private var classifierError: String?
    private var lastDiagnosticsWrite = Date.distantPast
    private var lastTelemetryLog = Date.distantPast
    private var youtubeShieldLatched = false
    private var instagramShieldLatched = false
    private var facebookShieldLatched = false
    private var xShieldLatched = false
    private var recorderBindings = IOSRecorderBindings()
    private var detectionRestGrants: [String: IOSDetectionRest] = [:]
    private var lastRestGrantRead = -Double.infinity
    private var youtubeGraceUntil: Date?
    private var instagramGraceUntil: Date?
    private var facebookGraceUntil: Date?
    private var xGraceUntil: Date?
    private var lastHandledYouTubeUnlockAt: String?
    private var lastHandledInstagramUnlockAt: String?
    private var lastHandledFacebookUnlockAt: String?
    private var lastHandledXUnlockAt: String?
    #if DEBUG
    private var youtubeShortsEvidence: [DebugCaptureFramePixels] = []
    private var instagramReelsEvidence: [DebugCaptureFramePixels] = []
    private var facebookReelsEvidence: [DebugCaptureFramePixels] = []
    private var xReelsEvidence: [DebugCaptureFramePixels] = []
    private var instagramStoriesEvidence: [DebugCaptureFramePixels] = []
    private var facebookStoriesEvidence: [DebugCaptureFramePixels] = []
    #endif
    private var observations = SurfaceObservationState()
    private var recordingBackend: ModelBackend = ModelSettings.defaultBackend
    #if DEBUG
    private var broadcastSessionID = UUID()
    private var sessionCapture: SessionCapture?

    #endif

    override func broadcastStarted(withSetupInfo setupInfo: [String: NSObject]?) {
        processingLock.lock()
        defer { processingLock.unlock() }
        RTLog.sampleHandler.notice("broadcastStarted — loading selected surface classifier")
        SoftYouTubeActivityMonitoring.stop()
        SharedStore.setBroadcastActive(true)
        resetSessionState()
        // Freeze the choice before a delayed load or a retry after pause/failure.
        #if DEBUG
        recordingBackend = DebugModelSettings.resolve(
            stored: AppGroup.defaults.string(forKey: DebugModelSettings.storageKey),
            debugEnabled: DebugMode.isEnabled,
            cascadeAvailable: DebugModelSettings.cascadeAvailable)
        #else
        recordingBackend = ModelSettings.defaultBackend
        #endif
        let sharedState = SharedStore.snapshot()
        if sharedState.realtimeShieldEnabled {
            loadClassifier()
        } else {
            classifierStatus = "disabled"
        }
        publishDiagnostics(force: true)
        do {
            try publishClassifierAvailability(sharedState)
            try IOSPauseCoordinator.beginRecordingGrace()
        } catch { RTLog.sampleHandler.error("Could not persist recording startup grace: \(String(describing: error), privacy: .public)") }
        prepareEnabledSurfacesForActiveBroadcast(sharedState)
        startRestWatchdog()
        #if DEBUG
        if let interval = SessionCaptureSettings.interval,
           let root = SessionCaptureSettings.rootDirectory {
            sessionCapture = SessionCapture(root: root, sessionID: broadcastSessionID,
                interval: interval, startedUptime: ProcessInfo.processInfo.systemUptime,
                limits: SessionCaptureSettings.captureLimits())
        }
        #endif
    }

    override func broadcastPaused() {
        processingLock.lock()
        defer { processingLock.unlock() }
        RTLog.sampleHandler.notice("broadcastPaused — applying at-rest shield policy")
        stopRestWatchdog()
        SharedStore.setBroadcastActive(false)
        resetStreaks()
        prepareEnabledSurfacesAfterBroadcastStops()
        _ = try? IOSPauseCoordinator.snapshot()
        publishDiagnostics(force: true)
        reshieldEnabledSurfaces()
        #if DEBUG
        sessionCapture?.pause()
        #endif
    }

    override func broadcastResumed() {
        processingLock.lock()
        defer { processingLock.unlock() }
        RTLog.sampleHandler.notice("broadcastResumed — restoring surface classifier state")
        SoftYouTubeActivityMonitoring.stop()
        SharedStore.setBroadcastActive(true)
        resetStreaks()
        resetLatchesForActiveBroadcast()
        lastInferenceTimestamp = nil
        timestampClock = CascadeTimestampClock()
        let sharedState = SharedStore.snapshot()
        if sharedState.realtimeShieldEnabled && classifier == nil {
            loadClassifier()
        }
        publishDiagnostics(force: true)
        do {
            try publishClassifierAvailability(sharedState)
            try IOSPauseCoordinator.beginRecordingGrace()
        } catch { RTLog.sampleHandler.error("Could not persist recording startup grace: \(String(describing: error), privacy: .public)") }
        prepareEnabledSurfacesForActiveBroadcast(sharedState)
        startRestWatchdog()
        #if DEBUG
        if SessionCaptureSettings.isEnabled {
            sessionCapture?.resume()
        } else {
            sessionCapture?.finish(reason: "opted_out")
        }
        #endif
    }

    override func broadcastFinished() {
        processingLock.lock()
        defer { processingLock.unlock() }
        RTLog.sampleHandler.notice("broadcastFinished — applying at-rest shield policy")
        stopRestWatchdog()
        SharedStore.setBroadcastActive(false)
        resetStreaks()
        prepareEnabledSurfacesAfterBroadcastStops()
        _ = try? IOSPauseCoordinator.snapshot()
        publishDiagnostics(force: true)
        reshieldEnabledSurfaces()
        #if DEBUG
        sessionCapture?.finish(reason: "finished")
        #endif
    }

    override func processSampleBuffer(
        _ sampleBuffer: CMSampleBuffer,
        with sampleBufferType: RPSampleBufferType
    ) {
        processingLock.lock()
        defer { processingLock.unlock() }
        guard sampleBufferType == .video else { return }
        #if DEBUG
        var framePredictions: [String: Double]?
        defer {
            captureSessionFrame(sampleBuffer, predictions: framePredictions)
        }
        #endif
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
        let observation = timestampClock.resolve(
            pts: timestamp.isValid ? CMTimeGetSeconds(timestamp) : .nan,
            uptime: ProcessInfo.processInfo.systemUptime)
        let interval = metadata?.inferenceIntervalSeconds ?? 0.25
        let sampling = observation.reset ? CascadeSampling.sample(reset: true)
            : CascadeSampling.decide(timestamp: observation.seconds, previous: lastInferenceTimestamp, interval: interval)
        switch sampling {
        case .skip:
            publishDiagnostics(force: false)
            return
        case .sample(let reset):
            if reset { resetStreaks() }
        }
        if classifier is FlatClassifier, let previous = lastInferenceTimestamp,
           observation.seconds - previous > 1.25 { resetStreaks() }
        lastInferenceTimestamp = observation.seconds

        guard let pixelBuffer = CMSampleBufferGetImageBuffer(sampleBuffer) else {
            failInference("sample has no pixel buffer", sharedState: sharedState)
            return
        }

        let startedAt = CFAbsoluteTimeGetCurrent()
        do {
            let enabledApps = CascadePolicy.enabledApps(
                youtube: sharedState.realtimeYouTubeBlockingEnabled,
                reels: sharedState.realtimeInstagramReelsBlockingEnabled,
                stories: sharedState.realtimeInstagramStoriesBlockingEnabled,
                facebookReels: sharedState.realtimeFacebookReelsBlockingEnabled,
                facebookStories: sharedState.realtimeFacebookStoriesBlockingEnabled,
                xReels: sharedState.realtimeXReelsBlockingEnabled)
            let prediction = try classifier.predict(pixelBuffer: pixelBuffer, enabledApps: enabledApps)
            guard let youtubeThreshold = classifier.metadata.threshold(for: .youtubeShorts),
                  let instagramReelsThreshold = classifier.metadata.threshold(for: .instagramReels),
                  let instagramStoriesThreshold = classifier.metadata.threshold(
                      for: .instagramStories
                  ) else {
                throw SurfaceClassifierError.invalidMetadata
            }
            if classifierStatus == "failed" {
                try publishClassifierAvailability(sharedState)
                resetLatchesForActiveBroadcast()
                resetStreaks()
            }
            let durationMS = (CFAbsoluteTimeGetCurrent() - startedAt) * 1_000
            if let routing = prediction.routing {
                var boundary = cascadeEvidenceBoundary
                if boundary.observe(app: routing.app, timestamp: observation.seconds,
                                    maxGap: routing.maxEvidenceGapSeconds) {
                    resetStreaks()
                }
                cascadeEvidenceBoundary = boundary
                if routing.app != lastPrediction?.routing?.app || routing.reason != lastPrediction?.routing?.reason {
                    RTLog.sampleHandler.debug("Cascade route=\(routing.app?.rawValue ?? "unknown", privacy: .public) reason=\(routing.reason, privacy: .public)")
                }
            }
            recordInference(prediction, durationMS: durationMS)
            #if DEBUG
            // Only this frame's actually executed heads; missing specialists stay absent.
            framePredictions = Dictionary(uniqueKeysWithValues:
                prediction.appProbabilities.map { ("app.\($0.key.rawValue)", $0.value) }
                + prediction.youtubeContentProbabilities.map { ("youtube.\($0.key.rawValue)", $0.value) }
                + prediction.instagramContentProbabilities.map { ("instagram.\($0.key.rawValue)", $0.value) }
                + prediction.facebookContentProbabilities.map { ("facebook.\($0.key.rawValue)", $0.value) }
                + prediction.xContentProbabilities.map { ("x.\($0.key.rawValue)", $0.value) })

            #endif
            let youtubeVerdict = !ignoresDetection("youtube") && prediction.probability(for: .youtubeShorts) >= youtubeThreshold
            let instagramReelsVerdict = !ignoresDetection("instagram") && sharedState.realtimeInstagramReelsBlockingEnabled
                && prediction.probability(for: .instagramReels) >= instagramReelsThreshold
            let instagramStoriesVerdict = !ignoresDetection("instagram") && sharedState.realtimeInstagramStoriesBlockingEnabled
                && prediction.probability(for: .instagramStories) >= instagramStoriesThreshold
            let facebookReelsVerdict = !ignoresDetection("facebook") && sharedState.realtimeFacebookReelsBlockingEnabled
                && prediction.probability(for: .facebookReels) >= (classifier.metadata.threshold(for: .facebookReels) ?? .infinity)
            let xReelsVerdict = !ignoresDetection("x") && sharedState.realtimeXReelsBlockingEnabled
                && prediction.probability(for: .xReels) >= (classifier.metadata.threshold(for: .xReels) ?? .infinity)
            let facebookStoriesVerdict = !ignoresDetection("facebook") && sharedState.realtimeFacebookStoriesBlockingEnabled
                && prediction.probability(for: .facebookStories) >= (classifier.metadata.threshold(for: .facebookStories) ?? .infinity)
            #if DEBUG
            recordDebugEvidence(
                classifier: classifier,
                prediction: prediction,
                youtubeVerdict: youtubeVerdict,
                instagramReelsVerdict: instagramReelsVerdict,
                instagramStoriesVerdict: instagramStoriesVerdict,
                facebookReelsVerdict: facebookReelsVerdict,
                xReelsVerdict: xReelsVerdict,
                facebookStoriesVerdict: facebookStoriesVerdict,
                observationWindowFrames: classifier.metadata.effectiveObservationWindowFrames,
                capturedAt: now
            )
            #endif
            updateCandidateStreaks(
                youtubeVerdict: youtubeVerdict,
                instagramReelsVerdict: instagramReelsVerdict,
                instagramStoriesVerdict: instagramStoriesVerdict,
                facebookReelsVerdict: facebookReelsVerdict,
                xReelsVerdict: xReelsVerdict,
                facebookStoriesVerdict: facebookStoriesVerdict,
                requiredHits: classifier.metadata.requiredConsecutiveHits,
                observationWindowFrames: classifier.metadata.effectiveObservationWindowFrames
            )
            enforceYouTube(
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
            enforceFacebook(
                reelsVerdict: facebookReelsVerdict,
                storiesVerdict: facebookStoriesVerdict,
                requiredHits: classifier.metadata.requiredConsecutiveHits,
                sharedState: sharedState,
                now: now
            )
            enforceX(verdict: xReelsVerdict, requiredHits: classifier.metadata.requiredConsecutiveHits, sharedState: sharedState, now: now)
            classifierStatus = "ready"
            classifierError = nil
        } catch {
            self.classifier = nil
            metadata = nil
            failInference(error.localizedDescription, sharedState: sharedState)
        }
        publishDiagnostics(force: classifierStatus == "failed")
    }

    #if DEBUG
    private func captureSessionFrame(_ sampleBuffer: CMSampleBuffer, predictions: [String: Double]?) {
        guard let sessionCapture else { return }
        guard SessionCaptureSettings.isEnabled else {
            sessionCapture.finish(reason: "opted_out")
            return
        }
        guard let pixels = CMSampleBufferGetImageBuffer(sampleBuffer) else { return }
        let pts = CMSampleBufferGetPresentationTimeStamp(sampleBuffer)
        let orientation = (CMGetAttachment(sampleBuffer, key: RPVideoSampleOrientationKey as CFString,
                                            attachmentModeOut: nil) as? NSNumber)?.uint32Value
        let frame = SessionCapture.Frame(ptsValue: pts.value, ptsTimescale: pts.timescale,
            ptsEpoch: pts.epoch, ptsFlags: pts.flags.rawValue, orientation: orientation,
            width: CVPixelBufferGetWidth(pixels), height: CVPixelBufferGetHeight(pixels),
            modelVersion: metadata?.modelVersion, predictions: predictions)
        // At most one full-size ReplayKit buffer is retained; no copy/JPEG work here.
        sessionCapture.offer(frame, uptime: ProcessInfo.processInfo.systemUptime) {
            try SessionJPEG.encode(pixels, orientation: orientation)
        }
    }

    #endif
    private func resetSessionState() {
        classifier = nil
        metadata = nil
        #if DEBUG
        sessionCapture?.finish(reason: "finished")
        sessionCapture = nil
        broadcastSessionID = UUID()
        #endif
        resetStreaks()
        resetLatchesForActiveBroadcast()
        receivedVideoFrames = 0
        inferenceCount = 0
        lastPrediction = nil
        lastInferenceDurationMS = nil
        inferenceDurationsMS.removeAll(keepingCapacity: true)
        peakFootprintMB = 0
        lastInferenceTimestamp = nil
        timestampClock = CascadeTimestampClock()
        observations.resetSession()
    }

    private func resetStreaks() {
        cascadeEvidenceBoundary = CascadeEvidenceBoundary()
        observations.resetObservations()
        #if DEBUG
        youtubeShortsEvidence.removeAll(keepingCapacity: true)
        instagramReelsEvidence.removeAll(keepingCapacity: true)
        facebookReelsEvidence.removeAll(keepingCapacity: true)
        xReelsEvidence.removeAll(keepingCapacity: true)
        instagramStoriesEvidence.removeAll(keepingCapacity: true)
        facebookStoriesEvidence.removeAll(keepingCapacity: true)
        #endif
    }

    private func resetLatchesForActiveBroadcast() {
        detectionRestGrants = [:]
        lastRestGrantRead = -Double.infinity
        youtubeShieldLatched = false
        instagramShieldLatched = false
        facebookShieldLatched = false
        xShieldLatched = false
        youtubeGraceUntil = nil
        instagramGraceUntil = nil
        facebookGraceUntil = nil
        xGraceUntil = nil
        lastHandledYouTubeUnlockAt = nil
        lastHandledInstagramUnlockAt = nil
        lastHandledFacebookUnlockAt = nil
        lastHandledXUnlockAt = nil
    }

    private func publishClassifierAvailability(_ state: SharedState) throws {
        try IOSPauseCoordinator.setInferenceFailure(classifier == nil, state: state)
        if metadata?.threshold(for: .youtubeShorts) == nil {
            try IOSPauseCoordinator.setInferenceFailure(true, state: state, target: "youtube")
        }
        if metadata?.threshold(for: .instagramReels) == nil || metadata?.threshold(for: .instagramStories) == nil {
            try IOSPauseCoordinator.setInferenceFailure(true, state: state, target: "instagram")
        }
        if recordingBackend.supportsFacebook && (metadata?.threshold(for: .facebookReels) == nil || metadata?.threshold(for: .facebookStories) == nil) {
            try IOSPauseCoordinator.setInferenceFailure(true, state: state, target: "facebook")
        }
        if recordingBackend.supportsX && metadata?.threshold(for: .xReels) == nil {
            try IOSPauseCoordinator.setInferenceFailure(true, state: state, target: "x")
        }
    }

    private func prepareEnabledSurfacesForActiveBroadcast(_ sharedState: SharedState) {
        for surface in [ManagedSettingsApplier.Surface.youtube, .instagram, .facebook, .x] {
            let supported = (surface != .facebook || metadata?.threshold(for: .facebookReels) != nil)
                && (surface != .x || metadata?.threshold(for: .xReels) != nil)
            let context = BlockingContext(target: surface.rawValue,
                enabled: surface == .youtube ? sharedState.realtimeYouTubeBlockingEnabled :
                    surface == .instagram ? sharedState.realtimeInstagramBlockingEnabled :
                    surface == .facebook ? sharedState.realtimeFacebookBlockingEnabled : sharedState.realtimeXBlockingEnabled,
                recording: true, inferenceFailed: classifier == nil || !supported)
            let decision = BlockingRules.decide(context, .recordingStarted)
            if decision.shield == .block { applyShield(surface: surface) }
            else { ManagedSettingsApplier.clear(surface: surface) }
        }
    }

    private func prepareEnabledSurfacesAfterBroadcastStops() {
        let sharedState = SharedStore.snapshot()
        youtubeShieldLatched = BlockingCoordinator.recordingStopped(sharedState)
        instagramShieldLatched = sharedState.realtimeInstagramBlockingEnabled
        facebookShieldLatched = sharedState.realtimeFacebookBlockingEnabled
        xShieldLatched = sharedState.realtimeXBlockingEnabled
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
        facebookReelsVerdict: Bool,
        xReelsVerdict: Bool,
        facebookStoriesVerdict: Bool,
        requiredHits: Int,
        observationWindowFrames: Int
    ) {
        let previousYouTube = observations.youtubeCandidateEvents
        let previousInstagram = observations.instagramCandidateEvents
        let previousStories = observations.instagramStoriesCandidateEvents
        observations.append(
            youtubeVerdict: youtubeVerdict, instagramReelsVerdict: instagramReelsVerdict,
            instagramStoriesVerdict: instagramStoriesVerdict, facebookReelsVerdict: facebookReelsVerdict,
            xReelsVerdict: xReelsVerdict, facebookStoriesVerdict: facebookStoriesVerdict,
            requiredHits: requiredHits, observationWindowFrames: observationWindowFrames)
        if observations.youtubeCandidateEvents > previousYouTube {
            RTLog.sampleHandler.notice("Surface candidate — youtube/shorts")
        }
        if observations.instagramCandidateEvents > previousInstagram {
            RTLog.sampleHandler.notice("Surface candidate — instagram/reels")
        }
        if observations.instagramStoriesCandidateEvents > previousStories {
            RTLog.sampleHandler.notice("Surface candidate — instagram/stories")
        }
    }


    #if DEBUG
    private func recordDebugEvidence(
        classifier: any SurfaceClassifying,
        prediction: SurfacePrediction,
        youtubeVerdict: Bool,
        instagramReelsVerdict: Bool,
        instagramStoriesVerdict: Bool,
        facebookReelsVerdict: Bool,
        xReelsVerdict: Bool,
        facebookStoriesVerdict: Bool,
        observationWindowFrames: Int,
        capturedAt: Date
    ) {
        guard DebugCaptureSettings.isEnabled else {
            youtubeShortsEvidence.removeAll(keepingCapacity: true)
            instagramReelsEvidence.removeAll(keepingCapacity: true)
            facebookReelsEvidence.removeAll(keepingCapacity: true)
            xReelsEvidence.removeAll(keepingCapacity: true)
            instagramStoriesEvidence.removeAll(keepingCapacity: true)
            facebookStoriesEvidence.removeAll(keepingCapacity: true)
            return
        }

        let oldestInference = max(inferenceCount - observationWindowFrames + 1, 0)
        youtubeShortsEvidence.removeAll { $0.inferenceIndex < oldestInference }
        instagramReelsEvidence.removeAll { $0.inferenceIndex < oldestInference }
        facebookReelsEvidence.removeAll { $0.inferenceIndex < oldestInference }
        xReelsEvidence.removeAll { $0.inferenceIndex < oldestInference }
        instagramStoriesEvidence.removeAll { $0.inferenceIndex < oldestInference }
        facebookStoriesEvidence.removeAll { $0.inferenceIndex < oldestInference }
        guard youtubeVerdict || instagramReelsVerdict || instagramStoriesVerdict || facebookReelsVerdict || facebookStoriesVerdict || xReelsVerdict else { return }

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
                "facebook_reels": prediction.facebookContentProbabilities[.reels] ?? 0,
                "x_reels": prediction.xContentProbabilities[.reels] ?? 0,
                "facebook_stories": prediction.facebookContentProbabilities[.stories] ?? 0,
                "facebook_normal": prediction.facebookContentProbabilities[.normal] ?? 0,
                "x_normal": prediction.xContentProbabilities[.normal] ?? 0,
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
            if facebookReelsVerdict { facebookReelsEvidence.append(frame(for: .facebookReels)) }
            if xReelsVerdict { xReelsEvidence.append(frame(for: .xReels)) }
            if facebookStoriesVerdict { facebookStoriesEvidence.append(frame(for: .facebookStories)) }
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

    #endif
    private func registerDetection(_ target: String, state: SharedState) -> Bool {
        do {
            return try IOSPauseCoordinator.requestRest(target: target,
                expectedSelection: IOSPauseCoordinator.selection(target, state: state),
                expectedRevision: recorderBindings.revision) == .accepted
        } catch {
            // Retain protection on storage failure, but retry the durable event
            // on subsequent frames instead of latching an unrecorded detection.
            if let surface = ManagedSettingsApplier.Surface(rawValue: target) { applyShield(surface: surface) }
            return false
        }
    }

    private func enforceYouTube(
        requiredHits: Int,
        sharedState: SharedState,
        now: Date
    ) {
        guard sharedState.realtimeYouTubeBlockingEnabled else {
            youtubeShieldLatched = false
            observations.reset(service: .youtube)
            ManagedSettingsApplier.clear(surface: .youtube)
            return
        }
        if !ignoresDetection("youtube") {
            if !youtubeShieldLatched && observations.youtubeShortsStreak >= requiredHits {
                guard registerDetection("youtube", state: sharedState) else { return }
                youtubeShieldLatched = true
                RTLog.sampleHandler.notice("YouTube Shorts detected — shielding youtube")
                SharedStore.setLastYouTubeShortsDetectionAt(now)
                #if DEBUG
                if let threshold = metadata?.threshold(for: .youtubeShorts) {
                    queueDebugCapture(
                        kind: .youtubeShorts,
                        evidence: youtubeShortsEvidence,
                        threshold: threshold,
                        requiredHits: requiredHits,
                        detectedAt: now
                    )
                }
                #endif
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
            observations.reset(service: .instagram)
            ManagedSettingsApplier.clear(surface: .instagram)
            return
        }
        let detectedReels = reelsVerdict && observations.instagramReelsStreak >= requiredHits
        let detectedStories = storiesVerdict && observations.instagramStoriesStreak >= requiredHits
        if !ignoresDetection("instagram") {
            if !instagramShieldLatched && (detectedReels || detectedStories) {
                guard registerDetection("instagram", state: sharedState) else { return }
                instagramShieldLatched = true
                let content = detectedStories ? "stories" : "reels"
                RTLog.sampleHandler.notice(
                    "Instagram \(content, privacy: .public) detected — shielding instagram"
                )
                if detectedStories {
                    SharedStore.setLastInstagramStoriesDetectionAt(now)
                    #if DEBUG
                    if let threshold = metadata?.threshold(for: .instagramStories) {
                        queueDebugCapture(
                            kind: .instagramStories,
                            evidence: instagramStoriesEvidence,
                            threshold: threshold,
                            requiredHits: requiredHits,
                            detectedAt: now
                        )
                    }
                    #endif
                } else {
                    SharedStore.setLastInstagramReelsDetectionAt(now)
                    #if DEBUG
                    if let threshold = metadata?.threshold(for: .instagramReels) {
                        queueDebugCapture(
                            kind: .instagramReels,
                            evidence: instagramReelsEvidence,
                            threshold: threshold,
                            requiredHits: requiredHits,
                            detectedAt: now
                        )
                    }
                    #endif
                }
                publishDiagnostics(force: true)
                applyShield(surface: .instagram)
            }
        }
        if !instagramShieldLatched {
            ManagedSettingsApplier.clear(surface: .instagram)
        }
    }

    private func enforceFacebook(
        reelsVerdict: Bool,
        storiesVerdict: Bool,
        requiredHits: Int,
        sharedState: SharedState,
        now: Date
    ) {
        guard recordingBackend.supportsFacebook, sharedState.realtimeFacebookBlockingEnabled else {
            facebookShieldLatched = false
            observations.reset(service: .facebook)
            ManagedSettingsApplier.clear(surface: .facebook)
            return
        }
        guard metadata?.threshold(for: .facebookReels) != nil,
              metadata?.threshold(for: .facebookStories) != nil else {
            try? IOSPauseCoordinator.setInferenceFailure(true, state: sharedState, target: "facebook")
            facebookShieldLatched = true
            applyShield(surface: .facebook)
            return
        }
        let detectedReels = reelsVerdict && observations.facebookReelsStreak >= requiredHits
        let detectedStories = storiesVerdict && observations.facebookStoriesStreak >= requiredHits
        if !ignoresDetection("facebook") {
            if !facebookShieldLatched && (detectedReels || detectedStories) {
                guard registerDetection("facebook", state: sharedState) else { return }
                facebookShieldLatched = true
                let content = detectedStories ? "stories" : "reels"
                RTLog.sampleHandler.notice(
                    "Facebook \(content, privacy: .public) detected — shielding facebook"
                )
                if detectedStories {
                    SharedStore.setLastFacebookStoriesDetectionAt(now)
                    #if DEBUG
                    if let threshold = metadata?.threshold(for: .facebookStories) {
                        queueDebugCapture(
                            kind: .facebookStories,
                            evidence: facebookStoriesEvidence,
                            threshold: threshold,
                            requiredHits: requiredHits,
                            detectedAt: now
                        )
                    }
                    #endif
                } else {
                    SharedStore.setLastFacebookReelsDetectionAt(now)
                    #if DEBUG
                    if let threshold = metadata?.threshold(for: .facebookReels) {
                        queueDebugCapture(
                            kind: .facebookReels,
                            evidence: facebookReelsEvidence,
                            threshold: threshold,
                            requiredHits: requiredHits,
                            detectedAt: now
                        )
                    }
                    #endif
                }
                publishDiagnostics(force: true)
                applyShield(surface: .facebook)
            }
        }
        if !facebookShieldLatched {
            ManagedSettingsApplier.clear(surface: .facebook)
        }
    }

    private func enforceX(verdict: Bool, requiredHits: Int, sharedState: SharedState, now: Date) {
        guard recordingBackend.supportsX, sharedState.realtimeXBlockingEnabled else {
            xShieldLatched = false
            observations.reset(service: .x)
            ManagedSettingsApplier.clear(surface: .x)
            return
        }
        guard let threshold = metadata?.threshold(for: .xReels) else {
            try? IOSPauseCoordinator.setInferenceFailure(true, state: sharedState, target: "x")
            xShieldLatched = true
            applyShield(surface: .x)
            return
        }
        if !ignoresDetection("x"), !xShieldLatched,
           verdict, observations.xReelsStreak >= requiredHits {
            guard registerDetection("x", state: sharedState) else { return }
            xShieldLatched = true
            SharedStore.setLastXReelsDetectionAt(now)
            #if DEBUG
            queueDebugCapture(kind: .xReels, evidence: xReelsEvidence, threshold: threshold,
                              requiredHits: requiredHits, detectedAt: now)
            #endif
            publishDiagnostics(force: true)
            applyShield(surface: .x)
        }
        if !xShieldLatched { ManagedSettingsApplier.clear(surface: .x) }
    }

    private func loadClassifier() {
        // Release the previous backend before allocating another model bundle.
        classifier = nil
        metadata = nil
        do {
            let loaded = try SurfaceClassifierFactory.make(backend: recordingBackend)
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
        try? IOSPauseCoordinator.setInferenceFailure(true, state: sharedState)
        if sharedState.realtimeYouTubeBlockingEnabled {
            youtubeShieldLatched = true
            applyShield(surface: .youtube)
        }
        if sharedState.realtimeInstagramBlockingEnabled {
            instagramShieldLatched = true
            applyShield(surface: .instagram)
        }
        if sharedState.realtimeFacebookBlockingEnabled {
            facebookShieldLatched = true
            applyShield(surface: .facebook)
        }
        if sharedState.realtimeXBlockingEnabled {
            xShieldLatched = true
            applyShield(surface: .x)
        }
    }

    private func startRestWatchdog() {
        stopRestWatchdog()
        let timer = DispatchSource.makeTimerSource(queue: DispatchQueue(label: "slowth.rest.watchdog", qos: .utility))
        timer.schedule(deadline: .now(), repeating: .milliseconds(250), leeway: .milliseconds(50))
        timer.setEventHandler { [weak self] in
            guard let self else { return }
            self.processingLock.lock()
            defer { self.processingLock.unlock() }
            guard self.restWatchdog != nil, SharedStore.snapshot().broadcastActive else { return }
            self.consumeUnlockRequests(at: Date())
        }
        restWatchdog = timer
        timer.resume()
    }

    private func stopRestWatchdog() {
        restWatchdog?.cancel()
        restWatchdog = nil
    }

    deinit { restWatchdog?.cancel() }

    private func ignoresDetection(_ target: String) -> Bool {
        let context = BlockingContext(activePause: recorderBindings.pausedTarget == target,
            graceActive: detectionRestGrants[target].map { $0.graceRemaining(IOSPauseCoordinator.restClock()) > 0 } ?? false)
        return BlockingRules.decide(context, .observation).resetObservations
    }

    private func consumeUnlockRequests(at now: Date) {
        // One shared read at most ten times a second, rather than opening SQLite
        // per service on every video frame. Deadlines still use continuous time.
        let continuous = IOSPauseCoordinator.restClock().continuous
        if continuous - lastRestGrantRead >= 0.1 {
            let state = SharedStore.snapshot()
            let selections = Dictionary(uniqueKeysWithValues: IOSPauseCoordinator.apps.compactMap { target in
                IOSPauseCoordinator.selection(target, state: state).map { (target, $0) }
            })
            let policy = try? IOSPauseCoordinator.recordingPolicy()
            let changed = recorderBindings.update(selections, pausedTarget: policy?.pausedTarget, revision: policy?.revision ?? -1)
            if !changed.isEmpty {
                resetStreaks()
                if changed.contains("youtube") { youtubeShieldLatched = false }
                if changed.contains("instagram") { instagramShieldLatched = false }
                if changed.contains("facebook") { facebookShieldLatched = false }
                if changed.contains("x") { xShieldLatched = false }
            }
            detectionRestGrants = IOSPauseCoordinator.restGrants()
            lastRestGrantRead = continuous
        }
        if let grant = detectionRestGrants["youtube"],
           lastHandledYouTubeUnlockAt != grant.id {
            lastHandledYouTubeUnlockAt = grant.id
            youtubeShieldLatched = false
            observations.reset(service: .youtube)
            #if DEBUG
            youtubeShortsEvidence.removeAll(keepingCapacity: true)
            #endif
            youtubeGraceUntil = now.addingTimeInterval(grant.graceRemaining(IOSPauseCoordinator.restClock()))
            ManagedSettingsApplier.clear(surface: .youtube)
            RTLog.sampleHandler.notice("YouTube shield released for navigation grace")
        }

        let sharedState = SharedStore.snapshot()
        if sharedState.realtimeInstagramBlockingEnabled,
           let grant = detectionRestGrants["instagram"],
           lastHandledInstagramUnlockAt != grant.id {
            lastHandledInstagramUnlockAt = grant.id
            instagramShieldLatched = false
            observations.reset(service: .instagram)
            #if DEBUG
            instagramReelsEvidence.removeAll(keepingCapacity: true)
            instagramStoriesEvidence.removeAll(keepingCapacity: true)
            #endif
            instagramGraceUntil = now.addingTimeInterval(grant.graceRemaining(IOSPauseCoordinator.restClock()))
            ManagedSettingsApplier.clear(surface: .instagram)
            RTLog.sampleHandler.notice("Instagram shield released for navigation grace")
        }

        if sharedState.realtimeFacebookBlockingEnabled,
           let grant = detectionRestGrants["facebook"],
           lastHandledFacebookUnlockAt != grant.id {
            lastHandledFacebookUnlockAt = grant.id
            facebookShieldLatched = false
            observations.reset(service: .facebook)
            #if DEBUG
            facebookReelsEvidence.removeAll(keepingCapacity: true)
            facebookStoriesEvidence.removeAll(keepingCapacity: true)
            #endif
            facebookGraceUntil = now.addingTimeInterval(grant.graceRemaining(IOSPauseCoordinator.restClock()))
            ManagedSettingsApplier.clear(surface: .facebook)
            RTLog.sampleHandler.notice("Facebook shield released for navigation grace")
        }
        if sharedState.realtimeXBlockingEnabled,
           let grant = detectionRestGrants["x"],
           lastHandledXUnlockAt != grant.id {
            lastHandledXUnlockAt = grant.id
            xShieldLatched = false
            observations.reset(service: .x)
            #if DEBUG
            xReelsEvidence.removeAll(keepingCapacity: true)
            #endif
            xGraceUntil = now.addingTimeInterval(grant.graceRemaining(IOSPauseCoordinator.restClock()))
            ManagedSettingsApplier.clear(surface: .x)
            RTLog.sampleHandler.notice("X shield released for navigation grace")
        }
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
            case .facebook:
                return Dictionary(uniqueKeysWithValues: FacebookContent.allCases.map { ($0.rawValue, prediction.facebookContentProbabilities[$0] ?? 0) })
            case .x:
                return Dictionary(uniqueKeysWithValues: XContent.allCases.map { ($0.rawValue, prediction.xContentProbabilities[$0] ?? 0) })
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
            youtubeShortsStreak: observations.youtubeShortsStreak,
            instagramReelsStreak: observations.instagramReelsStreak,
            instagramStoriesStreak: observations.instagramStoriesStreak,
            youtubeCandidateEvents: observations.youtubeCandidateEvents,
            instagramCandidateEvents: observations.instagramCandidateEvents,
            instagramStoriesCandidateEvents: observations.instagramStoriesCandidateEvents,
            youtubeShieldLatched: youtubeShieldLatched,
            instagramShieldLatched: instagramShieldLatched,
            youtubeGraceRemainingSeconds: youtubeGraceUntil.map { max($0.timeIntervalSince(now), 0) },
            instagramGraceRemainingSeconds: instagramGraceUntil.map { max($0.timeIntervalSince(now), 0) },
            lastClassifierError: classifierError,
            availableMemoryMB: RealtimeShieldMemory.availableMB,
            currentFootprintMB: currentFootprint,
            peakFootprintMB: peakFootprintMB > 0 ? peakFootprintMB : nil,
            updatedAt: now,
            facebookReelsStreak: observations.facebookReelsStreak,
            xReelsStreak: observations.xReelsStreak,
            facebookStoriesStreak: observations.facebookStoriesStreak,
            facebookCandidateEvents: observations.facebookCandidateEvents,
            xCandidateEvents: observations.xCandidateEvents,
            facebookStoriesCandidateEvents: observations.facebookStoriesCandidateEvents,
            facebookShieldLatched: facebookShieldLatched,
            xShieldLatched: xShieldLatched,
            facebookGraceRemainingSeconds: facebookGraceUntil.map { max($0.timeIntervalSince(now), 0) },
            xGraceRemainingSeconds: xGraceUntil.map { max($0.timeIntervalSince(now), 0) }
        )
        SharedStore.setRealtimeShieldDiagnostics(diagnostics)

        if force || now.timeIntervalSince(lastTelemetryLog) >= 10 {
            lastTelemetryLog = now
            if let timings = lastPrediction?.timings {
                let specialistMS = timings.specialistMS.map { String($0) } ?? "not_run"
                RTLog.sampleHandler.notice("cascade timings resizeMS=\(timings.resizeMS) routerMS=\(timings.routerMS) specialist=\(timings.specialist, privacy: .public) specialistMS=\(specialistMS, privacy: .public) totalMS=\(timings.totalMS)")
            }
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
        if sharedState.realtimeFacebookBlockingEnabled {
            applyShield(surface: .facebook)
        } else {
            ManagedSettingsApplier.clear(surface: .facebook)
        }
        if sharedState.realtimeXBlockingEnabled {
            applyShield(surface: .x)
        } else {
            ManagedSettingsApplier.clear(surface: .x)
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
        if surface == .facebook && (!recordingBackend.supportsFacebook || !sharedState.realtimeFacebookBlockingEnabled) {
            ManagedSettingsApplier.clear(surface: .facebook)
            return
        }

        if surface == .x && (!recordingBackend.supportsX || !sharedState.realtimeXBlockingEnabled) {
            ManagedSettingsApplier.clear(surface: .x)
            return
        }
        let data = surface == .youtube
            ? SharedStore.youtubeSelectionData()
            : surface == .x ? SharedStore.xSelectionData()
            : surface == .facebook ? SharedStore.facebookSelectionData()
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
