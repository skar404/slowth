import CoreML
import XCTest
@testable import CascadeRuntime

final class CascadeV10Tests: XCTestCase {
    func bundle() throws -> Bundle {
        let path = try requiredModelBundlePath("CASCADE_V10_TEST_BUNDLE")
        return try XCTUnwrap(Bundle(path: path))
    }

    func testSelectedV10LoadsAllStagesAndPreservesQualification() throws {
        let bundle = try bundle()
        let spec = try CascadeModelMetadata.load(bundle: bundle, candidate: .v10)
        XCTAssertEqual(spec.modelVersion, "cascade-v10-balanced-20260929-140403-diverse")
        XCTAssertEqual(spec.status, "experimental")
        XCTAssertEqual(spec.validationStatus, "failed")
        XCTAssertEqual(spec.policy.version, 3)
        let config = MLModelConfiguration()
        config.computeUnits = .cpuOnly
        for stage in ["router", "youtube", "instagram", "facebook", "x"] {
            let predict = try CascadeClassifier.loadComponent(stage: stage, specification: spec,
                bundle: bundle, candidate: .v10, configuration: config)
            try CascadePolicy.validateProbabilities(predict(ClassifierTests().buffer()),
                count: spec.components[stage]!.labels.count)
            XCTAssertThrowsError(try CascadeClassifier.loadComponent(stage: stage, specification: spec,
                bundle: bundle, candidate: .v8, configuration: config))
        }
    }

    func testAlteredMetadataAndUnknownFailedCandidateAreRejected() throws {
        let original = try bundle()
        let source = try XCTUnwrap(original.url(forResource: CascadeCandidate.v10.metadataResource, withExtension: "json"))
        var object = try XCTUnwrap(JSONSerialization.jsonObject(with: Data(contentsOf: source)) as? [String: Any])
        object["model_version"] = "unapproved-experimental-candidate"
        XCTAssertThrowsError(try MetadataTests().decode(object).validate())
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString + ".bundle")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        try JSONSerialization.data(withJSONObject: object).write(to: directory.appendingPathComponent(source.lastPathComponent))
        XCTAssertThrowsError(try CascadeModelMetadata.load(bundle: XCTUnwrap(Bundle(url: directory)), candidate: .v10))
    }
}
