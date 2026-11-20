#if DEBUG && os(iOS)
import AVFoundation
import SwiftUI

@MainActor
final class MotionExperimentPlayer: ObservableObject {
    let player = AVPlayer()
    @Published var position = 0.0
    @Published var playing = false
    @Published var thumbnails: [Int: UIImage] = [:]
    @Published var message = ""
    var rate: Float = 1
    var trim = MotionTimeRange(start: 0, end: 1)
    private var timer: Timer?
    private var video: MotionVideoManifest?
    private var offset = 0.0
    private var thumbnailTask: Task<Void, Never>?
    private var composition: AVMutableComposition?
    private var videoComposition: AVMutableVideoComposition?
    private var previousTick = ProcessInfo.processInfo.systemUptime
    private var hasVideo = false

    func configure(session: MotionExperimentSession, video: MotionVideoManifest?, edits: MotionExperimentEdits) async {
        pause(); thumbnailTask?.cancel(); self.video = video; offset = edits.videoOffset; trim = edits.trim
        player.replaceCurrentItem(with: nil); composition = nil; videoComposition = nil; hasVideo = false
        do {
            if let video, !video.segments.isEmpty, let folder = MotionVideoFiles.folder(session.id) {
                let built = try await Self.compose(video, folder: folder, duration: session.duration, offset: edits.videoOffset)
                composition = built.0; videoComposition = built.1
                let item = AVPlayerItem(asset: built.0); item.videoComposition = built.1
                player.replaceCurrentItem(with: item); hasVideo = true
                thumbnailTask = Task { await makeThumbnails(asset: built.0, videoComposition: built.1, duration: session.duration) }
            }
        } catch { message = "Video could not be opened: \(error.localizedDescription)" }
        seek(position)
        if timer == nil {
            timer = Timer.scheduledTimer(withTimeInterval: 0.05, repeats: true) { [weak self] _ in
                Task { @MainActor in self?.tick() }
            }
        }
    }
    func close() { pause(); timer?.invalidate(); timer = nil; thumbnailTask?.cancel(); player.replaceCurrentItem(with: nil) }
    func seek(_ second: Double) {
        position = min(max(trim.start, second), trim.end)
        player.seek(to: CMTime(seconds: position, preferredTimescale: 60000), toleranceBefore: .zero, toleranceAfter: .zero)
    }
    func toggle() {
        if playing { pause(); return }
        if position >= trim.end - 0.01 { seek(trim.start) }
        previousTick = ProcessInfo.processInfo.systemUptime
        playing = true
        if hasVideo { player.playImmediately(atRate: rate) }
    }
    func pause() { playing = false; player.pause() }
    func setRate(_ value: Float) { rate = value; if playing && hasVideo { player.rate = value } }
    func step(_ direction: Int) {
        pause()
        let times = video?.segments.flatMap { segment in segment.frameTimes.map { segment.start + offset + $0 } }.sorted() ?? []
        let next = direction > 0 ? times.first(where: { $0 > position + 0.00001 }) : times.last(where: { $0 < position - 0.00001 })
        seek(next ?? (position + Double(direction) / 30))
    }
    private func tick() {
        let now = ProcessInfo.processInfo.systemUptime
        defer { previousTick = now }
        guard playing else { return }
        let time = hasVideo ? player.currentTime().seconds : position + (now - previousTick) * Double(rate)
        guard time.isFinite else { return }
        position = min(trim.end, max(trim.start, time))
        if position >= trim.end - 0.01 { pause() }
    }
    private func makeThumbnails(asset: AVAsset, videoComposition: AVVideoComposition, duration: Double) async {
        thumbnails = [:]
        let generator = AVAssetImageGenerator(asset: asset)
        generator.videoComposition = videoComposition; generator.maximumSize = CGSize(width: 100, height: 100)
        generator.requestedTimeToleranceBefore = .zero; generator.requestedTimeToleranceAfter = .zero
        for second in stride(from: 0, through: Int(duration), by: 5) {
            guard !Task.isCancelled else { return }
            guard video?.segment(at: Double(second), offset: offset) != nil else { continue }
            if let result = try? await generator.image(at: CMTime(seconds: Double(second), preferredTimescale: 600)) {
                guard !Task.isCancelled else { return }
                thumbnails[second] = UIImage(cgImage: result.image)
            }
        }
    }
    func exportClip() async throws -> URL {
        guard let composition, let videoComposition, trim.end > trim.start,
              let export = AVAssetExportSession(asset: composition, presetName: AVAssetExportPresetHighestQuality) else {
            throw NSError(domain: "MotionVideo", code: 2, userInfo: [NSLocalizedDescriptionKey: "No video in this session"])
        }
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("motion-clip-\(UUID().uuidString).mp4")
        export.outputURL = url; export.outputFileType = .mp4; export.videoComposition = videoComposition
        export.timeRange = CMTimeRange(start: CMTime(seconds: trim.start, preferredTimescale: 60000),
                                      duration: CMTime(seconds: trim.end - trim.start, preferredTimescale: 60000))
        await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
            export.exportAsynchronously { continuation.resume() }
        }
        guard export.status == .completed else {
            try? FileManager.default.removeItem(at: url)
            throw export.error ?? NSError(domain: "MotionVideo", code: 3)
        }
        return url
    }
    /// Insert explicit empty ranges, never concatenate away missing video.
    static func compose(_ video: MotionVideoManifest, folder: URL, duration: Double, offset: Double) async throws
        -> (AVMutableComposition, AVMutableVideoComposition) {
        let composition = AVMutableComposition()
        guard let track = composition.addMutableTrack(withMediaType: .video, preferredTrackID: kCMPersistentTrackID_Invalid) else {
            throw NSError(domain: "MotionVideo", code: 4)
        }
        let size = CGSize(width: 720, height: 1280)
        var instructions: [AVMutableVideoCompositionInstruction] = []
        var cursor = 0.0
        func time(_ value: Double) -> CMTime { CMTime(seconds: value, preferredTimescale: 60000) }
        func gap(to end: Double) {
            guard end > cursor else { return }
            let range = CMTimeRange(start: time(cursor), end: time(end))
            composition.insertEmptyTimeRange(range)
            let instruction = AVMutableVideoCompositionInstruction()
            instruction.timeRange = range; instruction.layerInstructions = []; instruction.backgroundColor = UIColor.black.cgColor
            instructions.append(instruction); cursor = end
        }
        for segment in video.segments.sorted(by: { $0.start < $1.start }) {
            let asset = AVURLAsset(url: folder.appendingPathComponent(segment.file))
            guard let source = try await asset.loadTracks(withMediaType: .video).first else { continue }
            let assetDuration = try await asset.load(.duration).seconds
            let start = max(cursor, max(0, segment.start + offset))
            let end = min(duration, segment.start + offset + min(segment.duration, assetDuration))
            guard end > start else { continue }
            gap(to: start)
            let local = start - segment.start - offset
            try track.insertTimeRange(CMTimeRange(start: time(local), duration: time(end - start)), of: source, at: time(start))
            let instruction = AVMutableVideoCompositionInstruction()
            instruction.timeRange = CMTimeRange(start: time(start), end: time(end))
            instruction.backgroundColor = UIColor.black.cgColor
            let layer = AVMutableVideoCompositionLayerInstruction(assetTrack: track)
            let scale = min(size.width / CGFloat(segment.width), size.height / CGFloat(segment.height))
            let transform = CGAffineTransform(scaleX: scale, y: scale).concatenating(CGAffineTransform(
                translationX: (size.width - CGFloat(segment.width) * scale) / 2,
                y: (size.height - CGFloat(segment.height) * scale) / 2))
            layer.setTransform(transform, at: time(start)); instruction.layerInstructions = [layer]
            instructions.append(instruction); cursor = end
        }
        gap(to: duration)
        let output = AVMutableVideoComposition()
        output.renderSize = size; output.frameDuration = CMTime(value: 1, timescale: 30); output.instructions = instructions
        return (composition, output)
    }
}
#endif
