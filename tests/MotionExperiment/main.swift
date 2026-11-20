import Foundation

func check(_ condition: @autoclosure () -> Bool, _ message: String) {
    if !condition() { fatalError(message) }
}
let start = Date(timeIntervalSince1970: 1000)
let session = MotionExperimentSession(id: UUID(), requestedAt: start.addingTimeInterval(-15),
    startsAt: start, scheduledEnd: start.addingTimeInterval(3), markers: [
        .init(time: 1000, label: "scroll"), .init(time: 1001, label: "read")
    ])
func sample(_ time: Double, _ x: Double = 0) -> MotionExperimentSample {
    .init(time: time, x: x, y: 0, z: 1)
}
let raw = [sample(1002), sample(999), sample(1000.02), sample(1003), sample(1000), sample(1001, .nan)]
let valid = session.filtered(raw)
check(valid.map(\.time) == [1000, 1000.02, 1002], "Exclude setup, end boundary and invalid samples; sort chronologically")
check(session.label(at: 999.9) == "setup", "Setup is not scrolling")
check(session.label(at: 1000.99) == "scroll", "Keep prior label until marker")
check(session.label(at: 1001) == "read", "Use new label at marker boundary")
check(session.label(at: 1003) == "setup", "End is exclusive")
let bins = MotionExperimentAnalysis.bins(valid, start: start)
check(bins.map(\.id) == [0, 2], "Do not invent an empty middle second")
check(bins[0].count == 2 && bins[0].min == 1 && bins[0].max == 1, "Stillness retains gravity")
let gap = MotionExperimentAnalysis.largestGap(valid, start: start, end: session.endsAt)
check(abs(gap - 1.96) < 0.0001, "Measure missing time between samples")
check(MotionExperimentAnalysis.largestGap([], start: start, end: session.endsAt) == 3, "Empty recording is entirely missing")
let continuous = (0..<150).map { sample(1000 + Double($0) / 50) }
check(MotionExperimentAnalysis.largestGap(continuous, start: start, end: session.endsAt) < 0.0001, "Continuous 50 Hz data has no gap")
var ended = session
ended.endedAt = start.addingTimeInterval(0.5)
check(ended.filtered(valid).count == 2, "Early finish excludes subsequent samples")
ended.endedAt = start.addingTimeInterval(-5)
check(ended.duration == 0 && ended.filtered(valid).isEmpty, "Finish during setup gives an empty interval")
let csv = MotionExperimentAnalysis.csv(session: session, samples: raw)
check(csv.split(separator: "\n").count == 4, "CSV contains only valid interval samples")
check(csv.contains("1002.0,2.0,0.0,0.0,1.0,1.0,\"read\""), "CSV preserves units, time and label")
let encoded = try JSONEncoder().encode(session)
let restored = try JSONDecoder().decode(MotionExperimentSession.self, from: encoded)
check(restored.id == session.id && restored.label(at: 1001) == "read", "Session survives persistence")
print("Motion experiment: 15 checks passed")

// Decode the pre-video schema, then migrate recording labels exactly once.
let legacy = Data("""
{"id":"11111111-1111-1111-1111-111111111111","requestedAt":-978306215,"startsAt":-978306200,"scheduledEnd":-978306197,"markers":[{"time":1000,"label":"scroll"},{"time":1001,"label":"read"}]}
""".utf8)
let old = try JSONDecoder().decode(MotionExperimentSession.self, from: legacy)
check(old.recordsVideo == nil && old.startUptime == nil, "Old sessions need no video fields")
var edits = MotionExperimentEdits.migrating(old)
check(edits.tags(at: 0.999).map(\.name) == ["scroll"], "Migrate sequential marker interval")
check(edits.tags(at: 1).map(\.name) == ["read"], "Half-open tag boundaries")
check(edits.tags(at: 3).isEmpty, "Tag end is exclusive")
let walk = edits.tags.first { $0.name == "walk" }!.id
edits.assign(walk, to: .init(start: 0.5, end: 2.5))
check(Set(edits.tags(at: 1.5).map(\.name)) == Set(["read", "walk"]), "Tags may overlap")
let walkIndex = edits.tags.firstIndex { $0.id == walk }!
edits.tags[walkIndex].name = "Walking, \"outside\""
check(edits.tags(at: 2).contains { $0.id == walk && $0.name.contains("outside") }, "Rename preserves interval references")
let persisted = try JSONDecoder().decode(MotionExperimentEdits.self, from: JSONEncoder().encode(edits))
check(persisted == edits, "Persist exact edit IDs, tags and intervals")
var history = MotionEditHistory(value: edits)
var trimmed = edits; trimmed.trim = .init(start: 0.5, end: 2.5)
history.apply(trimmed)
check(history.canUndo && history.value.trim == trimmed.trim, "Trim enters edit history")
history.undo(); check(history.value == edits && history.canRedo, "Undo restores full range without changing raw markers")
history.redo(); check(history.value == trimmed, "Redo restores trim")
let trimmedCSV = MotionExperimentAnalysis.csv(session: old, samples: [sample(1000.4), sample(1000.5), sample(1002), sample(1002.5)], edits: trimmed)
check(trimmedCSV.split(separator: "\n").count == 3, "Trim exports half-open sample range")
check(trimmedCSV.contains("trim_elapsed_seconds,tags_json") && trimmedCSV.contains("\"read\",1.5,"), "CSV keeps original time and label and adds trim-relative time")
check(trimmedCSV.contains(#"Walking, \""outside\"""#), "CSV escapes JSON and quoted tag names")
let first = MotionVideoSegment(file: "a.mov", start: 0, duration: 1, firstPTS: 30, firstUptime: 100,
    orientation: 1, width: 720, height: 1280, frameTimes: [0, 0.5])
let rotated = MotionVideoSegment(file: "b.mov", start: 2, duration: 1, firstPTS: 32, firstUptime: 102,
    orientation: 6, width: 1280, height: 720, frameTimes: [0, 0.5])
var video = MotionVideoManifest(sessionID: old.id)
video.segments = [first, rotated]
check(video.segment(at: 1.5) == nil, "Pause remains a missing-video interval")
check(video.segment(at: 2)?.orientation == 6, "Rotation starts a new segment on same timeline")
check(video.segment(at: 2, offset: 0.25) == nil && video.segment(at: 2.25, offset: 0.25)?.file == "b.mov", "Manual sync preserves gaps")
let restoredVideo = try JSONDecoder().decode(MotionVideoManifest.self, from: JSONEncoder().encode(video))
check(restoredVideo == video, "Video clock anchors survive persistence")
print("Motion editor: migration, overlap, rename, trim, undo/redo, CSV and video timing checks passed")
var clockSession = old
clockSession.startUptime = 500
let changedWallClock = MotionExperimentSample(time: 1100, x: 0, y: 0, z: 1, uptime: 501)
check(clockSession.elapsed(changedWallClock) == 1 && clockSession.filtered([changedWallClock]).count == 1,
      "Monotonic sensor time preserves alignment when wall time changes")

let signedSamples = [
    MotionExperimentSample(time: 1000, x: -2.2, y: 0.5, z: 1),
    MotionExperimentSample(time: 1000.02, x: 1.8, y: -0.7, z: 0.9),
    MotionExperimentSample(time: 1001, x: 0, y: 0, z: 1)
]
let axes = MotionExperimentAnalysis.axes(signedSamples, session: old)
check(axes.runs.count == 2, "All axis graphs break across a missing interval")
check(axes.runs[0].points.map { $0.values[0] } == [-2.2, 1.8], "X graph retains sign and short peaks")
check(axes.runs[0].points[1].values == [1.8, -0.7, 0.9], "X Y Z stay independent on a common clock")
check(axes.limit == 2.5, "Axis scale expands instead of clipping high acceleration")
var coupled = old
coupled.followsBroadcast = true; coupled.startUptime = 100
var capturedEnd = MotionVideoManifest(sessionID: old.id)
capturedEnd.captureEndedAt = Date(timeIntervalSince1970: 1200)
capturedEnd.captureEndedUptime = 101.25
capturedEnd.stopCause = "broadcast_ended"
coupled.reconcileCapture(capturedEnd)
check(coupled.duration == 1.25, "Stopping broadcast closes the motion interval using monotonic time")
check(coupled.filtered([sample(1001), sample(1001.25)]).count == 1, "Do not import sensor samples after video stops")
var legacyIndependent = old
legacyIndependent.reconcileCapture(capturedEnd)
check(legacyIndependent.duration == 3, "Old independent sessions keep their original stopping behavior")
var other = coupled; other.endedAt = nil
other.reconcileCapture(MotionVideoManifest(sessionID: UUID(), captureEndedUptime: 100.5))
check(other.endedAt == nil, "A different capture cannot close the session")
print("Coupled recording and signed axis graph checks passed")
