import Foundation

enum DebugCaptureSettings {
    static let storageKey = "debugCapture.enabled"
    static let savedEventCountStorageKey = "debugCapture.savedEventCount"
    static let lastErrorStorageKey = "debugCapture.lastError"

    static var isEnabled: Bool {
        DebugMode.isEnabled && AppGroup.defaults.bool(forKey: storageKey)
    }

    static func disable() {
        AppGroup.defaults.set(false, forKey: storageKey)
    }
}

enum DebugCaptureKind: String, Codable, CaseIterable {
    case youtubeShorts = "youtube_shorts"
    case instagramReels = "instagram_reels"
    case instagramStories = "instagram_stories"

    static let folderTitle = "Slowth — Triggers"

    var albumTitle: String {
        switch self {
        case .youtubeShorts: return "YouTube Shorts"
        case .instagramReels: return "Instagram Reels"
        case .instagramStories: return "Instagram Stories"
        }
    }
}

struct DebugCaptureFrameManifest: Codable {
    let filename: String
    let capturedAt: Date
    let inferenceIndex: Int
    let probability: Double
    let appProbabilities: [String: Double]
    let contentProbabilities: [String: Double]
    let jointProbabilities: [String: Double]
    let width: Int
    let height: Int
}

struct DebugCaptureManifest: Codable {
    static let currentFormatVersion = 1

    let formatVersion: Int
    let eventID: UUID
    let broadcastSessionID: UUID
    let kind: DebugCaptureKind
    let detectedAt: Date
    let modelVersion: String
    let threshold: Double
    let requiredHits: Int
    let observationWindowFrames: Int
    let frames: [DebugCaptureFrameManifest]
}

enum DebugCaptureFileStore {
    static let maximumPendingEvents = 200
    static let maximumPendingBytes: Int64 = 500 * 1_024 * 1_024
    static let maximumHistoryEvents = 500

    static var rootDirectory: URL? {
        FileManager.default
            .containerURL(forSecurityApplicationGroupIdentifier: AppGroup.identifier)?
            .appendingPathComponent("RealtimeShieldCaptures", isDirectory: true)
    }

    static var pendingDirectory: URL? {
        rootDirectory?.appendingPathComponent("pending", isDirectory: true)
    }

    static var stagingDirectory: URL? {
        rootDirectory?.appendingPathComponent("staging", isDirectory: true)
    }

    static var historyDirectory: URL? {
        rootDirectory?.appendingPathComponent("history", isDirectory: true)
    }

    static func prepareDirectories() throws {
        guard let rootDirectory, let pendingDirectory, let stagingDirectory,
              let historyDirectory else {
            throw CocoaError(.fileNoSuchFile)
        }
        for directory in [rootDirectory, pendingDirectory, stagingDirectory, historyDirectory] {
            try FileManager.default.createDirectory(
                at: directory,
                withIntermediateDirectories: true
            )
        }
    }

    static func pendingEventDirectories() -> [URL] {
        guard let pendingDirectory else { return [] }
        let keys: Set<URLResourceKey> = [.isDirectoryKey, .creationDateKey]
        let urls = (try? FileManager.default.contentsOfDirectory(
            at: pendingDirectory,
            includingPropertiesForKeys: Array(keys),
            options: [.skipsHiddenFiles]
        )) ?? []
        return urls.filter {
            (try? $0.resourceValues(forKeys: keys).isDirectory) == true
        }.sorted {
            let lhs = (try? $0.resourceValues(forKeys: keys).creationDate) ?? .distantPast
            let rhs = (try? $1.resourceValues(forKeys: keys).creationDate) ?? .distantPast
            return lhs < rhs
        }
    }

    static func pendingBytes() -> Int64 {
        pendingEventDirectories().reduce(0) { $0 + directoryBytes($1) }
    }

    static func clearPending() throws {
        guard let pendingDirectory, let stagingDirectory else {
            throw CocoaError(.fileNoSuchFile)
        }
        let manager = FileManager.default
        for directory in [pendingDirectory, stagingDirectory] {
            if manager.fileExists(atPath: directory.path) {
                try manager.removeItem(at: directory)
            }
            try manager.createDirectory(at: directory, withIntermediateDirectories: true)
        }
    }

    static func prunePending() {
        var directories = pendingEventDirectories()
        var totalBytes = directories.reduce(0) { $0 + directoryBytes($1) }
        while directories.count > maximumPendingEvents || totalBytes > maximumPendingBytes {
            let oldest = directories.removeFirst()
            totalBytes -= directoryBytes(oldest)
            try? FileManager.default.removeItem(at: oldest)
        }
    }

    static func archiveManifest(from eventDirectory: URL) {
        guard let historyDirectory else { return }
        let source = eventDirectory.appendingPathComponent("manifest.json")
        let destination = historyDirectory.appendingPathComponent(
            "\(eventDirectory.lastPathComponent).json"
        )
        do {
            try prepareDirectories()
            if FileManager.default.fileExists(atPath: destination.path) {
                try FileManager.default.removeItem(at: destination)
            }
            try FileManager.default.copyItem(at: source, to: destination)
            pruneHistory()
        } catch {
            // Photo export has already succeeded. A history-copy failure must not
            // leave the JPEG event queued and cause duplicate Photos assets.
        }
    }

    static func setLastError(_ message: String?) {
        if let message, !message.isEmpty {
            AppGroup.defaults.set(message, forKey: DebugCaptureSettings.lastErrorStorageKey)
        } else {
            AppGroup.defaults.removeObject(forKey: DebugCaptureSettings.lastErrorStorageKey)
        }
    }

    private static func directoryBytes(_ directory: URL) -> Int64 {
        guard let enumerator = FileManager.default.enumerator(
            at: directory,
            includingPropertiesForKeys: [.isRegularFileKey, .fileSizeKey],
            options: [.skipsHiddenFiles]
        ) else { return 0 }
        var result: Int64 = 0
        for case let url as URL in enumerator {
            guard let values = try? url.resourceValues(forKeys: [.isRegularFileKey, .fileSizeKey]),
                  values.isRegularFile == true else { continue }
            result += Int64(values.fileSize ?? 0)
        }
        return result
    }

    private static func pruneHistory() {
        guard let historyDirectory else { return }
        let keys: Set<URLResourceKey> = [.isRegularFileKey, .creationDateKey]
        var files = ((try? FileManager.default.contentsOfDirectory(
            at: historyDirectory,
            includingPropertiesForKeys: Array(keys),
            options: [.skipsHiddenFiles]
        )) ?? []).filter {
            (try? $0.resourceValues(forKeys: keys).isRegularFile) == true
        }.sorted {
            let lhs = (try? $0.resourceValues(forKeys: keys).creationDate) ?? .distantPast
            let rhs = (try? $1.resourceValues(forKeys: keys).creationDate) ?? .distantPast
            return lhs < rhs
        }
        while files.count > maximumHistoryEvents {
            try? FileManager.default.removeItem(at: files.removeFirst())
        }
    }
}
