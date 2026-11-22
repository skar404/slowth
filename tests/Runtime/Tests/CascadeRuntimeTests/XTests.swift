import XCTest
import CoreML
@testable import CascadeRuntime

final class XTests: XCTestCase {
    func metadata() throws -> CascadeModelMetadata {
        var object = try MetadataTests().document()
        object["contract"] = "v8"
        var components = object["components"] as! [String: [String: Any]]
        components["router"]!["labels"] = ["youtube", "instagram", "other", "facebook", "x"]
        for (stage, resource, labels) in [("facebook", "FacebookDetector", ["reels", "stories", "normal"]),
                                           ("x", "XDetector", ["reels", "normal"])] {
            components[stage] = ["resource": resource, "labels": labels,
                                 "checkpoint_sha256": String(repeating: "a", count: 64)]
        }
        object["components"] = components
        var policy = object["policy"] as! [String: Any]
        policy["version"] = 3
        var routing = policy["routing"] as! [String: Any]
        routing["facebook"] = ["confidence": 0.6, "margin": 0.2]
        routing["x"] = ["confidence": 0.6, "margin": 0.2]
        policy["routing"] = routing
        var thresholds = policy["thresholds"] as! [String: Double]
        for target in ["facebook_reels", "facebook_stories", "x_reels"] { thresholds[target] = 0.6 }
        policy["thresholds"] = thresholds
        object["policy"] = policy
        return try MetadataTests().decode(object)
    }

    func testXUsesOnlyItsSpecialistAndNormalRemainsNegative() throws {
        let metadata = try metadata()
        try metadata.validate()
        for (content, expected) in [([0.8, 0.2], SurfaceClass.xReels), ([0.01, 0.99], .xNormal)] {
            var executed: [String] = []
            let prediction = try metadata.policy.predict(enabledApps: [.x]) { stage in
                executed.append(stage)
                return stage == "router" ? [0.02, 0.02, 0.03, 0.03, 0.9] : content
            }
            XCTAssertEqual(executed, ["router", "x"])
            XCTAssertEqual(prediction.topApp, .x)
            XCTAssertEqual(prediction.topClass, expected)
            XCTAssertEqual(prediction.probability(for: .xReels), 0.9 * content[0], accuracy: 1e-12)
            XCTAssertEqual(prediction.probability(for: .facebookReels), 0)
        }
    }

    func testDisabledXSkipsSpecialistAndV7RejectsNewRouterWidth() throws {
        let metadata = try metadata()
        var executed: [String] = []
        let prediction = try metadata.policy.predict(enabledApps: [.facebook]) { stage in
            executed.append(stage)
            return [0.02, 0.02, 0.03, 0.03, 0.9]
        }
        XCTAssertEqual(executed, ["router"])
        XCTAssertNil(prediction.topClass)
        XCTAssertEqual(prediction.probability(for: .xReels), 0)
        XCTAssertThrowsError(try FacebookTests().metadata().policy.route([0.02, 0.02, 0.03, 0.03, 0.9]))
        XCTAssertEqual(CascadePolicy.enabledApps(youtube: false, reels: false, stories: false, xReels: true), [.x])
    }

    func testFrozenV8BundleLoadsAllComponents() throws {
        guard let path = ProcessInfo.processInfo.environment["CASCADE_V8_TEST_BUNDLE"] else {
            throw XCTSkip("Set CASCADE_V8_TEST_BUNDLE to the compiled V8 bundle")
        }
        let bundle = try XCTUnwrap(Bundle(path: path))
        let spec = try CascadeModelMetadata.load(bundle: bundle, candidate: .v8)
        XCTAssertEqual(spec.policy.version, 3)
        let config = MLModelConfiguration()
        config.computeUnits = .cpuOnly
        let buffer = try ClassifierTests().buffer()
        for stage in ["router", "youtube", "instagram", "facebook", "x"] {
            let predictor = try CascadeClassifier.loadComponent(stage: stage, specification: spec,
                bundle: bundle, candidate: .v8, configuration: config)
            try CascadePolicy.validateProbabilities(predictor(buffer), count: spec.components[stage]!.labels.count)
        }
    }
}
