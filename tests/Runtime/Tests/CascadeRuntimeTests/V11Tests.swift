import CoreML
import XCTest
@testable import CascadeRuntime

final class V11Tests: XCTestCase {
    func testQualifiedExportMetadataStillDecodesButIsNotV11() throws {
        var object = document()
        object["qualification"] = ["status": "passed", "reason": NSNull()]
        object["experimental"] = false
        let metadata = try decode(object)
        XCTAssertThrowsError(try metadata.validateExperimentalCreator([:]))
    }
    func testNamedV11ResourcesNeverFallBackToV10() throws {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString + ".bundle")
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: url) }
        try JSONSerialization.data(withJSONObject: document()).write(to: url.appendingPathComponent("SurfaceDetectorMetadata.json"))
        let bundle = try XCTUnwrap(Bundle(url: url))
        XCTAssertThrowsError(try SurfaceClassifier(bundle: bundle, resourceName: "SurfaceDetectorV11"))
        try JSONSerialization.data(withJSONObject: document()).write(to: url.appendingPathComponent("SurfaceDetectorV11Metadata.json"))
        XCTAssertThrowsError(try SurfaceClassifier(bundle: bundle, resourceName: "SurfaceDetectorV11"))
        let corrupt = url.appendingPathComponent("SurfaceDetectorV11.mlmodelc")
        try FileManager.default.createDirectory(at: corrupt, withIntermediateDirectories: true)
        try Data("corrupt model bytes".utf8).write(to: corrupt.appendingPathComponent("model.mil"))
        XCTAssertThrowsError(try SurfaceClassifier(bundle: bundle, resourceName: "SurfaceDetectorV11"))
        XCTAssertThrowsError(try SurfaceClassifier(bundle: bundle, resourceName: "../SurfaceDetector"))
    }

    func testRealExportLoadsPredictsAndRejectsCorruption() throws {
        guard let path = ProcessInfo.processInfo.environment["V11_TEST_BUNDLE"] else {
            throw XCTSkip("Set V11_TEST_BUNDLE to exercise the private exported model")
        }
        let bundle = try XCTUnwrap(Bundle(path: path))
        let classifier = try SurfaceClassifier(bundle: bundle, computeUnits: .cpuOnly, resourceName: "SurfaceDetectorV11")
        XCTAssertEqual(classifier.metadata.modelVersion, "surface-hierarchical-v11-experimental")
        let prediction = try classifier.predict(pixelBuffer: ClassifierTests().buffer(), enabledApps: [.youtube, .instagram])
        XCTAssertEqual(prediction.jointProbabilities.values.reduce(0, +), 1, accuracy: 0.0001)
        XCTAssertEqual(try classifier.copyModelInputBGRA().width, 192)
        // A V11 package paired with V10 metadata must not silently load.
        let url = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString + ".bundle")
        try FileManager.default.copyItem(at: URL(fileURLWithPath: path), to: url)
        defer { try? FileManager.default.removeItem(at: url) }
        var wrong = document()
        wrong["modelVersion"] = "surface-hierarchical-v10"
        try JSONSerialization.data(withJSONObject: wrong).write(to: url.appendingPathComponent("SurfaceDetectorV11Metadata.json"))
        XCTAssertThrowsError(try SurfaceClassifier(bundle: XCTUnwrap(Bundle(url: url)), computeUnits: .cpuOnly, resourceName: "SurfaceDetectorV11"))
    }
    func document() -> [String: Any] {
        ["modelVersion": "surface-hierarchical-v11-experimental",
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
        let valid = ["modelVersion": "surface-hierarchical-v11-experimental",
                     "experimental": "true", "checkpointSHA256": String(repeating: "a", count: 64)]
        let metadata = try decode(document())
        XCTAssertNoThrow(try metadata.validateExperimentalCreator(valid))
        for key in valid.keys {
            var wrong = valid
            wrong[key] = "wrong"
            XCTAssertThrowsError(try metadata.validateExperimentalCreator(wrong))
            wrong[key] = nil
            XCTAssertThrowsError(try metadata.validateExperimentalCreator(wrong))
        }
        for key in ["experimental", "qualification", "checkpointSHA256"] {
            var wrong = document()
            wrong[key] = nil
            XCTAssertThrowsError(try decode(wrong).validateExperimentalCreator(valid))
        }
        var wrong = document()
        wrong["modelVersion"] = "surface-hierarchical-v10"
        XCTAssertThrowsError(try decode(wrong).validateExperimentalCreator(valid))
    }
}
