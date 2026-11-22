import CoreML
import XCTest
@testable import CascadeRuntime

final class V12Tests: XCTestCase {
    func testV12AcceptsGenuinelyPassedAndFailedOutcomes() throws {
        var object = document()
        let identity = ["modelVersion": "surface-hierarchical-v12-experimental",
                        "checkpointSHA256": String(repeating: "a", count: 64), "experimental": "false"]
        object["qualification"] = ["status": "passed", "reason": NSNull()]
        object["experimental"] = false
        XCTAssertNoThrow(try decode(object).validateV12Creator(identity))
        object["experimental"] = true
        XCTAssertThrowsError(try decode(object).validateV12Creator(identity))
        object["experimental"] = false
        object["qualification"] = ["status": "failed", "reason": "recall"]
        XCTAssertThrowsError(try decode(object).validateV12Creator(identity))
        object["qualification"] = ["status": "passed", "reason": "unexpected failure reason"]
        XCTAssertThrowsError(try decode(object).validateV12Creator(identity))
        object["qualification"] = ["status": "unknown"]
        XCTAssertThrowsError(try decode(object).validateV12Creator(identity))
    }
    func testNamedV12ResourcesNeverFallBackToV10() throws {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString + ".bundle")
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: url) }
        try JSONSerialization.data(withJSONObject: document()).write(to: url.appendingPathComponent("SurfaceDetectorMetadata.json"))
        let bundle = try XCTUnwrap(Bundle(url: url))
        XCTAssertThrowsError(try SurfaceClassifier(bundle: bundle, resourceName: "SurfaceDetectorV12"))
        try JSONSerialization.data(withJSONObject: document()).write(to: url.appendingPathComponent("SurfaceDetectorV12Metadata.json"))
        XCTAssertThrowsError(try SurfaceClassifier(bundle: bundle, resourceName: "SurfaceDetectorV12"))
        let corrupt = url.appendingPathComponent("SurfaceDetectorV12.mlmodelc")
        try FileManager.default.createDirectory(at: corrupt, withIntermediateDirectories: true)
        try Data("corrupt model bytes".utf8).write(to: corrupt.appendingPathComponent("model.mil"))
        XCTAssertThrowsError(try SurfaceClassifier(bundle: bundle, resourceName: "SurfaceDetectorV12"))
        XCTAssertThrowsError(try SurfaceClassifier(bundle: bundle, resourceName: "../SurfaceDetector"))
    }

    func testRealExportLoadsPredictsAndRejectsCorruption() throws {
        guard let path = ProcessInfo.processInfo.environment["V12_TEST_BUNDLE"] else {
            throw XCTSkip("Set V12_TEST_BUNDLE to exercise the private exported model")
        }
        let bundle = try XCTUnwrap(Bundle(path: path))
        let classifier = try SurfaceClassifier(bundle: bundle, computeUnits: .cpuOnly, resourceName: "SurfaceDetectorV12")
        XCTAssertEqual(classifier.metadata.modelVersion, "surface-hierarchical-v12-experimental")
        let prediction = try classifier.predict(pixelBuffer: ClassifierTests().buffer(), enabledApps: [.youtube, .instagram])
        XCTAssertEqual(prediction.jointProbabilities.values.reduce(0, +), 1, accuracy: 0.0001)
        XCTAssertEqual(try classifier.copyModelInputBGRA().width, 192)
        // A V12 package paired with V10 metadata must not silently load.
        let url = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString + ".bundle")
        try FileManager.default.copyItem(at: URL(fileURLWithPath: path), to: url)
        defer { try? FileManager.default.removeItem(at: url) }
        var wrong = document()
        wrong["modelVersion"] = "surface-hierarchical-v11-experimental"
        try JSONSerialization.data(withJSONObject: wrong).write(to: url.appendingPathComponent("SurfaceDetectorV12Metadata.json"))
        XCTAssertThrowsError(try SurfaceClassifier(bundle: XCTUnwrap(Bundle(url: url)), computeUnits: .cpuOnly, resourceName: "SurfaceDetectorV12"))
    }
    func testRealBundleIdentityAndCrossVersionPairing() throws {
        guard let path = ProcessInfo.processInfo.environment["V12_TEST_BUNDLE"] else {
            throw XCTSkip("Set V12_TEST_BUNDLE to exercise the private exported model")
        }
        let bundle = try XCTUnwrap(Bundle(path: path))
        let configuration = MLModelConfiguration()
        configuration.computeUnits = .cpuOnly
        let model = try MLModel(contentsOf: XCTUnwrap(bundle.url(forResource: "SurfaceDetectorV12", withExtension: "mlmodelc")), configuration: configuration)
        let creator = try XCTUnwrap(model.modelDescription.metadata[.creatorDefinedKey] as? [String: String])
        let metadata = try SurfaceModelMetadata.load(bundle: bundle, resourceName: "SurfaceDetectorV12Metadata")
        XCTAssertEqual(metadata.modelVersion, "surface-hierarchical-v12-experimental")
        XCTAssertNoThrow(try metadata.validateV12Creator(creator))
        // Direct CoreML inference is independent of the IOSurface resizer test above.
        // Keep both checks: a CPU prediction must not hide a production resize failure.
        let input = try MLDictionaryFeatureProvider(dictionary: [
            "image": MLFeatureValue(pixelBuffer: ClassifierTests().buffer())
        ])
        let prediction = try model.prediction(from: input)
        for (name, count) in [("appProbabilities", 3), ("youtubeContentProbabilities", 2),
                              ("instagramContentProbabilities", 3)] {
            let values = try XCTUnwrap(prediction.featureValue(for: name)?.multiArrayValue)
            XCTAssertEqual(values.count, count)
            let probabilities = (0..<values.count).map { values[$0].doubleValue }
            XCTAssertTrue(probabilities.allSatisfy { $0.isFinite && $0 >= 0 && $0 <= 1 })
            XCTAssertEqual(probabilities.reduce(0, +), 1, accuracy: 0.0001)
        }

        let url = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString + ".bundle")
        try FileManager.default.copyItem(at: URL(fileURLWithPath: path), to: url)
        defer { try? FileManager.default.removeItem(at: url) }
        let metadataURL = url.appendingPathComponent("SurfaceDetectorV12Metadata.json")
        let original = try XCTUnwrap(JSONSerialization.jsonObject(with: Data(contentsOf: metadataURL)) as? [String: Any])
        for field in ["modelVersion", "checkpointSHA256", "experimental", "qualification"] {
            var wrong = original
            switch field {
            case "modelVersion": wrong[field] = "surface-hierarchical-v11-experimental"
            case "checkpointSHA256": wrong[field] = String(repeating: "0", count: 64)
            case "experimental": wrong[field] = !(original[field] as? Bool ?? false)
            default: wrong[field] = ["status": "unknown"]
            }
            try JSONSerialization.data(withJSONObject: wrong).write(to: metadataURL)
            XCTAssertThrowsError(try SurfaceClassifier(bundle: XCTUnwrap(Bundle(url: url)), computeUnits: .cpuOnly, resourceName: "SurfaceDetectorV12")) { error in
                guard case SurfaceClassifierError.invalidMetadata = error else {
                    return XCTFail("Expected identity rejection, got \(error)")
                }
            }
        }
    }

    func document() -> [String: Any] {
        ["modelVersion": "surface-hierarchical-v12-experimental",
         "appLabels": ["youtube", "instagram", "other"],
         "youtubeContentLabels": ["shorts", "normal"],
         "instagramContentLabels": ["reels", "stories", "normal"],
         "inputWidth": 192, "inputHeight": 384,
         "confidenceThresholds": ["youtube_shorts": 0.9, "instagram_reels": 0.8, "instagram_stories": 0.7],
         "inferenceIntervalSeconds": 0.25, "requiredConsecutiveHits": 3, "observationWindowFrames": 5,
         "experimental": true, "qualification": ["status": "failed", "reason": "validation recall"],
         "checkpointSHA256": String(repeating: "a", count: 64)]
    }
    func decode(_ object: [String: Any]) throws -> SurfaceModelMetadata {
        try JSONDecoder().decode(SurfaceModelMetadata.self, from: JSONSerialization.data(withJSONObject: object))
    }
    func testExperimentalIdentityRejectsMissingMismatchedAndQualifiedMetadata() throws {
        let valid = ["modelVersion": "surface-hierarchical-v12-experimental",
                     "experimental": "true", "checkpointSHA256": String(repeating: "a", count: 64)]
        let metadata = try decode(document())
        XCTAssertNoThrow(try metadata.validateV12Creator(valid))
        for key in valid.keys {
            var wrong = valid
            wrong[key] = "wrong"
            XCTAssertThrowsError(try metadata.validateV12Creator(wrong))
            wrong[key] = nil
            XCTAssertThrowsError(try metadata.validateV12Creator(wrong))
        }
        for key in ["experimental", "qualification", "checkpointSHA256"] {
            var wrong = document()
            wrong[key] = nil
            XCTAssertThrowsError(try decode(wrong).validateV12Creator(valid))
        }
        var wrong = document()
        wrong["modelVersion"] = "surface-hierarchical-v10"
        XCTAssertThrowsError(try decode(wrong).validateV12Creator(valid))
    }
}
