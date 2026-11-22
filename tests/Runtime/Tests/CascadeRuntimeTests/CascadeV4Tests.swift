import CoreML
import XCTest
@testable import CascadeRuntime

final class CascadeV4Tests: XCTestCase {
    func privateBundle(_ key: String) throws -> Bundle {
        guard let path = ProcessInfo.processInfo.environment[key] else {
            throw XCTSkip("Set \(key) to a private Mac-compiled bundle")
        }
        return try XCTUnwrap(Bundle(path: path))
    }

    func testRealV4IdentityInferenceAndDisabledSpecialist() throws {
        let bundle = try privateBundle("CASCADE_V4_TEST_BUNDLE")
        let metadata = try CascadeModelMetadata.load(bundle: bundle, candidate: .v4)
        XCTAssertEqual(metadata.modelVersion, "cascade-v4-20260919")
        XCTAssertEqual(metadata.status, "candidate_unverified")
        XCTAssertEqual(metadata.validationStatus, "failed")
        XCTAssertEqual(metadata.policy.temporal.requiredHits, 3)
        let classifier = try CascadeClassifier(bundle: bundle, candidate: .v4, computeUnits: .cpuOnly)
        XCTAssertEqual(classifier.metadata.modelVersion, metadata.modelVersion)
        let buffer = try ClassifierTests().buffer()
        let prediction = try classifier.predict(pixelBuffer: buffer, enabledApps: [.youtube, .instagram])
        XCTAssertEqual(prediction.appProbabilities.values.reduce(0, +), 1, accuracy: 0.00001)
        XCTAssertEqual(try classifier.copyModelInputBGRA().width, 192)
        let disabled = try classifier.predict(pixelBuffer: buffer, enabledApps: [])
        XCTAssertEqual(disabled.timings?.specialist, "not_run")
        XCTAssertTrue(disabled.youtubeContentProbabilities.isEmpty)
        XCTAssertTrue(disabled.instagramContentProbabilities.isEmpty)
        let configuration = MLModelConfiguration(); configuration.computeUnits = .cpuOnly
        for (stage, component) in metadata.components {
            let predictor = try CascadeClassifier.loadComponent(stage: stage, specification: metadata,
                bundle: bundle, candidate: .v4, configuration: configuration)
            try CascadePolicy.validateProbabilities(predictor(buffer), count: component.labels.count)
        }
    }

    func testRealBundleFaultsAndCrossPairingFailClosed() throws {
        let original = try privateBundle("CASCADE_V4_TEST_BUNDLE")
        let v3 = try privateBundle("CASCADE_V3_TEST_BUNDLE")
        let configuration = MLModelConfiguration(); configuration.computeUnits = .cpuOnly
        let metadata = try CascadeModelMetadata.load(bundle: original, candidate: .v4)
        for fault in ["missingMetadata", "corruptMetadata", "changedMetadata", "v3Metadata"] {
            let url = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString + ".bundle")
            try FileManager.default.copyItem(at: original.bundleURL, to: url)
            defer { try? FileManager.default.removeItem(at: url) }
            let json = url.appendingPathComponent("CascadeV4Metadata.json")
            if fault == "missingMetadata" { try FileManager.default.removeItem(at: json) }
            else if fault == "corruptMetadata" { try Data("broken".utf8).write(to: json) }
            else if fault == "v3Metadata" {
                try Data(contentsOf: XCTUnwrap(v3.url(forResource: "CascadeMetadata", withExtension: "json"))).write(to: json)
            } else { var data = try Data(contentsOf: json); data.append(32); try data.write(to: json) }
            XCTAssertThrowsError(try CascadeClassifier(bundle: XCTUnwrap(Bundle(url: url)), candidate: .v4, computeUnits: .cpuOnly), fault)
        }
        for (stage, component) in metadata.components {
            for fault in ["missing", "corrupt", "wrongStage", "v3Model"] {
                let url = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString + ".bundle")
                try FileManager.default.copyItem(at: original.bundleURL, to: url)
                defer { try? FileManager.default.removeItem(at: url) }
                let model = url.appendingPathComponent(component.resource + "V4.mlmodelc")
                try FileManager.default.removeItem(at: model)
                if fault == "corrupt" { try FileManager.default.createDirectory(at: model, withIntermediateDirectories: true) }
                if fault == "wrongStage" {
                    let other = stage == "router" ? "YouTubeDetectorV4" : "AppRouterV4"
                    try FileManager.default.copyItem(at: XCTUnwrap(original.url(forResource: other, withExtension: "mlmodelc")), to: model)
                }
                if fault == "v3Model" {
                    try FileManager.default.copyItem(at: XCTUnwrap(v3.url(forResource: component.resource, withExtension: "mlmodelc")), to: model)
                }
                let bundle = try XCTUnwrap(Bundle(url: url))
                XCTAssertThrowsError(try CascadeClassifier.loadComponent(stage: stage, specification: metadata,
                    bundle: bundle, candidate: .v4, configuration: configuration), "\(stage)/\(fault)")
                if stage == "router" {
                    XCTAssertThrowsError(try CascadeClassifier(bundle: bundle, candidate: .v4, computeUnits: .cpuOnly))
                }
            }
        }
        // Reverse pairing: V4 component substituted into the original V3 namespace.
        let url = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString + ".bundle")
        try FileManager.default.copyItem(at: v3.bundleURL, to: url)
        defer { try? FileManager.default.removeItem(at: url) }
        let router = url.appendingPathComponent("AppRouter.mlmodelc")
        try FileManager.default.removeItem(at: router)
        try FileManager.default.copyItem(at: XCTUnwrap(original.url(forResource: "AppRouterV4", withExtension: "mlmodelc")), to: router)
        XCTAssertThrowsError(try CascadeClassifier(bundle: XCTUnwrap(Bundle(url: url)), computeUnits: .cpuOnly))
        XCTAssertThrowsError(try CascadeClassifier(bundle: v3, candidate: .v4, computeUnits: .cpuOnly))
        XCTAssertThrowsError(try CascadeClassifier(bundle: original, candidate: .v3, computeUnits: .cpuOnly))
    }
}
