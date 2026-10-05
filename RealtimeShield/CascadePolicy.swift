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

    var appLabels: [SurfaceApp] { version == 3 ? SurfaceApp.allCases : version == 2 ? SurfaceApp.legacyCases + [.facebook] : SurfaceApp.legacyCases }

    func validate() throws {
        var apps: Set<String> = version >= 2 ? ["youtube", "instagram", "facebook"] : ["youtube", "instagram"]
        var targets: Set<String> = version >= 2
            ? ["youtube_shorts", "instagram_reels", "instagram_stories", "facebook_reels", "facebook_stories"]
            : ["youtube_shorts", "instagram_reels", "instagram_stories"]
        if version == 3 { apps.insert("x"); targets.insert("x_reels") }
        guard [1, 2, 3].contains(version), Set(routing.keys) == apps,
              Set(thresholds.keys) == targets,
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
        try Self.validateProbabilities(values, count: appLabels.count)
        var winner = 0
        for index in 1..<values.count where values[index] > values[winner] { winner = index }
        let gap = temporal.maxGapSeconds
        guard winner != 2 else { return SurfaceRouting(app: nil, reason: "other", maxEvidenceGapSeconds: gap) }
        let app = appLabels[winner]
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

    static func enabledApps(youtube: Bool, reels: Bool, stories: Bool, facebookReels: Bool = false, facebookStories: Bool = false, xReels: Bool = false) -> Set<SurfaceApp> {
        var apps: Set<SurfaceApp> = []
        if youtube { apps.insert(.youtube) }
        if reels || stories { apps.insert(.instagram) }
        if facebookReels || facebookStories { apps.insert(.facebook) }
        if xReels { apps.insert(.x) }
        return apps
    }

    func predict(enabledApps: Set<SurfaceApp>, run: (String) throws -> [Double]) throws -> SurfacePrediction {
        let app = try run("router")
        try Self.validateProbabilities(app, count: appLabels.count)
        var routing = try route(app)
        if let accepted = routing.app, !enabledApps.contains(accepted) {
            routing = SurfaceRouting(app: nil, reason: "disabled", maxEvidenceGapSeconds: routing.maxEvidenceGapSeconds)
        }
        var youtube: [YouTubeContent: Double] = [:]
        var instagram: [InstagramContent: Double] = [:]
        var facebook: [FacebookContent: Double] = [:]
        var x: [XContent: Double] = [:]
        switch routing.app {
        case .youtube:
            let values = try run("youtube")
            try Self.validateProbabilities(values, count: 2)
            youtube = Dictionary(uniqueKeysWithValues: YouTubeContent.allCases.enumerated().map { ($0.element, values[$0.offset]) })
        case .instagram:
            let values = try run("instagram")
            try Self.validateProbabilities(values, count: 3)
            instagram = Dictionary(uniqueKeysWithValues: InstagramContent.allCases.enumerated().map { ($0.element, values[$0.offset]) })
        case .facebook:
            let values = try run("facebook")
            try Self.validateProbabilities(values, count: 3)
            facebook = Dictionary(uniqueKeysWithValues: FacebookContent.allCases.enumerated().map { ($0.element, values[$0.offset]) })
        case .x:
            let values = try run("x")
            try Self.validateProbabilities(values, count: 2)
            x = Dictionary(uniqueKeysWithValues: XContent.allCases.enumerated().map { ($0.element, values[$0.offset]) })
        default: break
        }
        return SurfacePrediction(
            appProbabilities: Dictionary(uniqueKeysWithValues: appLabels.enumerated().map { ($0.element, app[$0.offset]) }),
            youtubeContentProbabilities: youtube, instagramContentProbabilities: instagram, facebookContentProbabilities: facebook, xContentProbabilities: x, routing: routing)
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
    case v3, v4, v5, v6, v7, v8, v10

    var metadataResource: String {
        switch self {
        case .v10:
            #if DEBUG
            return "CascadeV10Metadata"
            #else
            return "CascadeV10RuntimeMetadata"
            #endif
        case .v8:
            #if DEBUG
            return "CascadeV8Metadata"
            #else
            return "CascadeV8RuntimeMetadata"
            #endif
        case .v7:
            #if DEBUG
            return "CascadeV7Metadata"
            #else
            return "CascadeV7RuntimeMetadata"
            #endif
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
        case .v10: return "cascade-v10-balanced-20260929-140403-diverse"
        case .v8: return "cascade-v8-x-20260928"
        case .v7: return "cascade-v7-facebook-20260928-114500"
        case .v3: return "cascade-v3-updated-20260914-100247"
        case .v4: return "cascade-v4-20260919"
        case .v5: return "cascade-v5-20260920-1018"
        case .v6: return "cascade-v6-20260920-124303"
        }
    }
    var metadataSHA256: String {
        switch self {
        case .v10:
            #if DEBUG
            return "f7fd1ae118afadc139c3e95b4e5bc9eb86eb801da770e5bf2194190320a66760"
            #else
            return "41ee86e2d0410dd455297c31c8a839aa2d72fb2b39a9698060e0a412ae63896a"
            #endif
        case .v8:
            #if DEBUG
            return "14d08357cc7bedc7f93fff18e380800ee30e06e279aed50f276efbb9df325977"
            #else
            return "861bc15a5c51cd477f1a044f2922ab30a8af4cfd77b4c9d5b638ec5d676aa1c8"
            #endif
        case .v7:
            #if DEBUG
            return "a18028d31e1ebc71a87a35ad48aea4c7740ff2a23a954c6a1059d6c5ac796c79"
            #else
            return "386758bcf18a12f2ee2336986875029816ef21f1dce892c506e7b9fa746273f6"
            #endif
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
        case .v10: return base + "V10"
        case .v8: return base + "V8"
        case .v7: return base + "V7"
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
    let contract: String?
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
        var expected = ["router": policy.appLabels.map(\.rawValue),
                        "youtube": YouTubeContent.allCases.map(\.rawValue),
                        "instagram": InstagramContent.allCases.map(\.rawValue)]
        if policy.version >= 2 { expected["facebook"] = FacebookContent.allCases.map(\.rawValue) }
        if policy.version == 3 { expected["x"] = XContent.allCases.map(\.rawValue) }
        guard (policy.version == 1 && (contract == nil || contract == "v1")) || (policy.version == 2 && contract == "v7") || (policy.version == 3 && contract == "v8") else {
            throw CascadeClassifierError.invalid("contract")
        }
        guard !modelVersion.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
              schemaVersion == 1, architecture == "cascade-spatial-v1", computePrecision == "float32",
              (validationStatus == "passed" ||
                ([CascadeCandidate.v3.modelVersion, CascadeCandidate.v4.modelVersion, CascadeCandidate.v5.modelVersion,
                  CascadeCandidate.v6.modelVersion].contains(modelVersion) &&
                 status == "candidate_unverified" && validationStatus == "failed") ||
                ([CascadeCandidate.v7.modelVersion, CascadeCandidate.v8.modelVersion, CascadeCandidate.v10.modelVersion].contains(modelVersion) && status == "experimental"
                 && validationStatus == "failed")),
              input.width == 192, input.height == 384,
              input.color == "RGB", abs(input.scale - 1 / 255.0) < 1e-12,
              Set(components.keys) == Set(expected.keys),
              expected.allSatisfy({ components[$0.key]?.labels == $0.value }),
              components["router"]?.resource == "AppRouter",
              components["youtube"]?.resource == "YouTubeDetector",
              components["instagram"]?.resource == "InstagramDetector",
              (policy.version == 1 || components["facebook"]?.resource == "FacebookDetector"),
              (policy.version != 3 || components["x"]?.resource == "XDetector"),
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
        SurfaceModelMetadata(modelVersion: modelVersion, appLabels: policy.appLabels.map(\.rawValue),
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
