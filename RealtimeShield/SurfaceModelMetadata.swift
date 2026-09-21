import Foundation

enum SurfaceApp: String, CaseIterable, Codable {
    case youtube
    case instagram
    case other
}

enum YouTubeContent: String, CaseIterable, Codable {
    case shorts
    case normal
}

enum InstagramContent: String, CaseIterable, Codable {
    case reels
    case stories
    case normal
}

enum SurfaceClass: String, CaseIterable, Codable {
    case youtubeShorts = "youtube_shorts"
    case youtubeNormal = "youtube_normal"
    case instagramReels = "instagram_reels"
    case instagramStories = "instagram_stories"
    case instagramNormal = "instagram_normal"
    case otherApp = "other_app"
}

struct SurfaceModelMetadata: Decodable {
    struct Qualification: Decodable {
        let status: String
        let reason: String?
    }
    let modelVersion: String
    let appLabels: [String]
    let youtubeContentLabels: [String]
    let instagramContentLabels: [String]
    let inputWidth: Int
    let inputHeight: Int
    let confidenceThresholds: [String: Double]
    let inferenceIntervalSeconds: Double
    let requiredConsecutiveHits: Int
    let observationWindowFrames: Int?
    var experimental: Bool? = nil
    var qualification: Qualification? = nil
    var checkpointSHA256: String? = nil

    func validateV12Creator(_ creator: [String: String]) throws {
        let passed = qualification?.status == "passed" && qualification?.reason == nil && experimental == false
        let failed = qualification?.status == "failed" && experimental == true
            && !(qualification?.reason?.isEmpty ?? true)
        guard modelVersion == "surface-hierarchical-v12-experimental",
              passed || failed,
              let digest = checkpointSHA256, digest.count == 64,
              digest.allSatisfy({ "0123456789abcdef".contains($0) }),
              creator["modelVersion"] == modelVersion,
              creator["checkpointSHA256"] == digest,
              creator["experimental"] == (experimental == true ? "true" : "false") else {
            throw SurfaceClassifierError.invalidMetadata
        }
    }

    func validateExperimentalCreator(_ creator: [String: String]) throws {
        guard ["surface-hierarchical-v11-experimental",
               "surface-hierarchical-v12-experimental",
               "surface-hierarchical-v14-experimental",
               "surface-hierarchical-v15-experimental"].contains(modelVersion),
              experimental == true,
              qualification?.status == "failed",
              let reason = qualification?.reason, !reason.isEmpty,
              let digest = checkpointSHA256, digest.count == 64,
              digest.allSatisfy({ "0123456789abcdef".contains($0) }),
              creator["modelVersion"] == modelVersion,
              creator["checkpointSHA256"] == digest,
              creator["experimental"] == "true" else {
            throw SurfaceClassifierError.invalidMetadata
        }
    }

    var effectiveObservationWindowFrames: Int {
        observationWindowFrames ?? requiredConsecutiveHits
    }

    static func load(bundle: Bundle = .main, resourceName: String = "SurfaceDetectorMetadata") throws -> SurfaceModelMetadata {
        guard let url = bundle.url(
            forResource: resourceName,
            withExtension: "json"
        ) else {
            throw SurfaceClassifierError.metadataMissing
        }
        let metadata = try JSONDecoder().decode(
            SurfaceModelMetadata.self,
            from: Data(contentsOf: url)
        )
        guard metadata.appLabels == SurfaceApp.allCases.map(\.rawValue),
              metadata.youtubeContentLabels == YouTubeContent.allCases.map(\.rawValue),
              metadata.instagramContentLabels == InstagramContent.allCases.map(\.rawValue),
              metadata.inputWidth > 0,
              metadata.inputHeight > 0,
              metadata.inferenceIntervalSeconds > 0,
              metadata.requiredConsecutiveHits > 0,
              metadata.effectiveObservationWindowFrames >= metadata.requiredConsecutiveHits,
              SurfaceClass.allCases.allSatisfy({ surface in
                  guard surface == .youtubeShorts
                        || surface == .instagramReels
                        || surface == .instagramStories else {
                      return true
                  }
                  guard let threshold = metadata.confidenceThresholds[surface.rawValue] else {
                      return false
                  }
                  return threshold > 0 && threshold <= 1
              }) else {
            throw SurfaceClassifierError.invalidMetadata
        }
        return metadata
    }

    func threshold(for surface: SurfaceClass) -> Double? {
        confidenceThresholds[surface.rawValue]
    }
}
