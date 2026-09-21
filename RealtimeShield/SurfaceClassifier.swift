import CoreML
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
        case .other:
            return "normal"
        case nil:
            return nil
        }
    }

    var jointProbabilities: [SurfaceClass: Double] {
        let youtube = routing == nil || routing?.app == .youtube ? (appProbabilities[.youtube] ?? 0) : 0
        let instagram = routing == nil || routing?.app == .instagram ? (appProbabilities[.instagram] ?? 0) : 0
        return [
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

final class SurfaceClassifier: SurfaceClassifying {
    let metadata: SurfaceModelMetadata

    private let model: MLModel
    private let imageResizer: ModelImageResizer

    init(bundle: Bundle = .main, computeUnits: MLComputeUnits = .cpuAndNeuralEngine,
         resourceName: String = "SurfaceDetector") throws {
        let expectedVersion: String?
        switch resourceName {
        case "SurfaceDetector": expectedVersion = nil
        case "SurfaceDetectorV11": expectedVersion = "surface-hierarchical-v11-experimental"
        case "SurfaceDetectorV12": expectedVersion = "surface-hierarchical-v12-experimental"
        case "SurfaceDetectorV14": expectedVersion = "surface-hierarchical-v14-experimental"
        case "SurfaceDetectorV15": expectedVersion = "surface-hierarchical-v15-experimental"
        default:
            throw SurfaceClassifierError.invalidMetadata
        }
        metadata = try SurfaceModelMetadata.load(bundle: bundle, resourceName: resourceName + "Metadata")
        if let expectedVersion, metadata.modelVersion != expectedVersion {
            throw SurfaceClassifierError.invalidMetadata
        }
        guard let modelURL = bundle.url(forResource: resourceName, withExtension: "mlmodelc") else {
            throw SurfaceClassifierError.modelMissing
        }
        let configuration = MLModelConfiguration()
        configuration.computeUnits = computeUnits
        model = try MLModel(contentsOf: modelURL, configuration: configuration)
        if expectedVersion != nil {
            let creator = model.modelDescription.metadata[.creatorDefinedKey] as? [String: String] ?? [:]
            if resourceName == "SurfaceDetectorV12" {
                try metadata.validateV12Creator(creator)
            } else {
                try metadata.validateExperimentalCreator(creator)
            }
        }
        imageResizer = try ModelImageResizer(
            width: metadata.inputWidth,
            height: metadata.inputHeight
        )
    }

    func predict(pixelBuffer: CVPixelBuffer, enabledApps: Set<SurfaceApp>) throws -> SurfacePrediction {
        let resizedBuffer = try imageResizer.resize(pixelBuffer)
        let provider = try MLDictionaryFeatureProvider(dictionary: [
            "image": MLFeatureValue(pixelBuffer: resizedBuffer)
        ])
        let prediction = try model.prediction(from: provider)
        let outputs = [
            "appProbabilities": prediction.featureValue(for: "appProbabilities")?.multiArrayValue,
            "youtubeContentProbabilities": prediction
                .featureValue(for: "youtubeContentProbabilities")?.multiArrayValue,
            "instagramContentProbabilities": prediction
                .featureValue(for: "instagramContentProbabilities")?.multiArrayValue,
        ]
        for (name, values) in outputs where values == nil {
            throw SurfaceClassifierError.missingOutput(name)
        }
        guard let appValues = outputs["appProbabilities"]!,
              let youtubeValues = outputs["youtubeContentProbabilities"]!,
              let instagramValues = outputs["instagramContentProbabilities"]! else {
            throw SurfaceClassifierError.invalidMetadata
        }
        guard appValues.count == SurfaceApp.allCases.count else {
            throw SurfaceClassifierError.unexpectedOutputCount(
                "appProbabilities",
                appValues.count
            )
        }
        guard youtubeValues.count == YouTubeContent.allCases.count else {
            throw SurfaceClassifierError.unexpectedOutputCount(
                "youtubeContentProbabilities",
                youtubeValues.count
            )
        }
        guard instagramValues.count == InstagramContent.allCases.count else {
            throw SurfaceClassifierError.unexpectedOutputCount(
                "instagramContentProbabilities",
                instagramValues.count
            )
        }
        return SurfacePrediction(
            appProbabilities: Dictionary(
                uniqueKeysWithValues: SurfaceApp.allCases.enumerated().map { index, app in
                    (app, appValues[index].doubleValue)
                }
            ),
            youtubeContentProbabilities: Dictionary(
                uniqueKeysWithValues: YouTubeContent.allCases.enumerated().map { index, content in
                    (content, youtubeValues[index].doubleValue)
                }
            ),
            instagramContentProbabilities: Dictionary(
                uniqueKeysWithValues: InstagramContent.allCases.enumerated().map { index, content in
                    (content, instagramValues[index].doubleValue)
                }
            )
        )
    }

    func copyModelInputBGRA() throws -> (data: Data, width: Int, height: Int, bytesPerRow: Int) {
        let copy = try imageResizer.copyCurrentBGRABytes()
        return (
            data: copy.data,
            width: imageResizer.width,
            height: imageResizer.height,
            bytesPerRow: copy.bytesPerRow
        )
    }
}
