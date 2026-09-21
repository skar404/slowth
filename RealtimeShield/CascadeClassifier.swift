import CoreML
import CoreVideo
import Foundation

/// Experimental cascade backend, selected through the runtime Debug menu.
final class CascadeClassifier: SurfaceClassifying {
    typealias StagePredictor = (CVPixelBuffer) throws -> [Double]
    typealias StageLoader = (String) throws -> StagePredictor

    let metadata: SurfaceModelMetadata
    private let specification: CascadeModelMetadata
    private let loadStage: StageLoader
    private var stages: [String: StagePredictor] = [:]
    private let resizer: ModelImageResizer

    convenience init(bundle: Bundle = .main, candidate: CascadeCandidate = .v3,
                     computeUnits: MLComputeUnits = .cpuAndNeuralEngine) throws {
        let specification = try CascadeModelMetadata.load(bundle: bundle, candidate: candidate)
        let configuration = MLModelConfiguration()
        configuration.computeUnits = computeUnits
        try self.init(specification: specification) { stage in
            try Self.loadComponent(stage: stage, specification: specification, bundle: bundle,
                                   candidate: candidate, configuration: configuration)
        }
    }

    /// Shared by lazy production loads and real compiled-bundle substitution tests.
    static func loadComponent(stage: String, specification: CascadeModelMetadata,
                              bundle: Bundle, candidate: CascadeCandidate,
                              configuration: MLModelConfiguration) throws -> StagePredictor {
        guard specification.modelVersion == candidate.modelVersion,
              let component = specification.components[stage],
              let url = bundle.url(forResource: candidate.resource(component.resource), withExtension: "mlmodelc") else {
            throw CascadeClassifierError.missing(stage)
        }
        let model = try MLModel(contentsOf: url, configuration: configuration)
        let creator = model.modelDescription.metadata[.creatorDefinedKey] as? [String: String]
        try specification.validateCreator(creator, stage: stage)
        return { buffer in
            let provider = try MLDictionaryFeatureProvider(dictionary: ["image": MLFeatureValue(pixelBuffer: buffer)])
            guard let array = try model.prediction(from: provider)
                .featureValue(for: "probabilities")?.multiArrayValue else {
                throw CascadeClassifierError.invalid("output: \(stage)")
            }
            return (0..<array.count).map { array[$0].doubleValue }
        }
    }

    /// The same loader/cache path is exercised without real model resources in XCTest.
    init(specification: CascadeModelMetadata, loadStage: @escaping StageLoader) throws {
        try specification.validate()
        self.specification = specification
        self.loadStage = loadStage
        metadata = specification.surfaceMetadata
        resizer = try ModelImageResizer(width: specification.input.width, height: specification.input.height)
        stages["router"] = try loadStage("router")
    }

    func copyModelInputBGRA() throws -> (data: Data, width: Int, height: Int, bytesPerRow: Int) {
        let copy = try resizer.copyCurrentBGRABytes()
        return (copy.data, resizer.width, resizer.height, copy.bytesPerRow)
    }

    func predict(pixelBuffer: CVPixelBuffer, enabledApps: Set<SurfaceApp>) throws -> SurfacePrediction {
        let startedAt = ProcessInfo.processInfo.systemUptime
        let buffer = try resizer.resize(pixelBuffer)
        let resizeMS = (ProcessInfo.processInfo.systemUptime - startedAt) * 1_000
        var routerMS = 0.0
        var specialistMS: Double?
        var specialist = "not_run"
        var prediction = try specification.policy.predict(enabledApps: enabledApps) { stage in
            let stageStart = ProcessInfo.processInfo.systemUptime
            if stages[stage] == nil { stages[stage] = try loadStage(stage) }
            guard let predictor = stages[stage] else { throw CascadeClassifierError.missing(stage) }
            let values = try predictor(buffer)
            let elapsed = (ProcessInfo.processInfo.systemUptime - stageStart) * 1_000
            if stage == "router" { routerMS = elapsed }
            else { specialistMS = elapsed; specialist = stage }
            return values
        }
        prediction.timings = SurfaceInferenceTimings(resizeMS: resizeMS, routerMS: routerMS,
            specialistMS: specialistMS, totalMS: (ProcessInfo.processInfo.systemUptime - startedAt) * 1_000,
            specialist: specialist)
        return prediction
    }
}

enum SurfaceClassifierFactory {
    static func make(backend: DebugModelBackend = DebugModelSettings.defaultBackend) throws -> any SurfaceClassifying {
        #if DEBUG
        switch backend {
        case .v14:
            return try SurfaceClassifier(resourceName: "SurfaceDetectorV14")
        case .v15:
            #if CASCADE_MODEL && os(iOS)
            return try SurfaceClassifier(resourceName: "SurfaceDetectorV15")
            #else
            throw CascadeClassifierError.missing("V15 support in this build")
            #endif
        case .cascadeV6:
            #if CASCADE_MODEL && os(iOS)
            return try CascadeClassifier(candidate: .v6)
            #else
            throw CascadeClassifierError.missing("Cascade V6 support in this build")
            #endif
        }
        #else
        return try CascadeClassifier(candidate: .v6)
        #endif
    }
}
