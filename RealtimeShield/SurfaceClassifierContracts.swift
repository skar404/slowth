import CoreVideo
import Foundation

enum SurfaceClassifierError: LocalizedError {
    case metadataMissing
    case invalidMetadata
    case modelMissing
    case missingOutput(String)
    case unexpectedOutputCount(String, Int)

    var errorDescription: String? {
        switch self {
        case .metadataMissing: return "SurfaceDetectorMetadata.json is missing"
        case .invalidMetadata: return "SurfaceDetector metadata is invalid"
        case .modelMissing: return "SurfaceDetector.mlmodelc is missing"
        case .missingOutput(let name): return "model output \(name) is missing"
        case .unexpectedOutputCount(let name, let count):
            return "SurfaceDetector output \(name) has unexpected count \(count)"
        }
    }
}

protocol SurfaceClassifying {
    var metadata: SurfaceModelMetadata { get }
    func copyModelInputBGRA() throws -> (data: Data, width: Int, height: Int, bytesPerRow: Int)
    func predict(pixelBuffer: CVPixelBuffer, enabledApps: Set<SurfaceApp>) throws -> SurfacePrediction
}

struct SurfaceInferenceTimings {
    let resizeMS: Double
    let routerMS: Double
    let specialistMS: Double?
    let totalMS: Double
    let specialist: String // "not_run" is not a normal classification.
}

struct SurfacePrediction {
    let appProbabilities: [SurfaceApp: Double]
    let youtubeContentProbabilities: [YouTubeContent: Double]
    let instagramContentProbabilities: [InstagramContent: Double]
    var facebookContentProbabilities: [FacebookContent: Double] = [:]
    var xContentProbabilities: [XContent: Double] = [:]
    var flatProbabilities: [SurfaceClass: Double]? = nil
    var routing: SurfaceRouting? = nil
    var timings: SurfaceInferenceTimings? = nil

    var topApp: SurfaceApp? {
        if let routing { return routing.app }
        return appProbabilities.max(by: { $0.value < $1.value })?.key
    }

    var topContent: String? {
        switch topApp {
        case .youtube:
            return youtubeContentProbabilities.max(by: { $0.value < $1.value })?.key.rawValue
        case .instagram:
            return instagramContentProbabilities.max(by: { $0.value < $1.value })?.key.rawValue
        case .facebook:
            return facebookContentProbabilities.max(by: { $0.value < $1.value })?.key.rawValue
        case .x:
            return xContentProbabilities.max(by: { $0.value < $1.value })?.key.rawValue
        case .other:
            return "normal"
        case nil:
            return nil
        }
    }

    var jointProbabilities: [SurfaceClass: Double] {
        if let flatProbabilities { return flatProbabilities }
        let youtube = routing == nil || routing?.app == .youtube ? (appProbabilities[.youtube] ?? 0) : 0
        let instagram = routing == nil || routing?.app == .instagram ? (appProbabilities[.instagram] ?? 0) : 0
        let facebook = routing?.app == .facebook ? (appProbabilities[.facebook] ?? 0) : 0
        let x = routing?.app == .x ? (appProbabilities[.x] ?? 0) : 0
        return [
            .xReels: x * (xContentProbabilities[.reels] ?? 0),
            .xNormal: x * (xContentProbabilities[.normal] ?? 0),
            .facebookReels: facebook * (facebookContentProbabilities[.reels] ?? 0),
            .facebookStories: facebook * (facebookContentProbabilities[.stories] ?? 0),
            .facebookNormal: facebook * (facebookContentProbabilities[.normal] ?? 0),
            .youtubeShorts: youtube * (youtubeContentProbabilities[.shorts] ?? 0),
            .youtubeNormal: youtube * (youtubeContentProbabilities[.normal] ?? 0),
            .instagramReels: instagram * (instagramContentProbabilities[.reels] ?? 0),
            .instagramStories: instagram * (instagramContentProbabilities[.stories] ?? 0),
            .instagramNormal: instagram * (instagramContentProbabilities[.normal] ?? 0),
            .otherApp: routing == nil ? (appProbabilities[.other] ?? 0) : 0,
        ]
    }

    var topClass: SurfaceClass? {
        if routing != nil && routing?.app == nil { return nil }
        return jointProbabilities.max(by: { $0.value < $1.value })?.key
    }

    func probability(for surface: SurfaceClass) -> Double {
        jointProbabilities[surface] ?? 0
    }
}
