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

struct SurfacePrediction {
    let appProbabilities: [SurfaceApp: Double]
    let youtubeContentProbabilities: [YouTubeContent: Double]
    let instagramContentProbabilities: [InstagramContent: Double]

    var topApp: SurfaceApp? {
        appProbabilities.max(by: { $0.value < $1.value })?.key
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
        let youtube = appProbabilities[.youtube] ?? 0
        let instagram = appProbabilities[.instagram] ?? 0
        return [
            .youtubeShorts: youtube * (youtubeContentProbabilities[.shorts] ?? 0),
            .youtubeNormal: youtube * (youtubeContentProbabilities[.normal] ?? 0),
            .instagramReels: instagram * (instagramContentProbabilities[.reels] ?? 0),
            .instagramStories: instagram * (instagramContentProbabilities[.stories] ?? 0),
            .instagramNormal: instagram * (instagramContentProbabilities[.normal] ?? 0),
            .otherApp: appProbabilities[.other] ?? 0,
        ]
    }

    var topClass: SurfaceClass? {
        jointProbabilities.max(by: { $0.value < $1.value })?.key
    }

    func probability(for surface: SurfaceClass) -> Double {
        jointProbabilities[surface] ?? 0
    }
}

final class SurfaceClassifier {
    let metadata: SurfaceModelMetadata

    private let model: MLModel
    private let imageResizer: ModelImageResizer

    init(bundle: Bundle = .main, computeUnits: MLComputeUnits = .cpuAndNeuralEngine) throws {
        metadata = try SurfaceModelMetadata.load(bundle: bundle)
        guard let modelURL = bundle.url(forResource: "SurfaceDetector", withExtension: "mlmodelc") else {
            throw SurfaceClassifierError.modelMissing
        }
        let configuration = MLModelConfiguration()
        configuration.computeUnits = computeUnits
        model = try MLModel(contentsOf: modelURL, configuration: configuration)
        imageResizer = try ModelImageResizer(
            width: metadata.inputWidth,
            height: metadata.inputHeight
        )
    }

    func predict(pixelBuffer: CVPixelBuffer) throws -> SurfacePrediction {
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
