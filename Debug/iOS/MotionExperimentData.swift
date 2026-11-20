#if DEBUG
import Foundation

/// Raw acceleration includes gravity. Labels describe the participant's action,
/// never a classifier prediction. Dates are Unix seconds in exports.
struct MotionExperimentSample: Codable, Sendable {
    let time: Double
    let x: Double
    let y: Double
    let z: Double
    var uptime: Double? = nil
    var magnitude: Double { sqrt(x * x + y * y + z * z) }
}

struct MotionExperimentMarker: Codable, Sendable, Identifiable {
    var id: Double { time }
    let time: Double
    let label: String
}

struct MotionExperimentSession: Codable, Sendable, Identifiable {
    let id: UUID
    let requestedAt: Date
    let startsAt: Date
    let scheduledEnd: Date
    var endedAt: Date?
    var schemaVersion: Int? = 2
    var startUptime: Double? = nil
    var recordsVideo: Bool? = nil
    var followsBroadcast: Bool? = nil
    var markers: [MotionExperimentMarker]
    var endsAt: Date { min(endedAt ?? scheduledEnd, scheduledEnd) }
    var duration: Double { max(0, endsAt.timeIntervalSince(startsAt)) }

    mutating func reconcileCapture(_ video: MotionVideoManifest) {
        guard followsBroadcast == true, video.sessionID == id else { return }
        let end: Date?
        if let anchor = startUptime, let uptime = video.captureEndedUptime {
            end = startsAt.addingTimeInterval(uptime - anchor)
        } else { end = video.captureEndedAt }
        if let end { endedAt = min(endedAt ?? scheduledEnd, min(end, scheduledEnd)) }
    }

    func label(at time: Double) -> String {
        guard time >= startsAt.timeIntervalSince1970, time < endsAt.timeIntervalSince1970 else { return "setup" }
        return markers.last(where: { $0.time <= time })?.label ?? "unlabelled"
    }

    func elapsed(_ sample: MotionExperimentSample) -> Double {
        if let anchor = startUptime, let uptime = sample.uptime { return uptime - anchor }
        return sample.time - startsAt.timeIntervalSince1970
    }

    func filtered(_ samples: [MotionExperimentSample]) -> [MotionExperimentSample] {
        samples.filter {
            elapsed($0) >= 0 && elapsed($0) < duration &&
            $0.time.isFinite && $0.x.isFinite && $0.y.isFinite && $0.z.isFinite
        }.sorted { elapsed($0) < elapsed($1) }
    }
}

struct MotionExperimentBin: Identifiable {
    let id: Int
    let second: Double
    let min: Double
    let max: Double
    let count: Int
}

struct MotionAxisPoint: Equatable, Sendable {
    let second: Double
    let values: [Double]
}
struct MotionAxisRun: Sendable {
    let points: [MotionAxisPoint]
}
struct MotionAxes: Sendable {
    let runs: [MotionAxisRun]
    let limit: Double
    static let empty = MotionAxes(runs: [], limit: 1)
}

enum MotionExperimentAnalysis {
    /// Preserve raw signed axes and break all three lines across missing samples.
    /// Sorting uses the same monotonic session clock as video and tag selection.
    static func axes(_ samples: [MotionExperimentSample], session: MotionExperimentSession) -> MotionAxes {
        var runs: [MotionAxisRun] = []
        var points: [MotionAxisPoint] = []
        var previous: Double?
        var peak = 1.0
        for sample in session.filtered(samples) {
            let second = session.elapsed(sample)
            if let previous, second - previous > 0.1 {
                if !points.isEmpty { runs.append(.init(points: points)) }
                points = []
            }
            let values = [sample.x, sample.y, sample.z]
            for value in values { peak = max(peak, abs(value)) }
            points.append(.init(second: second, values: values))
            previous = second
        }
        if !points.isEmpty { runs.append(.init(points: points)) }
        return .init(runs: runs, limit: ceil(peak * 2) / 2)
    }

    /// One-second min/max bars preserve short peaks without connecting data gaps.
    static func bins(_ samples: [MotionExperimentSample], start: Date) -> [MotionExperimentBin] {
        let groups = Dictionary(grouping: samples) { Int(floor($0.time - start.timeIntervalSince1970)) }
        return groups.keys.sorted().compactMap { key in
            guard let values = groups[key], let low = values.map(\.magnitude).min(),
                  let high = values.map(\.magnitude).max() else { return nil }
            return MotionExperimentBin(id: key, second: Double(key) + 0.5, min: low, max: high, count: values.count)
        }
    }

    /// Includes missing time at the beginning/end; nominal sample period is 20 ms.
    static func largestGap(_ samples: [MotionExperimentSample], start: Date, end: Date) -> Double {
        guard end > start else { return 0 }
        guard let first = samples.first, let last = samples.last else { return end.timeIntervalSince(start) }
        var gap = max(first.time - start.timeIntervalSince1970,
                      end.timeIntervalSince1970 - last.time - 0.02)
        for (a, b) in zip(samples, samples.dropFirst()) {
            gap = max(gap, b.time - a.time - 0.02)
        }
        return max(0, gap)
    }

    static func csv(session: MotionExperimentSession, samples: [MotionExperimentSample], edits: MotionExperimentEdits? = nil) -> String {
        let edits = edits ?? .migrating(session)
        var rows = ["unix_seconds,elapsed_seconds,x_g,y_g,z_g,magnitude_g,label,trim_elapsed_seconds,tags_json"]
        rows += session.filtered(samples).filter { edits.trim.contains(session.elapsed($0)) }.map { sample in
            let label = session.label(at: sample.time).replacingOccurrences(of: "\"", with: "\"\"")
            let elapsed = session.elapsed(sample)
            let tags = edits.tags(at: elapsed).map { ["id": $0.id.uuidString, "name": $0.name] }
            let tagsJSON = String(data: (try? JSONSerialization.data(withJSONObject: tags, options: [.sortedKeys])) ?? Data("[]".utf8), encoding: .utf8)!.replacingOccurrences(of: "\"", with: "\"\"")
            return "\(sample.time),\(elapsed),\(sample.x),\(sample.y),\(sample.z),\(sample.magnitude),\"\(label)\",\(elapsed - edits.trim.start),\"\(tagsJSON)\""
        }
        return rows.joined(separator: "\n") + "\n"
    }
}
#endif
