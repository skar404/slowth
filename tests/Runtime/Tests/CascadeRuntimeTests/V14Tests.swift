import CoreML
import XCTest
@testable import CascadeRuntime

final class V14Tests: XCTestCase {
    func bundle(_ key: String = "V14_TEST_BUNDLE") throws -> Bundle {
        let path = try requiredModelBundlePath(key)
        return try XCTUnwrap(Bundle(path: path))
    }

    func testRealV14LoadsProductionResizerAndStrictFailedIdentity() throws {
        let original = try bundle()
        let classifier = try SurfaceClassifier(bundle: original, computeUnits: .cpuOnly, resourceName: "SurfaceDetectorV14")
        XCTAssertEqual(classifier.metadata.modelVersion, "surface-hierarchical-v14-experimental")
        XCTAssertEqual(classifier.metadata.checkpointSHA256, "873b918ddfbe994820ce814d55f1c7b3bd90049553eb319c538f96d36f170eb1")
        XCTAssertEqual(classifier.metadata.qualification?.status, "failed")
        XCTAssertEqual(classifier.metadata.experimental, true)
        let prediction = try classifier.predict(pixelBuffer: ClassifierTests().buffer(), enabledApps: [.youtube, .instagram])
        XCTAssertEqual(prediction.jointProbabilities.values.reduce(0, +), 1, accuracy: 0.0001)
        let resized = try classifier.copyModelInputBGRA()
        XCTAssertEqual(resized.width, 192); XCTAssertEqual(resized.height, 384)
        XCTAssertEqual(resized.data[0], 42)
    }

    func testRealV14FaultsAndBidirectionalV12CrossPairingFailClosed() throws {
        let original = try bundle()
        let old = try bundle("V12_TEST_BUNDLE")
        let fallback = try bundle("V10_TEST_BUNDLE")
        XCTAssertNoThrow(try SurfaceClassifier(bundle: fallback, computeUnits: .cpuOnly))
        for fault in ["missingMetadata", "corruptMetadata", "missingModel", "corruptModel", "oldModel", "oldMetadata",
                      "modelVersion", "checkpointSHA256", "experimental", "qualification"] {
            let url = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString + ".bundle")
            try FileManager.default.copyItem(at: original.bundleURL, to: url)
            defer { try? FileManager.default.removeItem(at: url) }
            // A valid ordinary model must not mask a broken selected candidate.
            for name in ["SurfaceDetector.mlmodelc", "SurfaceDetectorMetadata.json"] {
                try FileManager.default.copyItem(at: fallback.bundleURL.appendingPathComponent(name),
                                                 to: url.appendingPathComponent(name))
            }
            let json = url.appendingPathComponent("SurfaceDetectorV14Metadata.json")
            let model = url.appendingPathComponent("SurfaceDetectorV14.mlmodelc")
            switch fault {
            case "missingMetadata": try FileManager.default.removeItem(at: json)
            case "corruptMetadata": try Data("broken".utf8).write(to: json)
            case "oldMetadata": try Data(contentsOf: XCTUnwrap(old.url(forResource: "SurfaceDetectorV12Metadata", withExtension: "json"))).write(to: json)
            case "missingModel", "corruptModel", "oldModel":
                try FileManager.default.removeItem(at: model)
                if fault == "corruptModel" { try FileManager.default.createDirectory(at: model, withIntermediateDirectories: true) }
                if fault == "oldModel" { try FileManager.default.copyItem(at: XCTUnwrap(old.url(forResource: "SurfaceDetectorV12", withExtension: "mlmodelc")), to: model) }
            default:
                var object = try XCTUnwrap(JSONSerialization.jsonObject(with: Data(contentsOf: json)) as? [String: Any])
                switch fault {
                case "modelVersion": object[fault] = "surface-hierarchical-v999-experimental"
                case "checkpointSHA256": object[fault] = String(repeating: "0", count: 64)
                case "experimental": object[fault] = false
                default: object[fault] = ["status": "passed"]
                }
                try JSONSerialization.data(withJSONObject: object).write(to: json)
            }
            XCTAssertThrowsError(try SurfaceClassifier(bundle: XCTUnwrap(Bundle(url: url)), computeUnits: .cpuOnly, resourceName: "SurfaceDetectorV14"), fault)
        }
        let url = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString + ".bundle")
        try FileManager.default.copyItem(at: old.bundleURL, to: url)
        defer { try? FileManager.default.removeItem(at: url) }
        let model = url.appendingPathComponent("SurfaceDetectorV12.mlmodelc")
        try FileManager.default.removeItem(at: model)
        try FileManager.default.copyItem(at: XCTUnwrap(original.url(forResource: "SurfaceDetectorV14", withExtension: "mlmodelc")), to: model)
        XCTAssertThrowsError(try SurfaceClassifier(bundle: XCTUnwrap(Bundle(url: url)), computeUnits: .cpuOnly, resourceName: "SurfaceDetectorV12"))
    }

    func testV5FrozenMetadataAcceptedWithoutChangingQualification() throws {
        let original = try bundle("CASCADE_V5_TEST_BUNDLE")
        let decoder = JSONDecoder(); decoder.keyDecodingStrategy = .convertFromSnakeCase
        let metadata = try decoder.decode(CascadeModelMetadata.self,
            from: Data(contentsOf: XCTUnwrap(original.url(forResource: "CascadeV5Metadata", withExtension: "json"))))
        XCTAssertEqual(metadata.modelVersion, "cascade-v5-20260920-1018")
        XCTAssertEqual(metadata.validationStatus, "failed")
        XCTAssertEqual(metadata.status, "candidate_unverified")
        XCTAssertNoThrow(try metadata.validate())
    }
}
