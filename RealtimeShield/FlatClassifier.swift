import CoreML
import CoreVideo
import CryptoKit
import Foundation

/// Frozen single-backbone model. Scores are already joint probabilities; no routing gate.
final class FlatClassifier: SurfaceClassifying {
    static let version = "flat-11-seed7-20261015"
    static let metadataSHA256 = "5759a56cccb193afc60faaf6ae8ecbda2838059eb7318afe04df0e87f4b923c9"
    let metadata: SurfaceModelMetadata
    private let model: MLModel
    private let imageResizer: ModelImageResizer

    init(bundle: Bundle = .main, computeUnits: MLComputeUnits = .cpuAndNeuralEngine) throws {
        guard let url = bundle.url(forResource: "FlatDetectorMetadata", withExtension: "json") else {
            throw SurfaceClassifierError.metadataMissing
        }
        let data = try Data(contentsOf: url)
        guard SHA256.hash(data: data).map({ String(format: "%02x", $0) }).joined() == Self.metadataSHA256 else {
            throw SurfaceClassifierError.invalidMetadata
        }
        metadata = try JSONDecoder().decode(SurfaceModelMetadata.self, from: data)
        guard let modelURL = bundle.url(forResource: "FlatDetector", withExtension: "mlmodelc") else {
            throw SurfaceClassifierError.modelMissing
        }
        let configuration = MLModelConfiguration()
        configuration.computeUnits = computeUnits
        model = try MLModel(contentsOf: modelURL, configuration: configuration)
        let creator = model.modelDescription.metadata[.creatorDefinedKey] as? [String: String] ?? [:]
        let labels = creator["classes"].flatMap { $0.data(using: .utf8) }
        guard metadata.modelVersion == Self.version,
              creator["modelVersion"] == Self.version,
              creator["checkpointSHA256"] == metadata.checkpointSHA256,
              creator["experimental"] == "true",
              let labels, try JSONDecoder().decode([String].self, from: labels) == SurfaceClass.allCases.map(\.rawValue) else {
            throw SurfaceClassifierError.invalidMetadata
        }
        imageResizer = try ModelImageResizer(width: metadata.inputWidth, height: metadata.inputHeight)
    }

    static func prediction(probabilities: [Double], enabledApps: Set<SurfaceApp>) throws -> SurfacePrediction {
        try CascadePolicy.validateProbabilities(probabilities, count: 11)
        let classes = SurfaceClass.allCases
        let apps: [SurfaceApp] = [.youtube, .youtube, .instagram, .instagram, .instagram, .other,
                                  .facebook, .facebook, .facebook, .x, .x]
        var totals: [SurfaceApp: Double] = [:]
        var scores: [SurfaceClass: Double] = [:]
        for index in classes.indices {
            totals[apps[index], default: 0] += probabilities[index]
            scores[classes[index]] = enabledApps.contains(apps[index]) || apps[index] == .other ? probabilities[index] : 0
        }
        func conditional(_ index: Int) -> Double {
            let total = totals[apps[index], default: 0]
            return total > 0 ? probabilities[index] / total : 0
        }
        return SurfacePrediction(appProbabilities: totals,
            youtubeContentProbabilities: [.shorts: conditional(0), .normal: conditional(1)],
            instagramContentProbabilities: [.reels: conditional(2), .stories: conditional(3), .normal: conditional(4)],
            facebookContentProbabilities: [.reels: conditional(6), .stories: conditional(7), .normal: conditional(8)],
            xContentProbabilities: [.reels: conditional(9), .normal: conditional(10)], flatProbabilities: scores)
    }

    func predict(pixelBuffer: CVPixelBuffer, enabledApps: Set<SurfaceApp>) throws -> SurfacePrediction {
        let start = ProcessInfo.processInfo.systemUptime
        let buffer = try imageResizer.resize(pixelBuffer)
        let resized = ProcessInfo.processInfo.systemUptime
        let output = try model.prediction(from: MLDictionaryFeatureProvider(dictionary: ["image": MLFeatureValue(pixelBuffer: buffer)]))
        guard let values = output.featureValue(for: "probabilities")?.multiArrayValue else {
            throw SurfaceClassifierError.missingOutput("probabilities")
        }
        var result = try Self.prediction(probabilities: (0..<values.count).map { values[$0].doubleValue }, enabledApps: enabledApps)
        let end = ProcessInfo.processInfo.systemUptime
        result.timings = SurfaceInferenceTimings(resizeMS: (resized-start)*1000, routerMS: 0,
            specialistMS: (end-resized)*1000, totalMS: (end-start)*1000, specialist: "flat11")
        return result
    }

    func copyModelInputBGRA() throws -> (data: Data, width: Int, height: Int, bytesPerRow: Int) {
        let copy = try imageResizer.copyCurrentBGRABytes()
        return (copy.data, imageResizer.width, imageResizer.height, copy.bytesPerRow)
    }
}
