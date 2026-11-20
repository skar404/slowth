#if DEBUG && os(iOS)
import AVFoundation
import CoreImage
import ImageIO
import ReplayKit

/// ReplayKit never waits for encoding: only one frame may be retained by this
/// recorder. Disk I/O, scaling and writer back-pressure stay on a utility queue.
final class MotionVideoRecorder {
    private let queue = DispatchQueue(label: "slowth.motion.video", qos: .utility)
    private let slot = DispatchSemaphore(value: 1)
    private let context = CIContext(options: [.cacheIntermediates: false])
    private var timer: DispatchSourceTimer?
    private var command: MotionVideoCommand?
    private var manifest: MotionVideoManifest?
    private var handled = Set<UUID>()
    private var writer: AVAssetWriter?
    private var input: AVAssetWriterInput?
    private var adaptor: AVAssetWriterInputPixelBufferAdaptor?
    private var segment: MotionVideoSegment?
    private var frameTimes: [Double] = []
    private var lastPTS = -Double.infinity
    private var lastArrival = -Double.infinity
    private var finishing = false
    private var terminalState: String?
    private var heartbeatAt = -Double.infinity
    private var paused = false
    private let stopBroadcast: () -> Void

    init(stopBroadcast: @escaping () -> Void = {}) {
        self.stopBroadcast = stopBroadcast
        let timer = DispatchSource.makeTimerSource(queue: queue)
        timer.schedule(deadline: .now(), repeating: .milliseconds(250))
        timer.setEventHandler { [weak self] in self?.poll() }
        self.timer = timer; timer.resume()
    }
    deinit { timer?.cancel() }

    func offer(_ buffer: CMSampleBuffer) {
        guard slot.wait(timeout: .now()) == .success else { return }
        let arrival = ProcessInfo.processInfo.systemUptime
        queue.async { [self] in
            defer { slot.signal() }
            autoreleasepool {
                if arrival - heartbeatAt >= 0.5 {
                    heartbeatAt = arrival
                    if let url = MotionVideoFiles.heartbeatURL {
                        try? MotionVideoFiles.write(MotionVideoHeartbeat(uptime: arrival, wallTime: Date()), to: url)
                    }
                }
                poll()
                guard !paused, !finishing, let command, manifest?.state == "recording",
                      arrival >= command.startUptime, arrival < command.endUptime else { return }
                do { try append(buffer, arrival: arrival, command: command) }
                catch { stop(reason: error.localizedDescription, cause: "capture_error") }
            }
        }
    }
    func pause() {
        queue.async { [self] in
            paused = true
            if let url = MotionVideoFiles.heartbeatURL { try? FileManager.default.removeItem(at: url) }
            closeSegment()
        }
    }
    func resume() { queue.async { [self] in paused = false } }
    func finish() {
        // ReplayKit may terminate the extension after this callback returns.
        // Give the final short segment a bounded chance to flush; earlier ones
        // are already durable and are never removed by a failed finalization.
        let done = DispatchSemaphore(value: 0)
        queue.async { [self] in
            timer?.cancel(); timer = nil
            if let url = MotionVideoFiles.heartbeatURL { try? FileManager.default.removeItem(at: url) }
            stop(reason: "Screen recording ended", cause: "broadcast_ended")
            if let writer, writer.status == .writing {
                queue.asyncAfter(deadline: .now() + 1) { done.signal() }
            } else { done.signal() }
        }
        _ = done.wait(timeout: .now() + 1.5)
    }
    private func poll() {
        let now = ProcessInfo.processInfo.systemUptime
        if let next = MotionVideoFiles.read(MotionVideoCommand.self, at: MotionVideoFiles.commandURL), next.version == 1 {
            if command?.sessionID == next.sessionID {
                if next.stop { stop(reason: "Ended by user", cause: "user") }
            } else if command == nil && !finishing && !handled.contains(next.sessionID) && !next.stop &&
                        next.endUptime > now && next.startUptime - now <= 20 &&
                        abs(next.startsAt.timeIntervalSinceNow - (next.startUptime - now)) < 5 {
                command = next
                handled.insert(next.sessionID)
                terminalState = nil
                manifest = .init(sessionID: next.sessionID, state: "recording")
                persist()
            }
        }
        if let command, now >= command.endUptime { stop(reason: nil, cause: "deadline") }
    }
    private func persist() {
        guard var value = manifest, let url = MotionVideoFiles.manifestURL(value.sessionID) else { return }
        value.updatedAt = Date(); manifest = value
        do { try MotionVideoFiles.write(value, to: url) }
        catch {
            // Stop accepting new frames if metadata cannot be made durable.
            manifest?.state = "failed"; manifest?.reason = "Cannot save video metadata: \(error.localizedDescription)"
        }
    }
    private func stop(reason: String?, cause: String) {
        guard let command else { return }
        let shouldStopBroadcast = command.followsBroadcast == true && cause != "broadcast_ended"
        manifest?.captureEndedAt = Date()
        manifest?.captureEndedUptime = ProcessInfo.processInfo.systemUptime
        manifest?.stopCause = cause
        terminalState = reason == nil ? "complete" : "stopped"
        manifest?.state = writer == nil ? terminalState! : "finishing"
        manifest?.reason = reason
        self.command = nil
        closeSegment()
        persist()
        if shouldStopBroadcast {
            // Never invoke the handler synchronously on the encoder queue:
            // its final flush must be able to enqueue work here.
            DispatchQueue.global(qos: .utility).async { [stopBroadcast] in stopBroadcast() }
        }
    }
    private func append(_ buffer: CMSampleBuffer, arrival: Double, command: MotionVideoCommand) throws {
        guard let pixels = CMSampleBufferGetImageBuffer(buffer) else { return }
        let pts = CMSampleBufferGetPresentationTimeStamp(buffer).seconds
        guard pts.isFinite else { return }
        let raw = (CMGetAttachment(buffer, key: RPVideoSampleOrientationKey as CFString, attachmentModeOut: nil) as? NSNumber)?.uint32Value ?? 1
        let orientation = CGImagePropertyOrientation(rawValue: raw) ?? .up
        let source = CIImage(cvPixelBuffer: pixels).oriented(orientation)
        let scale = min(1, 1280 / max(source.extent.width, source.extent.height))
        let width = max(2, Int(source.extent.width * scale) / 2 * 2)
        let height = max(2, Int(source.extent.height * scale) / 2 * 2)
        if let segment, (pts - segment.firstPTS >= 4 || segment.orientation != raw ||
            segment.width != width || segment.height != height || pts <= lastPTS ||
            pts - lastPTS > 0.25 || arrival - lastArrival > 0.25 ||
            abs((pts - segment.firstPTS) - (arrival - segment.firstUptime)) > 0.15) {
            closeSegment(); return
        }
        if pts - lastPTS < 1.0 / 30.0 { return }
        if writer == nil {
            guard let folder = MotionVideoFiles.folder(command.sessionID) else { throw error("App Group unavailable") }
            try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
            let capacity = try folder.resourceValues(forKeys: [.volumeAvailableCapacityForImportantUsageKey]).volumeAvailableCapacityForImportantUsage ?? 0
            guard capacity > 80 * 1024 * 1024 else { throw error("Low storage — completed video segments preserved") }
            let name = "segment-\(UUID().uuidString).mov"
            let writer = try AVAssetWriter(outputURL: folder.appendingPathComponent(name), fileType: .mov)
            writer.movieFragmentInterval = CMTime(seconds: 1, preferredTimescale: 600)
            let input = AVAssetWriterInput(mediaType: .video, outputSettings: [
                AVVideoCodecKey: AVVideoCodecType.h264, AVVideoWidthKey: width, AVVideoHeightKey: height,
                AVVideoCompressionPropertiesKey: [AVVideoAverageBitRateKey: 2_000_000,
                    AVVideoMaxKeyFrameIntervalKey: 30, AVVideoAllowFrameReorderingKey: false]])
            input.expectsMediaDataInRealTime = true
            guard writer.canAdd(input) else { throw error("H.264 encoder unavailable") }
            writer.add(input)
            let adaptor = AVAssetWriterInputPixelBufferAdaptor(assetWriterInput: input,
                sourcePixelBufferAttributes: [kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA,
                    kCVPixelBufferWidthKey as String: width, kCVPixelBufferHeightKey as String: height,
                    kCVPixelBufferIOSurfacePropertiesKey as String: [:]])
            guard writer.startWriting() else { throw writer.error ?? error("Could not start video") }
            writer.startSession(atSourceTime: .zero)
            self.writer = writer; self.input = input; self.adaptor = adaptor
            segment = .init(file: name, start: arrival - command.startUptime, duration: 0,
                firstPTS: pts, firstUptime: arrival, orientation: raw, width: width, height: height, frameTimes: [])
            frameTimes = []; lastPTS = -Double.infinity
        }
        guard let input, let adaptor, let segment, let pool = adaptor.pixelBufferPool else { return }
        guard input.isReadyForMoreMediaData else {
            manifest?.droppedFrames += 1
            if writer?.status == .failed { throw writer?.error ?? error("Video encoder failed") }
            return
        }
        var output: CVPixelBuffer?
        guard CVPixelBufferPoolCreatePixelBuffer(nil, pool, &output) == kCVReturnSuccess, let output else {
            throw error("Video buffer allocation failed")
        }
        let image = source.transformed(by: CGAffineTransform(translationX: -source.extent.minX, y: -source.extent.minY))
            .transformed(by: CGAffineTransform(scaleX: CGFloat(width) / source.extent.width, y: CGFloat(height) / source.extent.height))
        context.render(image, to: output)
        let local = pts - segment.firstPTS
        guard adaptor.append(output, withPresentationTime: CMTime(seconds: local, preferredTimescale: 60000)) else {
            throw writer?.error ?? error("Could not append video frame")
        }
        frameTimes.append(local); lastPTS = pts; lastArrival = arrival
    }
    private func closeSegment() {
        guard !finishing, let writer, let segment else { return }
        guard writer.status == .writing else {
            manifest?.state = "failed"
            manifest?.reason = writer.error?.localizedDescription ?? "Video encoder stopped"
            self.writer = nil; input = nil; adaptor = nil; self.segment = nil
            persist()
            return
        }
        finishing = true
        let times = frameTimes
        input?.markAsFinished()
        writer.endSession(atSourceTime: CMTime(seconds: (times.last ?? 0) + 1.0 / 30, preferredTimescale: 60000))
        writer.finishWriting { [self] in
            queue.async { [self] in
                if writer.status == .completed && !times.isEmpty {
                    manifest?.segments.append(.init(file: segment.file, start: segment.start,
                        duration: (times.last ?? 0) + 1.0 / 30, firstPTS: segment.firstPTS,
                        firstUptime: segment.firstUptime, orientation: segment.orientation,
                        width: segment.width, height: segment.height, frameTimes: times))
                } else {
                    manifest?.state = "failed"; manifest?.reason = writer.error?.localizedDescription ?? "Interrupted video segment"
                    command = nil
                }
                self.writer = nil; input = nil; adaptor = nil; self.segment = nil
                if manifest?.state == "finishing", let terminalState { manifest?.state = terminalState }
                finishing = false; lastPTS = -Double.infinity; lastArrival = -Double.infinity
                persist()
            }
        }
    }
    private func error(_ message: String) -> NSError {
        NSError(domain: "MotionVideo", code: 1, userInfo: [NSLocalizedDescriptionKey: message])
    }
}
#endif
