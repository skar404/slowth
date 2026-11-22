import CoreML
import XCTest
@testable import CascadeRuntime

final class CascadeV6Tests: XCTestCase {
    func privateBundle(_ key: String) throws -> Bundle {
        let path = try requiredModelBundlePath(key)
        return try XCTUnwrap(Bundle(path: path))
    }

    func testRealV6IdentityInferenceAndDisabledSpecialist() throws {
        let bundle = try privateBundle("CASCADE_V6_TEST_BUNDLE")
        let metadata = try CascadeModelMetadata.load(bundle: bundle, candidate: .v6)
        XCTAssertEqual(metadata.modelVersion, "cascade-v6-20260920-124303")
        XCTAssertEqual(metadata.status, "candidate_unverified")
        XCTAssertEqual(metadata.validationStatus, "failed")
        XCTAssertEqual(metadata.policy.temporal.requiredHits, 3)
        let classifier = try CascadeClassifier(bundle: bundle, candidate: .v6, computeUnits: .cpuOnly)
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
                bundle: bundle, candidate: .v6, configuration: configuration)
            try CascadePolicy.validateProbabilities(predictor(buffer), count: component.labels.count)
        }
    }

    func testRealBundleFaultsAndCrossPairingFailClosed() throws {
        let original = try privateBundle("CASCADE_V6_TEST_BUNDLE")
        let v5 = try privateBundle("CASCADE_V5_TEST_BUNDLE")
        let fallback = try privateBundle("V10_TEST_BUNDLE")
        XCTAssertNoThrow(try SurfaceClassifier(bundle: fallback, computeUnits: .cpuOnly))
        let configuration = MLModelConfiguration(); configuration.computeUnits = .cpuOnly
        let metadata = try CascadeModelMetadata.load(bundle: original, candidate: .v6)
        for fault in ["missingMetadata", "corruptMetadata", "changedMetadata", "v5Metadata"] {
            let url = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString + ".bundle")
            try FileManager.default.copyItem(at: original.bundleURL, to: url)
            defer { try? FileManager.default.removeItem(at: url) }
            for name in ["SurfaceDetector.mlmodelc", "SurfaceDetectorMetadata.json"] {
                try FileManager.default.copyItem(at: fallback.bundleURL.appendingPathComponent(name),
                                                 to: url.appendingPathComponent(name))
            }
            let json = url.appendingPathComponent("CascadeV6Metadata.json")
            if fault == "missingMetadata" { try FileManager.default.removeItem(at: json) }
            else if fault == "corruptMetadata" { try Data("broken".utf8).write(to: json) }
            else if fault == "v5Metadata" {
                try Data(contentsOf: XCTUnwrap(v5.url(forResource: "CascadeV5Metadata", withExtension: "json"))).write(to: json)
            } else { var data = try Data(contentsOf: json); data.append(32); try data.write(to: json) }
            XCTAssertThrowsError(try CascadeClassifier(bundle: XCTUnwrap(Bundle(url: url)), candidate: .v6, computeUnits: .cpuOnly), fault)
        }
        for (stage, component) in metadata.components {
            for fault in ["missing", "corrupt", "wrongStage", "v5Model"] {
                let url = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString + ".bundle")
                try FileManager.default.copyItem(at: original.bundleURL, to: url)
                defer { try? FileManager.default.removeItem(at: url) }
                for name in ["SurfaceDetector.mlmodelc", "SurfaceDetectorMetadata.json"] {
                    try FileManager.default.copyItem(at: fallback.bundleURL.appendingPathComponent(name),
                                                     to: url.appendingPathComponent(name))
                }
                let model = url.appendingPathComponent(component.resource + "V6.mlmodelc")
                try FileManager.default.removeItem(at: model)
                if fault == "corrupt" { try FileManager.default.createDirectory(at: model, withIntermediateDirectories: true) }
                if fault == "wrongStage" {
                    let other = stage == "router" ? "YouTubeDetectorV6" : "AppRouterV6"
                    try FileManager.default.copyItem(at: XCTUnwrap(original.url(forResource: other, withExtension: "mlmodelc")), to: model)
                }
                if fault == "v5Model" {
                    try FileManager.default.copyItem(at: XCTUnwrap(v5.url(forResource: component.resource + "V5", withExtension: "mlmodelc")), to: model)
                }
                let bundle = try XCTUnwrap(Bundle(url: url))
                XCTAssertThrowsError(try CascadeClassifier.loadComponent(stage: stage, specification: metadata,
                    bundle: bundle, candidate: .v6, configuration: configuration), "\(stage)/\(fault)")
                if stage == "router" {
                    XCTAssertThrowsError(try CascadeClassifier(bundle: bundle, candidate: .v6, computeUnits: .cpuOnly))
                }
            }
        }
        // Reverse pairing: every V6 component substituted into the original V5 namespace.
        let oldMetadata = try CascadeModelMetadata.load(bundle: v5, candidate: .v5)
        for (stage, component) in oldMetadata.components {
            let url = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString + ".bundle")
            try FileManager.default.copyItem(at: v5.bundleURL, to: url)
            defer { try? FileManager.default.removeItem(at: url) }
            let model = url.appendingPathComponent(component.resource + "V5.mlmodelc")
            try FileManager.default.removeItem(at: model)
            try FileManager.default.copyItem(at: XCTUnwrap(original.url(forResource: component.resource + "V6", withExtension: "mlmodelc")), to: model)
            XCTAssertThrowsError(try CascadeClassifier.loadComponent(stage: stage, specification: oldMetadata,
                bundle: XCTUnwrap(Bundle(url: url)), candidate: .v5, configuration: configuration), stage)
        }
        XCTAssertThrowsError(try CascadeClassifier(bundle: v5, candidate: .v6, computeUnits: .cpuOnly))
        XCTAssertThrowsError(try CascadeClassifier(bundle: original, candidate: .v5, computeUnits: .cpuOnly))
    }
}

extension CascadeV6Tests {
    func testPinnedV6PolicyAbstainsOnUnknownAndDisabledWithoutSpecialist() throws {
        let specification = try CascadeModelMetadata.load(bundle: privateBundle("CASCADE_V6_TEST_BUNDLE"), candidate: .v6)
        for (router, enabled, reason) in [([0.0, 0.0, 1.0], Set([SurfaceApp.youtube, .instagram]), "other"),
                                          ([1.0, 0.0, 0.0], Set<SurfaceApp>(), "disabled")] {
            var stages: [String] = []
            let prediction = try specification.policy.predict(enabledApps: enabled) { stage in
                stages.append(stage)
                return router
            }
            XCTAssertEqual(stages, ["router"])
            XCTAssertEqual(prediction.routing?.reason, reason)
            XCTAssertNil(prediction.topApp); XCTAssertNil(prediction.topClass)
            XCTAssertTrue(prediction.youtubeContentProbabilities.isEmpty)
            XCTAssertTrue(prediction.instagramContentProbabilities.isEmpty)
        }
        XCTAssertEqual(specification.policy.temporal.requiredHits, 3)
        XCTAssertEqual(specification.policy.temporal.windowFrames, 5)
        XCTAssertEqual(specification.policy.temporal.intervalSeconds, 0.25)
    }
}
