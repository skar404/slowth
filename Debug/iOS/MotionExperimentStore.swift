#if DEBUG && os(iOS)
import ActivityKit
import AVFoundation
import CoreMotion
import Foundation
import SwiftUI
import UIKit

@available(iOS 16.2, *)
@MainActor
final class MotionExperimentStore: ObservableObject {
    static let shared = MotionExperimentStore()
    static let labels = ["scroll", "read", "type", "walk", "still"]
    @Published private(set) var sessions: [MotionExperimentSession] = []
    @Published private(set) var samples: [MotionExperimentSample] = []
    @Published private(set) var loadedID: UUID?
    @Published private(set) var busy = false
    @Published var message = ""
    @Published var exportURL: URL?
    private var storageOK = true
    @Published private(set) var waitingForBroadcast = false
    private var startTask: Task<Void, Never>?
    private var startGeneration = 0
    private var startBackgroundTask = UIBackgroundTaskIdentifier.invalid

    private var directory: URL {
        FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("MotionExperiment", isDirectory: true)
    }
    private var manifest: URL { directory.appendingPathComponent("sessions.json") }
    private func dataURL(_ id: UUID) -> URL { directory.appendingPathComponent("\(id.uuidString).json") }

    private init() {
        do {
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
            if FileManager.default.fileExists(atPath: manifest.path) {
                sessions = try JSONDecoder().decode([MotionExperimentSession].self, from: Data(contentsOf: manifest))
            }
        } catch {
            storageOK = false
            message = "Could not read experiment history: \(error.localizedDescription)"
        }
    }

    private func save(_ next: [MotionExperimentSession]) throws {
        guard storageOK else { throw failure("Experiment history is unavailable. Restart Slowth and try again.") }
        try JSONEncoder().encode(next).write(to: manifest, options: .atomic)
        sessions = next
        exportURL = nil
    }

    private func failure(_ text: String) -> NSError {
        NSError(domain: "MotionExperiment", code: 1, userInfo: [NSLocalizedDescriptionKey: text])
    }

    var available: Bool { CMSensorRecorder.isAccelerometerRecordingAvailable() }
    var canAutomaticallyLoadMotion: Bool { available && CMSensorRecorder.authorizationStatus() == .authorized }
    var mayRequestMotion: Bool {
        let status = CMSensorRecorder.authorizationStatus()
        return status != .denied && status != .restricted
    }
    var authorization: String {
        switch CMSensorRecorder.authorizationStatus() {
        case .authorized: return "Allowed"
        case .denied: return "Denied — enable Motion & Fitness in Settings"
        case .restricted: return "Restricted by system settings"
        case .notDetermined: return "Permission requested when starting"
        @unknown default: return "Unknown"
        }
    }
    var active: MotionExperimentSession? { sessions.first { $0.endsAt > Date() } }

    func prepareLinkedStart(seconds: Int, label: String) {
        guard !waitingForBroadcast, !busy, active == nil else { return }
        if sessions.contains(where: { session in
            guard session.followsBroadcast == true, session.endsAt <= Date(), let capture = self.video(for: session.id) else { return false }
            return ["recording", "finishing"].contains(capture.state)
        }) {
            message = "The previous screen recording is still finishing. Try again in a moment."
            return
        }
        print("[MotionExperiment] Waiting for confirmed broadcast frames")
        startGeneration += 1
        let generation = startGeneration
        waitingForBroadcast = true
        message = "Confirm the system screen recording. Motion starts automatically when live frames arrive."
        startBackgroundTask = UIApplication.shared.beginBackgroundTask(withName: "Start motion with broadcast") { [weak self] in
            Task { @MainActor in self?.cancelPendingStart() }
        }
        startTask = Task {
            defer { if generation == startGeneration { finishPendingStart() } }
            let deadline = ProcessInfo.processInfo.systemUptime + 45
            while !Task.isCancelled && ProcessInfo.processInfo.systemUptime < deadline {
                if MotionVideoFiles.framesAvailable {
                    print("[MotionExperiment] Frames confirmed; starting video and motion together")
                    await start(seconds: seconds, label: label, video: true, linked: true)
                    return
                }
                try? await Task.sleep(nanoseconds: 200_000_000)
            }
            if !Task.isCancelled { message = "Screen recording was not started. No motion session was created." }
        }
    }
    func cancelPendingStart() {
        startGeneration += 1
        startTask?.cancel()
        finishPendingStart()
    }
    private func finishPendingStart() {
        waitingForBroadcast = false; startTask = nil
        if startBackgroundTask != .invalid {
            UIApplication.shared.endBackgroundTask(startBackgroundTask); startBackgroundTask = .invalid
        }
    }
    /// Import extension-owned stop time before presenting/editing a session.
    func reconcileCaptureEnds() async {
        var next = sessions
        var changed = false
        for index in next.indices where next[index].followsBroadcast == true && next[index].endedAt == nil {
            guard let manifest = MotionVideoFiles.read(MotionVideoManifest.self, at: MotionVideoFiles.manifestURL(next[index].id)) else { continue }
            let previous = next[index].endedAt
            next[index].reconcileCapture(manifest)
            changed = changed || next[index].endedAt != previous
        }
        if changed {
            do { try save(next); await reconcileActivities() }
            catch { message = "Could not save recording end: \(error.localizedDescription)" }
        }
    }

    func start(seconds: Int, label: String, video: Bool = false, linked: Bool = false) async {
        guard !busy, active == nil else { return }
        guard !video || MotionVideoFiles.framesAvailable else { message = "Start the Slowth broadcast first and wait for live frames."; return }
        guard available else { message = "Sensor recording is unavailable on this device. Use a physical iPhone."; return }
        guard Self.labels.contains(label), [60, 180, 300].contains(seconds) else { return }
        let permission = CMSensorRecorder.authorizationStatus()
        guard permission != .denied && permission != .restricted else { message = authorization; return }
        busy = true
        defer { busy = false }
        do {
            // Store the bounded request before invoking the sensor API so it survives suspension.
            let now = Date()
            let setup = linked ? 0.0 : 15.0
            let start = now.addingTimeInterval(setup)
            let session = MotionExperimentSession(id: UUID(), requestedAt: now, startsAt: start,
                scheduledEnd: start.addingTimeInterval(Double(seconds)),
                startUptime: ProcessInfo.processInfo.systemUptime + setup, recordsVideo: video, followsBroadcast: linked, markers: [
                    MotionExperimentMarker(time: start.timeIntervalSince1970, label: label)
                ])
            if video {
                guard let commandURL = MotionVideoFiles.commandURL else { throw failure("App Group unavailable") }
                try MotionVideoFiles.write(MotionVideoCommand(sessionID: session.id, startsAt: start,
                    startUptime: session.startUptime!, endUptime: session.startUptime! + Double(seconds), followsBroadcast: linked), to: commandURL)
            }
            do { try save([session] + sessions) }
            catch {
                if video, let url = MotionVideoFiles.commandURL { try? FileManager.default.removeItem(at: url) }
                throw error
            }
            samples = []
            loadedID = session.id
            await Task.detached(priority: .userInitiated) {
                CMSensorRecorder().recordAccelerometer(forDuration: Double(seconds) + setup)
            }.value
            if !mayRequestMotion {
                try await mark(sessionID: session.id.uuidString, action: "end")
                message = "Motion access was denied. The session has ended; enable Motion & Fitness in Settings to record."
                return
            }
            message = linked
                ? "Video and motion session started together. Stopping the broadcast or ending the session closes both recordings."
                : "Recording requested. Allow Motion access if prompted. Switch apps during the 15-second setup period."
            await reconcileActivities()
            if ActivityAuthorizationInfo().areActivitiesEnabled {
                do {
                    _ = try Activity<MotionExperimentAttributes>.request(
                        attributes: .init(sessionID: session.id.uuidString, startsAt: session.startsAt, endsAt: session.endsAt),
                        content: .init(state: .init(label: label), staleDate: session.endsAt), pushType: nil)
                } catch { message += " Live Activity unavailable: \(error.localizedDescription)" }
            } else { message += " Live Activities are disabled; the selected label applies to the session." }
        } catch { message = error.localizedDescription }
    }

    func mark(sessionID: String, action: String) async throws {
        guard let index = sessions.firstIndex(where: { $0.id.uuidString == sessionID }),
              sessions[index].endsAt > Date() else { await reconcileActivities(); return }
        guard action == "end" || Self.labels.contains(action) else { return }
        var next = sessions
        let now = Date()
        if action == "end" {
            next[index].endedAt = now
        } else {
            // During setup replace the initial label, avoiding future/out-of-order markers.
            let time = max(now, next[index].startsAt).timeIntervalSince1970
            next[index].markers.removeAll { $0.time >= time }
            next[index].markers.append(.init(time: time, label: action))
        }
        try save(next)
        if action == "end", var command = MotionVideoFiles.read(MotionVideoCommand.self, at: MotionVideoFiles.commandURL),
           command.sessionID.uuidString == sessionID, let url = MotionVideoFiles.commandURL {
            command.stop = true
            try MotionVideoFiles.write(command, to: url)
        }
        await reconcileActivities()
        if action == "end" {
            message = next[index].followsBroadcast == true
                ? "Stopping the screen broadcast and motion session together."
                : "Session ended. Sensor recording itself expires at the originally scheduled time; only this session's interval is imported."
        }
    }

    func reconcileActivities() async {
        for activity in Activity<MotionExperimentAttributes>.activities {
            let session = sessions.first { $0.id.uuidString == activity.attributes.sessionID }
            let ended = session == nil || session!.endsAt <= Date()
            let state = MotionExperimentAttributes.ContentState(label: session?.markers.last?.label ?? "unlabelled", ended: ended)
            if ended {
                await activity.end(.init(state: state, staleDate: nil), dismissalPolicy: .immediate)
            } else {
                await activity.update(.init(state: state, staleDate: session!.endsAt))
            }
        }
    }

    func load(_ id: UUID, fetch: Bool) async {
        guard !busy, let session = sessions.first(where: { $0.id == id }) else { return }
        busy = true
        exportURL = nil
        defer { busy = false }
        do {
            let file = dataURL(id)
            var existing: [MotionExperimentSample] = []
            if FileManager.default.fileExists(atPath: file.path) {
                existing = try JSONDecoder().decode([MotionExperimentSample].self, from: Data(contentsOf: file))
            }
            if loadedID != id { samples = []; loadedID = id }
            if fetch && session.endsAt > session.startsAt && Date() > session.startsAt {
                let end = min(session.endsAt, Date())
                let fresh: [MotionExperimentSample] = await Task.detached(priority: .userInitiated) {
                    guard let list = CMSensorRecorder().accelerometerData(from: session.startsAt, to: end) else { return [] }
                    var result: [MotionExperimentSample] = []
                    var iterator = NSFastEnumerationIterator(list)
                    while let data = iterator.next() as? CMRecordedAccelerometerData {
                        result.append(.init(time: data.startDate.timeIntervalSince1970,
                            x: data.acceleration.x, y: data.acceleration.y, z: data.acceleration.z, uptime: data.timestamp))
                    }
                    return result
                }.value
                // The system retains only three days. Preserve previously imported samples
                // if a later query is empty or partial, and deduplicate overlapping fetches.
                var merged = Dictionary(existing.map { ($0.time, $0) }, uniquingKeysWith: { _, new in new })
                for value in session.filtered(fresh) { merged[value.time] = value }
                let current = sessions.first(where: { $0.id == id }) ?? session
                existing = current.filtered(Array(merged.values))
                try JSONEncoder().encode(existing).write(to: file, options: .atomic)
            }
            samples = (sessions.first(where: { $0.id == id }) ?? session).filtered(existing)
            loadedID = id
            message = fetch
                ? "Loaded \(samples.count) samples. New samples may take up to 3 minutes to appear. Return after the session and tap Load again. Motion access: \(authorization)."
                : "Saved samples: \(samples.count). Tap Load recorded data to fetch from the sensor."
            await reconcileActivities()
        } catch { message = "Could not load data: \(error.localizedDescription)" }
    }

    func editsURL(_ id: UUID) -> URL { directory.appendingPathComponent("\(id.uuidString)-edits.json") }

    func edits(for session: MotionExperimentSession) throws -> MotionExperimentEdits {
        let url = editsURL(session.id)
        guard FileManager.default.fileExists(atPath: url.path) else {
            let migrated = MotionExperimentEdits.migrating(session)
            // Freeze IDs on first open/export. While recording, wait for the
            // final Live Activity markers before committing initial intervals.
            if session.endsAt <= Date() { try saveEdits(migrated, id: session.id) }
            return migrated
        }
        let value = try JSONDecoder().decode(MotionExperimentEdits.self, from: Data(contentsOf: url))
        guard value.version == 1 else { throw failure("Unsupported edit version") }
        return value
    }
    func saveEdits(_ value: MotionExperimentEdits, id: UUID) throws {
        try JSONEncoder().encode(value).write(to: editsURL(id), options: .atomic)
        exportURL = nil
    }
    func video(for id: UUID) -> MotionVideoManifest? {
        guard var value = MotionVideoFiles.read(MotionVideoManifest.self, at: MotionVideoFiles.manifestURL(id)) else { return nil }
        if ["recording", "finishing"].contains(value.state), !MotionVideoFiles.framesAvailable, value.updatedAt.timeIntervalSinceNow < -8 {
            value.state = "interrupted"
            value.reason = "Capture interrupted. Completed segments recovered; sensor data can still be loaded."
        }
        return value
    }
    func remove(_ id: UUID) throws {
        guard !busy, sessions.first(where: { $0.id == id })?.endsAt ?? .distantPast <= Date() else {
            throw failure("End the session before deleting it")
        }
        if let capture = video(for: id), ["recording", "finishing"].contains(capture.state) {
            throw failure("Video is still finishing. Wait a moment before deleting the session.")
        }
        // Delete payloads first so a failed removal remains visible and retryable.
        for url in [dataURL(id), editsURL(id), MotionVideoFiles.folder(id)].compactMap({ $0 }) {
            if FileManager.default.fileExists(atPath: url.path) { try FileManager.default.removeItem(at: url) }
        }
        try save(sessions.filter { $0.id != id })
        if loadedID == id { loadedID = nil; samples = [] }
    }
    func transferSource(_ id: UUID) throws -> DebugTransferSnapshot.Source {
        guard let session = sessions.first(where: { $0.id == id }), session.endsAt <= Date() else {
            throw failure("End the session before exporting")
        }
        let raw: [MotionExperimentSample]
        if loadedID == id { raw = samples }
        else if FileManager.default.fileExists(atPath: dataURL(id).path) {
            raw = try JSONDecoder().decode([MotionExperimentSample].self, from: Data(contentsOf: dataURL(id)))
        } else { raw = [] }
        let edits = try edits(for: session)
        let encoder = JSONEncoder(); encoder.outputFormatting = [.sortedKeys]; encoder.dateEncodingStrategy = .iso8601
        var metadata = ["session.json": try encoder.encode(session), "samples.json": try encoder.encode(raw),
            "edits.json": try encoder.encode(edits),
            "motion.csv": Data(MotionExperimentAnalysis.csv(session: session, samples: raw, edits: edits).utf8)]
        var files: [URL] = []
        if let video = video(for: id), let folder = MotionVideoFiles.folder(id) {
            guard !["recording", "finishing", "waiting"].contains(video.state) else { throw failure("Video is still finishing. Try again shortly.") }
            metadata["video.json"] = try encoder.encode(video)
            files = video.segments.map { folder.appendingPathComponent($0.file) }
        }
        return .motionFiles(id, metadata, files)
    }
    func export(_ id: UUID) {
        guard loadedID == id, let session = sessions.first(where: { $0.id == id }) else { return }
        do {
            let file = FileManager.default.temporaryDirectory.appendingPathComponent("motion-\(id.uuidString).csv")
            try MotionExperimentAnalysis.csv(session: session, samples: samples, edits: edits(for: session))
                .write(to: file, atomically: true, encoding: .utf8)
            exportURL = file
        } catch { message = "Could not export: \(error.localizedDescription)" }
    }
    func exportFull(_ id: UUID) async {
        do {
            let source = try transferSource(id)
            let root = FileManager.default.temporaryDirectory.appendingPathComponent("MotionExports")
            exportURL = try await Task.detached(priority: .utility) {
                let snapshot = try DebugTransferSnapshot.prepare(source, root: root)
                let folder = root.appendingPathComponent(snapshot.id)
                let destination = root.appendingPathComponent("motion-\(UUID().uuidString).zip")
                let coordinator = NSFileCoordinator()
                var coordinationError: NSError?
                var result: Result<URL, Error> = .failure(CocoaError(.fileReadUnknown))
                coordinator.coordinate(readingItemAt: folder, options: .forUploading, error: &coordinationError) { archive in
                    result = Result {
                        try FileManager.default.copyItem(at: archive, to: destination)
                        return destination
                    }
                }
                if let coordinationError { throw coordinationError }
                return try result.get()
            }.value
        } catch { message = error.localizedDescription }
    }
}
#endif
