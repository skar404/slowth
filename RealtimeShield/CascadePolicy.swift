import Foundation
import CryptoKit

/// A nil app means a normal abstention, not a model execution failure.
struct SurfaceRouting {
    let app: SurfaceApp?
    let reason: String
    let maxEvidenceGapSeconds: Double
}

struct CascadePolicy: Decodable {
    struct Cutoff: Decodable { let confidence: Double; let margin: Double }
    struct Temporal: Decodable {
        let intervalSeconds: Double
        let requiredHits: Int
        let windowFrames: Int
        let maxGapSeconds: Double
    }
    let version: Int
    let routing: [String: Cutoff]
    let thresholds: [String: Double]
    let temporal: Temporal

    func validate() throws {
        guard version == 1, Set(routing.keys) == ["youtube", "instagram"],
              Set(thresholds.keys) == ["youtube_shorts", "instagram_reels", "instagram_stories"],
              routing.values.allSatisfy({
                  $0.confidence.isFinite && (0...1).contains($0.confidence)
                    && $0.margin.isFinite && (0...1).contains($0.margin)
              }), thresholds.values.allSatisfy({ $0.isFinite && $0 > 0 && $0 <= 1 }),
              temporal.intervalSeconds.isFinite, temporal.intervalSeconds > 0,
              temporal.requiredHits > 0, temporal.windowFrames >= temporal.requiredHits,
              temporal.maxGapSeconds.isFinite, temporal.maxGapSeconds >= temporal.intervalSeconds else {
            throw CascadeClassifierError.invalid("policy")
        }
    }

    func route(_ values: [Double]) throws -> SurfaceRouting {
        try Self.validateProbabilities(values, count: 3)
        var winner = 0
        for index in 1..<values.count where values[index] > values[winner] { winner = index }
        let gap = temporal.maxGapSeconds
        guard winner != 2 else { return SurfaceRouting(app: nil, reason: "other", maxEvidenceGapSeconds: gap) }
        let app: SurfaceApp = winner == 0 ? .youtube : .instagram
        guard let cutoff = routing[app.rawValue] else { throw CascadeClassifierError.invalid("routing") }
        let second = values.enumerated().filter { $0.offset != winner }.map(\.element).max() ?? 0
        if values[winner] < cutoff.confidence {
            return SurfaceRouting(app: nil, reason: "low_confidence", maxEvidenceGapSeconds: gap)
        }
        if values[winner] - second < cutoff.margin {
            return SurfaceRouting(app: nil, reason: "ambiguous", maxEvidenceGapSeconds: gap)
        }
        return SurfaceRouting(app: app, reason: "accepted", maxEvidenceGapSeconds: gap)
    }

    static func enabledApps(youtube: Bool, reels: Bool, stories: Bool) -> Set<SurfaceApp> {
        var apps: Set<SurfaceApp> = []
        if youtube { apps.insert(.youtube) }
        if reels || stories { apps.insert(.instagram) }
        return apps
    }

    func predict(enabledApps: Set<SurfaceApp>, run: (String) throws -> [Double]) throws -> SurfacePrediction {
        let app = try run("router")
        try Self.validateProbabilities(app, count: 3)
        var routing = try route(app)
        if let accepted = routing.app, !enabledApps.contains(accepted) {
            routing = SurfaceRouting(app: nil, reason: "disabled", maxEvidenceGapSeconds: routing.maxEvidenceGapSeconds)
        }
        var youtube: [YouTubeContent: Double] = [:]
        var instagram: [InstagramContent: Double] = [:]
        switch routing.app {
        case .youtube:
            let values = try run("youtube")
            try Self.validateProbabilities(values, count: 2)
            youtube = Dictionary(uniqueKeysWithValues: YouTubeContent.allCases.enumerated().map { ($0.element, values[$0.offset]) })
        case .instagram:
            let values = try run("instagram")
            try Self.validateProbabilities(values, count: 3)
            instagram = Dictionary(uniqueKeysWithValues: InstagramContent.allCases.enumerated().map { ($0.element, values[$0.offset]) })
        default: break
        }
        return SurfacePrediction(
            appProbabilities: Dictionary(uniqueKeysWithValues: SurfaceApp.allCases.enumerated().map { ($0.element, app[$0.offset]) }),
            youtubeContentProbabilities: youtube, instagramContentProbabilities: instagram, routing: routing)
    }

    static func validateProbabilities(_ values: [Double], count: Int) throws {
        guard values.count == count, values.allSatisfy({ $0.isFinite && (0...1).contains($0) }),
              abs(values.reduce(0, +) - 1) <= 0.00001 else {
            throw CascadeClassifierError.invalid("probabilities")
        }
    }
}

enum CascadeClassifierError: LocalizedError {
    case missing(String)
    case invalid(String)
    var errorDescription: String? {
        switch self {
        case .missing(let name): return "Cascade resource missing: \(name)"
        case .invalid(let name): return "Invalid cascade \(name)"
        }
    }
}

/// Explicit identities and bundle names for frozen experimental candidates.
enum CascadeCandidate {
    case v3, v4, v5, v6

    var metadataResource: String {
        switch self {
        case .v3: return "CascadeMetadata"
        case .v4: return "CascadeV4Metadata"
        case .v5: return "CascadeV5Metadata"
        case .v6:
            #if DEBUG
            return "CascadeV6Metadata"
            #else
            return "CascadeV6RuntimeMetadata"
            #endif
        }
    }
    var modelVersion: String {
        switch self {
        case .v3: return "cascade-v3-updated-20260914-100247"
        case .v4: return "cascade-v4-20260919"
        case .v5: return "cascade-v5-20260920-1018"
        case .v6: return "cascade-v6-20260920-124303"
        }
    }
    var metadataSHA256: String {
        switch self {
        case .v3: return CascadeModelMetadata.debugMetadataSHA256
        case .v4: return "19e58b295b39a3fbf5fedca00bc80a176b6ecc6b4a62a6ed5cafde34c4ec59e9"
        case .v5: return "5e83dfb960b19f5b0e3cd26d4bb6a4403432d2a56d24340e96f4d6c5c3c26291"
        case .v6:
            #if DEBUG
            return "ac60c10e4bc7f0091b51bd86195b5597ccb78e6c7af3a5b15911f70981cdf404"
            #else
            // Compact derivative: identical policy/identity, no training inventory or local paths.
            return "b56dfc94cecd8f6165c3a94bc3781fb76cff98df87516a40bc09577887e4fcbd"
            #endif
        }
    }
    func resource(_ base: String) -> String {
        switch self {
        case .v3: return base
        case .v4: return base + "V4"
        case .v5: return base + "V5"
        case .v6: return base + "V6"
        }
    }
}

struct CascadeModelMetadata: Decodable {
    struct Input: Decodable { let width: Int; let height: Int; let color: String; let scale: Double }
    struct Component: Decodable {
        let resource: String
        let labels: [String]
        let checkpointSha256: String
    }
    let schemaVersion: Int
    let modelVersion: String
    let architecture: String
    let input: Input
    let components: [String: Component]
    let policy: CascadePolicy
    let validationStatus: String
    let computePrecision: String
    let status: String?

    // Pin the frozen Debug candidate, not a qualification claim. Export bytes and
    // calibrated policy stay unchanged even though validation did not pass.
    static let debugMetadataSHA256 = "1f9bfba712efdfc581afd60f0e67e968796bdb5aa43e2c6dd4ed307c808ce9b1"

    static func load(bundle: Bundle, candidate: CascadeCandidate = .v3) throws -> CascadeModelMetadata {
        guard let url = bundle.url(forResource: candidate.metadataResource, withExtension: "json") else {
            throw CascadeClassifierError.missing(candidate.metadataResource + ".json")
        }
        let decoder = JSONDecoder()
        decoder.keyDecodingStrategy = .convertFromSnakeCase
        let data = try Data(contentsOf: url)
        guard SHA256.hash(data: data).map({ String(format: "%02x", $0) }).joined() == candidate.metadataSHA256 else {
            throw CascadeClassifierError.invalid("candidate metadata identity")
        }
        let value = try decoder.decode(Self.self, from: data)
        try value.validate()
        guard value.modelVersion == candidate.modelVersion else {
            throw CascadeClassifierError.invalid("selected candidate version")
        }
        return value
    }

    func validate() throws {
        let expected = ["router": SurfaceApp.allCases.map(\.rawValue),
                        "youtube": YouTubeContent.allCases.map(\.rawValue),
                        "instagram": InstagramContent.allCases.map(\.rawValue)]
        guard !modelVersion.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
              schemaVersion == 1, architecture == "cascade-spatial-v1", computePrecision == "float32",
              (validationStatus == "passed" ||
                ([CascadeCandidate.v3.modelVersion, CascadeCandidate.v4.modelVersion, CascadeCandidate.v5.modelVersion,
                  CascadeCandidate.v6.modelVersion].contains(modelVersion) &&
                 status == "candidate_unverified" && validationStatus == "failed")),
              input.width == 192, input.height == 384,
              input.color == "RGB", abs(input.scale - 1 / 255.0) < 1e-12,
              Set(components.keys) == Set(expected.keys),
              expected.allSatisfy({ components[$0.key]?.labels == $0.value }),
              components["router"]?.resource == "AppRouter",
              components["youtube"]?.resource == "YouTubeDetector",
              components["instagram"]?.resource == "InstagramDetector",
              components.values.allSatisfy({
                  $0.checkpointSha256.range(of: "^[0-9a-f]{64}$", options: .regularExpression) != nil
              }) else {
            throw CascadeClassifierError.invalid("metadata")
        }
        try policy.validate()
    }

    func validateCreator(_ creator: [String: String]?, stage: String) throws {
        guard let component = components[stage],
              creator?["cascade_stage"] == stage,
              creator?["cascade_version"] == modelVersion,
              creator?["checkpoint_sha256"] == component.checkpointSha256 else {
            throw CascadeClassifierError.invalid("component identity: \(stage)")
        }
    }

    var surfaceMetadata: SurfaceModelMetadata {
        SurfaceModelMetadata(modelVersion: modelVersion, appLabels: SurfaceApp.allCases.map(\.rawValue),
            youtubeContentLabels: YouTubeContent.allCases.map(\.rawValue),
            instagramContentLabels: InstagramContent.allCases.map(\.rawValue),
            inputWidth: input.width, inputHeight: input.height, confidenceThresholds: policy.thresholds,
            inferenceIntervalSeconds: policy.temporal.intervalSeconds,
            requiredConsecutiveHits: policy.temporal.requiredHits,
            observationWindowFrames: policy.temporal.windowFrames)
    }
}


/// Decide discontinuities before throttling so a restarted PTS cannot starve inference.
enum CascadeSampling: Equatable {
    case skip
    case sample(reset: Bool)

    static func decide(timestamp: Double, previous: Double?, interval: Double) -> Self {
        guard timestamp.isFinite else { return .sample(reset: true) }
        guard let previous else { return .sample(reset: false) }
        let elapsed = timestamp - previous
        guard elapsed.isFinite, elapsed > 0 else { return .sample(reset: true) }
        return elapsed < interval ? .skip : .sample(reset: false)
    }
}

/// PTS deltas on an uptime-anchored timeline. Clock-source changes reset evidence;
/// invalid PTS never introduces Date's epoch into neighboring observations.
struct CascadeTimestampClock {
    private var previousPTS: Double?
    private var previousUptime: Double?
    private var seconds: Double?

    mutating func resolve(pts: Double, uptime: Double) -> (seconds: Double, reset: Bool) {
        let validPTS = pts.isFinite ? pts : nil
        defer { previousPTS = validPTS; previousUptime = uptime }
        guard let previousUptime, let previousSeconds = seconds else {
            seconds = uptime
            return (uptime, false)
        }
        let sourceChanged = (validPTS == nil) != (previousPTS == nil)
        let delta: Double
        if let validPTS, let previousPTS { delta = validPTS - previousPTS }
        else { delta = uptime - previousUptime }
        let discontinuity = !delta.isFinite || delta <= 0
        let resolved = previousSeconds + (discontinuity ? max(0, uptime - previousUptime) : delta)
        seconds = resolved
        return (resolved, sourceChanged || discontinuity)
    }
}

/// Candidate-only state: intentionally has no access to shield latches or grace.
struct CascadeEvidenceBoundary {
    static func appendVote(_ vote: Bool, to votes: inout [Bool], window: Int) -> Int {
        votes.append(vote)
        if votes.count > window {
            votes.removeFirst(votes.count - window)
        }
        return votes.reduce(0) { $0 + ($1 ? 1 : 0) }
    }

    private var previousApp: SurfaceApp?
    private var previousTimestamp: Double?

    mutating func observe(app: SurfaceApp?, timestamp: Double, maxGap: Double) -> Bool {
        defer { previousApp = app; previousTimestamp = timestamp }
        guard let previousTimestamp else { return true }
        let elapsed = timestamp - previousTimestamp
        return app == nil || app != previousApp || !elapsed.isFinite || elapsed <= 0 || elapsed > maxGap
    }
}
