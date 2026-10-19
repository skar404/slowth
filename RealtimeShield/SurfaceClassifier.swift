import CoreML
import CoreVideo
import Foundation

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
        guard appValues.count == SurfaceApp.legacyCases.count else {
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
                uniqueKeysWithValues: SurfaceApp.legacyCases.enumerated().map { index, app in
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
