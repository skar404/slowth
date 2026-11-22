import CoreML
import XCTest
@testable import CascadeRuntime

final class CascadeV3Tests: XCTestCase {
    func testRealExportLoadsPredictsAndRejectsInvalidResources() throws {
        guard let path = ProcessInfo.processInfo.environment["CASCADE_V3_TEST_BUNDLE"] else {
            throw XCTSkip("Set CASCADE_V3_TEST_BUNDLE to a private compiled V3 bundle")
        }
        let bundle = try XCTUnwrap(Bundle(path: path))
        let metadata = try CascadeModelMetadata.load(bundle: bundle)
        XCTAssertEqual(metadata.modelVersion, "cascade-v3-updated-20260914-100247")
        XCTAssertEqual(metadata.validationStatus, "failed")
        XCTAssertEqual(metadata.policy.temporal.requiredHits, 3)
        let classifier = try CascadeClassifier(bundle: bundle, computeUnits: .cpuOnly)
        let buffer = try ClassifierTests().buffer()
        let prediction = try classifier.predict(pixelBuffer: buffer, enabledApps: [.youtube, .instagram])
        XCTAssertEqual(prediction.appProbabilities.values.reduce(0, +), 1, accuracy: 0.00001)
        XCTAssertEqual(try classifier.copyModelInputBGRA().width, 192)
        let disabled = try classifier.predict(pixelBuffer: buffer, enabledApps: [])
        XCTAssertEqual(disabled.timings?.specialist, "not_run")
        // Exercise every real specialist, even if the synthetic frame abstains.
        for (stage, component) in metadata.components {
            let url = try XCTUnwrap(bundle.url(forResource: component.resource, withExtension: "mlmodelc"))
            let configuration = MLModelConfiguration()
            configuration.computeUnits = .cpuOnly
            let model = try MLModel(contentsOf: url, configuration: configuration)
            let creator = model.modelDescription.metadata[.creatorDefinedKey] as? [String: String]
            try metadata.validateCreator(creator, stage: stage)
            let provider = try MLDictionaryFeatureProvider(dictionary: ["image": MLFeatureValue(pixelBuffer: buffer)])
            let values = try XCTUnwrap(model.prediction(from: provider).featureValue(for: "probabilities")?.multiArrayValue)
            try CascadePolicy.validateProbabilities((0..<values.count).map { values[$0].doubleValue }, count: component.labels.count)
            var wrong = creator ?? [:]
            wrong["checkpoint_sha256"] = String(repeating: "0", count: 64)
            XCTAssertThrowsError(try metadata.validateCreator(wrong, stage: stage))
        }
        // Unique bundles avoid resource lookup caches; never mutate the export.
        for fault in ["missingMetadata", "changedMetadata", "missingRouter", "mismatchedRouter", "corruptRouter"] {
            let url = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString + ".bundle")
            try FileManager.default.copyItem(at: URL(fileURLWithPath: path), to: url)
            defer { try? FileManager.default.removeItem(at: url) }
            let json = url.appendingPathComponent("CascadeMetadata.json")
            let router = url.appendingPathComponent("AppRouter.mlmodelc")
            switch fault {
            case "missingMetadata": try FileManager.default.removeItem(at: json)
            case "changedMetadata":
                var data = try Data(contentsOf: json)
                data.append(contentsOf: [32]) // Still valid JSON, but not the frozen export.
                try data.write(to: json)
            case "missingRouter": try FileManager.default.removeItem(at: router)
            case "mismatchedRouter":
                try FileManager.default.removeItem(at: router)
                try FileManager.default.copyItem(at: url.appendingPathComponent("YouTubeDetector.mlmodelc"), to: router)
            default:
                try FileManager.default.removeItem(at: router)
                try FileManager.default.createDirectory(at: router, withIntermediateDirectories: true)
            }
            XCTAssertThrowsError(try CascadeClassifier(bundle: XCTUnwrap(Bundle(url: url)), computeUnits: .cpuOnly), fault)
        }
    }
}
