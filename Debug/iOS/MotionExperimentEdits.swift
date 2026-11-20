#if DEBUG
import Foundation

struct MotionTimeRange: Codable, Equatable, Sendable {
    var start: Double
    var end: Double
    func contains(_ time: Double) -> Bool { time >= start && time < end }
    func clamped(to duration: Double) -> Self {
        let start = min(max(0, start.isFinite ? start : 0), duration)
        return .init(start: start, end: min(duration, max(start, end.isFinite ? end : duration)))
    }
}
struct MotionTag: Codable, Equatable, Identifiable, Sendable {
    var id: UUID = UUID()
    var name: String
    var color: String
    static let colors = ["blue", "green", "orange", "purple", "pink", "red", "teal"]
}
struct MotionTagInterval: Codable, Equatable, Identifiable, Sendable {
    var id: UUID = UUID()
    var tagID: UUID
    var range: MotionTimeRange
}
struct MotionExperimentEdits: Codable, Equatable, Sendable {
    var version = 1
    var trim: MotionTimeRange
    var tags: [MotionTag]
    var intervals: [MotionTagInterval]
    /// Positive offset moves video later on the sensor axis.
    var videoOffset: Double = 0
    static func migrating(_ session: MotionExperimentSession) -> Self {
        let names = ["scroll", "read", "type", "walk", "still"] + session.markers.map(\.label).filter {
            !["scroll", "read", "type", "walk", "still", "unlabelled", "setup"].contains($0)
        }
        var tags: [MotionTag] = []
        for name in names where !tags.contains(where: { $0.name == name }) {
            tags.append(.init(name: name, color: MotionTag.colors[tags.count % MotionTag.colors.count]))
        }
        let markers = session.markers.sorted { $0.time < $1.time }
        let intervals = markers.enumerated().compactMap { i, marker -> MotionTagInterval? in
            guard let tag = tags.first(where: { $0.name == marker.label }) else { return nil }
            let end = i + 1 < markers.count ? markers[i + 1].time : session.endsAt.timeIntervalSince1970
            let range = MotionTimeRange(start: marker.time - session.startsAt.timeIntervalSince1970,
                                        end: end - session.startsAt.timeIntervalSince1970).clamped(to: session.duration)
            return range.end > range.start ? .init(tagID: tag.id, range: range) : nil
        }
        return .init(trim: .init(start: 0, end: session.duration), tags: tags, intervals: intervals)
    }
    func tags(at time: Double) -> [MotionTag] {
        let ids = Set(intervals.filter { $0.range.contains(time) }.map(\.tagID))
        return tags.filter { ids.contains($0.id) }
    }
    mutating func assign(_ tagID: UUID, to range: MotionTimeRange) {
        guard range.start.isFinite, range.end.isFinite, range.end > range.start,
              tags.contains(where: { $0.id == tagID }) else { return }
        intervals.append(.init(tagID: tagID, range: range))
    }
}
/// The editor's history is independent of raw samples, markers and video.
struct MotionEditHistory {
    private(set) var value: MotionExperimentEdits
    private var past: [MotionExperimentEdits] = []
    private var future: [MotionExperimentEdits] = []
    var canUndo: Bool { !past.isEmpty }
    var canRedo: Bool { !future.isEmpty }
    mutating func apply(_ next: MotionExperimentEdits) {
        guard next != value else { return }
        past.append(value); value = next; future = []
    }
    mutating func undo() {
        guard let next = past.popLast() else { return }
        future.append(value); value = next
    }
    mutating func redo() {
        guard let next = future.popLast() else { return }
        past.append(value); value = next
    }
}
#endif
