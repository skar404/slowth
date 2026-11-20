#if DEBUG
import Foundation

/// Relative times use the end of setup as zero. Every segment keeps both clocks;
/// gaps remain on the session axis, including ReplayKit pauses and dropped frames.
struct MotionVideoSegment: Codable, Equatable, Identifiable, Sendable {
    var id: String { file }
    let file: String
    let start: Double
    let duration: Double
    let firstPTS: Double
    let firstUptime: Double
    let orientation: UInt32
    let width: Int
    let height: Int
    let frameTimes: [Double]
}
struct MotionVideoManifest: Codable, Equatable, Sendable {
    var version = 1
    let sessionID: UUID
    var state = "waiting"
    var reason: String?
    var segments: [MotionVideoSegment] = []
    var droppedFrames = 0
    var updatedAt = Date()
    /// Actual end, written by the extension even while the host is suspended.
    var captureEndedAt: Date? = nil
    var captureEndedUptime: Double? = nil
    var stopCause: String? = nil
    func segment(at second: Double, offset: Double = 0) -> MotionVideoSegment? {
        segments.first { second >= $0.start + offset && second < $0.start + offset + $0.duration }
    }
}
struct MotionVideoCommand: Codable, Sendable {
    var version = 1
    let sessionID: UUID
    let startsAt: Date
    let startUptime: Double
    let endUptime: Double
    var stop = false
    /// Explicitly opted-in by a coupled video + motion session; legacy captures
    /// continue to leave the ordinary broadcast running.
    var followsBroadcast: Bool? = nil
}
struct MotionVideoHeartbeat: Codable {
    let uptime: Double
    let wallTime: Date
    var fresh: Bool {
        let age = ProcessInfo.processInfo.systemUptime - uptime
        return age >= 0 && age < 2 && abs(wallTime.timeIntervalSinceNow) < 2
    }
}
#if os(iOS)
enum MotionVideoFiles {
    static var root: URL? {
        FileManager.default.containerURL(forSecurityApplicationGroupIdentifier: AppGroup.identifier)?
            .appendingPathComponent("MotionVideo", isDirectory: true)
    }
    static func folder(_ id: UUID) -> URL? { root?.appendingPathComponent(id.uuidString, isDirectory: true) }
    static func write<T: Encodable>(_ value: T, to url: URL) throws {
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try JSONEncoder().encode(value).write(to: url, options: [.atomic, .completeFileProtectionUntilFirstUserAuthentication])
    }
    static func read<T: Decodable>(_ type: T.Type, at url: URL?) -> T? {
        guard let url, let data = try? Data(contentsOf: url) else { return nil }
        return try? JSONDecoder().decode(type, from: data)
    }
    static var commandURL: URL? { root?.appendingPathComponent("command.json") }
    static var heartbeatURL: URL? { root?.appendingPathComponent("frames.json") }
    static var framesAvailable: Bool { read(MotionVideoHeartbeat.self, at: heartbeatURL)?.fresh == true }
    static func manifestURL(_ id: UUID) -> URL? { folder(id)?.appendingPathComponent("video.json") }
}
#endif
#endif
