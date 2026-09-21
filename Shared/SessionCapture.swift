#if DEBUG
import Foundation

/// Independent debug evidence, never a source of blocking decisions or ground truth.
final class SessionCapture {
    struct Limits {
        var duration: Double = 15 * 60
        var sessionBytes = 250 * 1_024 * 1_024
        var totalBytes = 1_024 * 1_024 * 1_024
        var minimumFreeBytes: Int64 = 256 * 1_024 * 1_024
    }
    struct Frame: Codable {
        var filename = ""
        var capturedAt = Date()
        let ptsValue: Int64
        let ptsTimescale: Int32
        let ptsEpoch: Int64
        let ptsFlags: UInt32
        let orientation: UInt32?
        let width: Int
        let height: Int
        let modelVersion: String?
        let predictions: [String: Double]?
    }

    struct Event: Codable {
        let kind: String
        let at: Date
    }

    struct Manifest: Codable {
        var formatVersion = 1
        let sessionID: UUID
        let startedAt: Date
        let intervalSeconds: Double
        var status = "active"
        var endedAt: Date?
        var frames: [Frame] = []
        var droppedFrames = 0
        var jpegBytes = 0
        var error: String?
        var events: [Event] = []
    }

    private let queue = DispatchQueue(label: "com.slowth.session-capture", qos: .utility)
    private let directory: URL
    private var manifest: Manifest
    private let lock = NSLock()
    private let interval: Double
    private var nextUptime: Double
    private var busy = false
    private var closed = false
    private var paused = false
    private var dropped = 0
    private let startedUptime: Double
    private let limits: Limits
    private let freeBytes: () throws -> Int64
    private var existingBytes = 0
    // Reserve space for atomic manifest replacement and JSON growth.
    private static let manifestReserve = 8 * 1_024 * 1_024

    init(root: URL, sessionID: UUID, interval: Double, startedUptime: Double,
         limits: Limits = Limits(), freeBytes: (() throws -> Int64)? = nil) {
        directory = root.appendingPathComponent(sessionID.uuidString.lowercased(), isDirectory: true)
        self.interval = interval == 0.5 ? 0.5 : 1
        self.startedUptime = startedUptime
        self.limits = limits
        self.freeBytes = freeBytes ?? {
            let attributes = try FileManager.default.attributesOfFileSystem(forPath: root.path)
            guard let bytes = attributes[.systemFreeSize] as? NSNumber else { throw CocoaError(.fileReadUnknown) }
            return bytes.int64Value
        }
        nextUptime = startedUptime
        manifest = Manifest(sessionID: sessionID, startedAt: Date(), intervalSeconds: self.interval)
        queue.async {
            do {
                try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
                var protectedRoot = root
                var resources = URLResourceValues()
                resources.isExcludedFromBackup = true
                try protectedRoot.setResourceValues(resources)
                self.existingBytes = try Self.bytes(in: root)
                try FileManager.default.createDirectory(at: self.directory, withIntermediateDirectories: false)
                try self.persist()
            } catch { self.stopOnWorker(reason: "error", error: error) }
        }
    }

    @discardableResult
    func offer(_ frame: Frame, uptime: Double, jpeg: @escaping () throws -> Data) -> Bool {
        lock.lock()
        defer { lock.unlock() }
        guard !closed, !paused, uptime.isFinite, uptime >= nextUptime else { return false }
        if uptime - startedUptime >= limits.duration {
            closed = true
            queue.async { self.stopOnWorker(reason: "duration_limit") }
            return false
        }
        nextUptime = uptime + interval
        guard !busy else { dropped += 1; return false }
        busy = true
        queue.async {
            defer {
                self.lock.lock()
                self.busy = false
                self.lock.unlock()
            }
            do {
                guard self.manifest.status == "active" else { return }
                if try self.freeBytes() < self.limits.minimumFreeBytes + Int64(Self.manifestReserve) {
                    self.stopOnWorker(reason: "low_disk")
                    return
                }
                var frame = frame
                frame.filename = String(format: "frame_%06d.jpg", self.manifest.frames.count + 1)
                let data = try jpeg()
                let budget = self.manifest.jpegBytes + data.count + Self.manifestReserve
                if budget > self.limits.sessionBytes {
                    self.stopOnWorker(reason: "session_disk_limit")
                    return
                }
                if self.existingBytes + budget > self.limits.totalBytes {
                    self.stopOnWorker(reason: "total_disk_limit")
                    return
                }
                if try self.freeBytes() < self.limits.minimumFreeBytes + Int64(data.count + Self.manifestReserve) {
                    self.stopOnWorker(reason: "low_disk")
                    return
                }
                try data.write(to: self.directory.appendingPathComponent(frame.filename), options: .atomic)
                self.manifest.frames.append(frame)
                self.manifest.jpegBytes += data.count
                try self.persist()
            } catch {
                self.stopOnWorker(reason: "error", error: error)
            }
        }
        return true
    }

    func pause() { setPaused(true) }
    func resume() { setPaused(false) }

    private func setPaused(_ value: Bool) {
        lock.lock()
        defer { lock.unlock() }
        guard !closed, paused != value else { return }
        paused = value
        let at = Date()
        queue.async {
            guard self.manifest.status == "active" || self.manifest.status == "paused" else { return }
            self.manifest.status = value ? "paused" : "active"
            self.manifest.events.append(Event(kind: value ? "paused" : "resumed", at: at))
            do { try self.persist() } catch { self.stopOnWorker(reason: "error", error: error) }
        }
    }

    func finish(reason: String) {
        lock.lock()
        defer { lock.unlock() }
        guard !closed else { return }
        closed = true
        queue.async {
            guard self.manifest.status == "active" || self.manifest.status == "paused" else { return }
            self.manifest.status = reason
            self.manifest.endedAt = Date()
            try? self.persist()
        }
    }

    /// Tests only; ReplayKit callbacks must never wait for disk/encoding.
    func drain() { queue.sync {} }

    private func stopOnWorker(reason: String, error: Error? = nil) {
        lock.lock()
        closed = true
        lock.unlock()
        manifest.status = reason
        manifest.error = error?.localizedDescription
        manifest.endedAt = Date()
        try? persist()
    }

    private static func bytes(in root: URL) throws -> Int {
        guard let files = FileManager.default.enumerator(at: root,
            includingPropertiesForKeys: [.fileSizeKey, .isRegularFileKey]) else { throw CocoaError(.fileReadUnknown) }
        var total = 0
        for case let url as URL in files {
            let values = try url.resourceValues(forKeys: [.fileSizeKey, .isRegularFileKey])
            if values.isRegularFile == true { total += values.fileSize ?? 0 }
        }
        return total
    }

    private func persist() throws {
        lock.lock()
        manifest.droppedFrames = dropped
        lock.unlock()
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        try encoder.encode(manifest).write(to: directory.appendingPathComponent("session.json"), options: .atomic)
    }
}
#endif
