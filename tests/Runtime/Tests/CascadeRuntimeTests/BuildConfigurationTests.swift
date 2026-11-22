import CoreML
import XCTest
@testable import CascadeRuntime

final class BuildConfigurationTests: XCTestCase {
    func testFlat15IsTheSharedDefault() {
        XCTAssertEqual(ModelSettings.defaultBackend, .flat15)
        XCTAssertTrue(ModelBackend.flat15.supportsFacebook)
        XCTAssertTrue(ModelBackend.flat15.supportsX)
    }
    func testSavedDebugFlagCannotEnableToolsInRelease() {
        XCTAssertFalse(DebugMode.resolve(stored: false))
        #if DEBUG
        XCTAssertTrue(DebugMode.resolve(stored: true))
        #else
        XCTAssertFalse(DebugMode.resolve(stored: true))
        XCTAssertFalse(DebugMode.isEnabled)
        XCTAssertTrue(FeatureFlags.tipsEnabled) // Donations are enabled in production.
        XCTAssertEqual(ModelSettings.defaultBackend, .flat15)
        XCTAssertEqual(ModelBackend.allCases, [.cascadeV6, .cascadeV7, .cascadeV8, .cascadeV10, .flat11, .flat12, .flat13, .flat14, .flat15])
        #endif
    }

    #if !DEBUG
    func testHistoricalReleaseCascadeLoadsCompactMetadataAndRunsInference() throws {
        let path = try requiredModelBundlePath("CASCADE_RELEASE_TEST_BUNDLE")
        let bundle = try XCTUnwrap(Bundle(path: path))
        XCTAssertEqual(CascadeCandidate.v10.metadataResource, "CascadeV10RuntimeMetadata")
        let classifier = try CascadeClassifier(bundle: bundle, candidate: .v10, computeUnits: .cpuOnly)
        XCTAssertEqual(classifier.metadata.modelVersion, CascadeCandidate.v10.modelVersion)
        let prediction = try classifier.predict(pixelBuffer: ClassifierTests().buffer(),
                                                enabledApps: [.youtube, .instagram, .facebook, .x])
        XCTAssertEqual(prediction.appProbabilities.values.reduce(0, +), 1, accuracy: 0.00001)
        // Load every specialist even if the synthetic input causes the router to abstain.
        let specification = try CascadeModelMetadata.load(bundle: bundle, candidate: .v10)
        let config = MLModelConfiguration()
        config.computeUnits = .cpuOnly
        for stage in specification.components.keys {
            let predictor = try CascadeClassifier.loadComponent(stage: stage, specification: specification,
                bundle: bundle, candidate: .v10, configuration: config)
            XCTAssertEqual(try predictor(ClassifierTests().buffer()).reduce(0, +), 1, accuracy: 0.00001)
        }
    }

    func testHistoricalReleaseCascadeRejectsAlteredCompactMetadata() throws {
        let path = try requiredModelBundlePath("CASCADE_RELEASE_TEST_BUNDLE")
        let source = URL(fileURLWithPath: path).appendingPathComponent("CascadeV10RuntimeMetadata.json")
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString + ".bundle")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        var document = try XCTUnwrap(JSONSerialization.jsonObject(with: Data(contentsOf: source)) as? [String: Any])
        document["validation_status"] = "passed"
        try JSONSerialization.data(withJSONObject: document).write(to: directory.appendingPathComponent(source.lastPathComponent))
        XCTAssertThrowsError(try CascadeModelMetadata.load(bundle: XCTUnwrap(Bundle(url: directory)), candidate: .v10))
    }
    #endif
}
