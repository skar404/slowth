#if DEBUG
import CoreGraphics
import Foundation
import ImageIO
import UniformTypeIdentifiers

struct DebugCaptureFramePixels {
    let capturedAt: Date
    let inferenceIndex: Int
    let probability: Double
    let appProbabilities: [String: Double]
    let contentProbabilities: [String: Double]
    let jointProbabilities: [String: Double]
    let data: Data
    let width: Int
    let height: Int
    let bytesPerRow: Int
}

struct DebugCaptureEvent {
    let eventID: UUID
    let broadcastSessionID: UUID
    let kind: DebugCaptureKind
    let detectedAt: Date
    let modelVersion: String
    let threshold: Double
    let requiredHits: Int
    let observationWindowFrames: Int
    let frames: [DebugCaptureFramePixels]
}

enum DebugCaptureWriter {
    private static let queue = DispatchQueue(
        label: "com.slowth.realtimeshield.debug-capture",
        qos: .utility
    )

    static func enqueue(_ event: DebugCaptureEvent) {
        guard DebugCaptureSettings.isEnabled, !event.frames.isEmpty else { return }
        queue.async {
            do {
                try write(event)
                DebugCaptureFileStore.setLastError(nil)
                RTLog.sampleHandler.notice(
                    "Debug capture queued — kind=\(event.kind.rawValue, privacy: .public) frames=\(event.frames.count)"
                )
            } catch {
                DebugCaptureFileStore.setLastError(error.localizedDescription)
                RTLog.sampleHandler.error(
                    "Debug capture failed — \(error.localizedDescription, privacy: .public)"
                )
            }
        }
    }

    private static func write(_ event: DebugCaptureEvent) throws {
        try DebugCaptureFileStore.prepareDirectories()
        guard let stagingDirectory = DebugCaptureFileStore.stagingDirectory,
              let pendingDirectory = DebugCaptureFileStore.pendingDirectory else {
            throw CocoaError(.fileNoSuchFile)
        }

        let eventName = event.eventID.uuidString.lowercased()
        let stagingURL = stagingDirectory.appendingPathComponent(eventName, isDirectory: true)
        let destinationURL = pendingDirectory.appendingPathComponent(eventName, isDirectory: true)
        let manager = FileManager.default
        if manager.fileExists(atPath: stagingURL.path) {
            try manager.removeItem(at: stagingURL)
        }
        try manager.createDirectory(at: stagingURL, withIntermediateDirectories: true)

        do {
            let timestamp = Self.filenameTimestamp.string(from: event.detectedAt)
            var frameManifests: [DebugCaptureFrameManifest] = []
            for (offset, frame) in event.frames.enumerated() {
                let filename = "slowth_\(event.kind.rawValue)_\(timestamp)_\(offset + 1).jpg"
                try writeJPEG(
                    frame,
                    to: stagingURL.appendingPathComponent(filename)
                )
                frameManifests.append(DebugCaptureFrameManifest(
                    filename: filename,
                    capturedAt: frame.capturedAt,
                    inferenceIndex: frame.inferenceIndex,
                    probability: frame.probability,
                    appProbabilities: frame.appProbabilities,
                    contentProbabilities: frame.contentProbabilities,
                    jointProbabilities: frame.jointProbabilities,
                    width: frame.width,
                    height: frame.height
                ))
            }

            let manifest = DebugCaptureManifest(
                formatVersion: DebugCaptureManifest.currentFormatVersion,
                eventID: event.eventID,
                broadcastSessionID: event.broadcastSessionID,
                kind: event.kind,
                detectedAt: event.detectedAt,
                modelVersion: event.modelVersion,
                threshold: event.threshold,
                requiredHits: event.requiredHits,
                observationWindowFrames: event.observationWindowFrames,
                frames: frameManifests
            )
            let encoder = JSONEncoder()
            encoder.dateEncodingStrategy = .iso8601
            encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
            try encoder.encode(manifest).write(
                to: stagingURL.appendingPathComponent("manifest.json"),
                options: .atomic
            )
            try manager.moveItem(at: stagingURL, to: destinationURL)
            DebugCaptureFileStore.prunePending()
        } catch {
            try? manager.removeItem(at: stagingURL)
            throw error
        }
    }

    private static func writeJPEG(_ frame: DebugCaptureFramePixels, to url: URL) throws {
        guard frame.data.count >= frame.bytesPerRow * frame.height,
              let provider = CGDataProvider(data: frame.data as CFData) else {
            throw CocoaError(.fileWriteUnknown)
        }
        let bitmapInfo = CGBitmapInfo.byteOrder32Little.union(
            CGBitmapInfo(rawValue: CGImageAlphaInfo.premultipliedFirst.rawValue)
        )
        guard let image = CGImage(
            width: frame.width,
            height: frame.height,
            bitsPerComponent: 8,
            bitsPerPixel: 32,
            bytesPerRow: frame.bytesPerRow,
            space: CGColorSpaceCreateDeviceRGB(),
            bitmapInfo: bitmapInfo,
            provider: provider,
            decode: nil,
            shouldInterpolate: true,
            intent: .defaultIntent
        ), let destination = CGImageDestinationCreateWithURL(
            url as CFURL,
            UTType.jpeg.identifier as CFString,
            1,
            nil
        ) else {
            throw CocoaError(.fileWriteUnknown)
        }
        CGImageDestinationAddImage(
            destination,
            image,
            [kCGImageDestinationLossyCompressionQuality: 0.86] as CFDictionary
        )
        guard CGImageDestinationFinalize(destination) else {
            throw CocoaError(.fileWriteUnknown)
        }
    }

    private static let filenameTimestamp: DateFormatter = {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = TimeZone(secondsFromGMT: 0)
        formatter.dateFormat = "yyyyMMdd_HHmmss_SSS"
        return formatter
    }()
}
#endif
