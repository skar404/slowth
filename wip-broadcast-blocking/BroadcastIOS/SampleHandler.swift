import Foundation
import ReplayKit
#if canImport(FamilyControls)
import FamilyControls
#endif

final class SampleHandler: RPBroadcastSampleHandler {
    private var frameCounter = 0
    private var lastDetectionAt = Date.distantPast

    override func broadcastStarted(withSetupInfo setupInfo: [String: NSObject]?) {
        SharedStore.setBroadcastActive(true)
    }

    override func broadcastFinished() {
        SharedStore.setBroadcastActive(false)
        ManagedSettingsApplier.clear()
    }

    override func processSampleBuffer(_ sampleBuffer: CMSampleBuffer, with sampleBufferType: RPSampleBufferType) {
        guard sampleBufferType == .video else { return }

        frameCounter += 1
        guard frameCounter % ShortsHeuristics.sampleEveryNFrames == 0 else { return }
        guard SharedStore.snapshot().broadcastBlockingEnabled else { return }

        guard let pixelBuffer = CMSampleBufferGetImageBuffer(sampleBuffer) else { return }
        guard ShortsHeuristics.looksLikeShorts(pixelBuffer) else { return }

        let now = Date()
        guard now.timeIntervalSince(lastDetectionAt) > ShortsHeuristics.minRedetectionInterval else { return }
        lastDetectionAt = now

        SharedStore.setLastShortsDetectionAt(now)
        applyShield()
    }

    private func applyShield() {
        #if canImport(FamilyControls)
        guard let data = SharedStore.youtubeActivitySelectionData(),
              let selection = try? JSONDecoder().decode(FamilyActivitySelection.self, from: data) else { return }
        ManagedSettingsApplier.apply(selection: selection)
        #endif
    }
}
