import XCTest
import CoreML
@testable import CascadeRuntime

final class FacebookTests: XCTestCase {
    func metadata() throws -> CascadeModelMetadata {
        var object = try MetadataTests().document()
        object["contract"] = "v7"
        var components = object["components"] as! [String: [String: Any]]
        components["router"]!["labels"] = ["youtube", "instagram", "other", "facebook"]
        components["facebook"] = ["resource": "FacebookDetector", "labels": ["reels", "stories", "normal"],
                                  "checkpoint_sha256": String(repeating: "a", count: 64)]
        object["components"] = components
        var policy = object["policy"] as! [String: Any]
        policy["version"] = 2
        var routing = policy["routing"] as! [String: Any]
        routing["facebook"] = ["confidence": 0.6, "margin": 0.2]
        policy["routing"] = routing
        var thresholds = policy["thresholds"] as! [String: Double]
        thresholds["facebook_reels"] = 0.6
        thresholds["facebook_stories"] = 0.6
        policy["thresholds"] = thresholds
        object["policy"] = policy
        return try MetadataTests().decode(object)
    }

    func testFrozenBundledV7MetadataAndAllComponents() throws {
        guard let path = ProcessInfo.processInfo.environment["CASCADE_V7_TEST_BUNDLE"] else {
            throw XCTSkip("Set CASCADE_V7_TEST_BUNDLE to the compiled experimental app bundle")
        }
        let bundle = try XCTUnwrap(Bundle(path: path))
        let specification = try CascadeModelMetadata.load(bundle: bundle, candidate: .v7)
        XCTAssertEqual(specification.status, "experimental")
        XCTAssertEqual(specification.validationStatus, "failed")
        XCTAssertEqual(specification.policy.version, 2)
        let config = MLModelConfiguration()
        config.computeUnits = .cpuOnly
        let buffer = try ClassifierTests().buffer()
        for stage in ["router", "youtube", "instagram", "facebook"] {
            let predictor = try CascadeClassifier.loadComponent(stage: stage, specification: specification,
                bundle: bundle, candidate: .v7, configuration: config)
            try CascadePolicy.validateProbabilities(predictor(buffer), count: specification.components[stage]!.labels.count)
        }
    }

    func testRuntimeMetadataPreservesFrozenPolicyAndComponentIdentity() throws {
        guard let path = ProcessInfo.processInfo.environment["CASCADE_V7_SOURCE_METADATA"],
              let runtimePath = ProcessInfo.processInfo.environment["CASCADE_V7_RUNTIME_METADATA"] else {
            throw XCTSkip("Set source and runtime V7 metadata paths")
        }
        let source = try XCTUnwrap(JSONSerialization.jsonObject(with: Data(contentsOf: URL(fileURLWithPath: path))) as? [String: Any])
        let runtime = try XCTUnwrap(JSONSerialization.jsonObject(with: Data(contentsOf: URL(fileURLWithPath: runtimePath))) as? [String: Any])
        for key in ["schema_version", "contract", "model_version", "architecture", "input", "policy", "validation_status", "compute_precision", "status"] {
            XCTAssertEqual(try JSONSerialization.data(withJSONObject: ["value": source[key]!], options: .sortedKeys),
                           try JSONSerialization.data(withJSONObject: ["value": runtime[key]!], options: .sortedKeys), key)
        }
        let components = try XCTUnwrap(runtime["components"] as? [String: [String: Any]])
        let original = try XCTUnwrap(source["components"] as? [String: [String: Any]])
        for (stage, component) in components {
            XCTAssertEqual(Set(component.keys), ["resource", "labels", "checkpoint_sha256"])
            for key in component.keys {
                XCTAssertEqual(String(describing: component[key]!), String(describing: original[stage]![key]!), key)
            }
        }
        XCTAssertNil(runtime["calibration_inventory"])
        XCTAssertNil(runtime["manifest_sha256"])
    }

    func testFacebookRoutesOnlyOneSpecialistAndUsesJointScores() throws {
        let metadata = try metadata()
        try metadata.validate()
        var executed: [String] = []
        let prediction = try metadata.policy.predict(enabledApps: [.youtube, .instagram, .facebook]) { stage in
            executed.append(stage)
            return stage == "router" ? [0.03, 0.03, 0.04, 0.9] : [0.8, 0.1, 0.1]
        }
        XCTAssertEqual(executed, ["router", "facebook"])
        XCTAssertEqual(prediction.topApp, .facebook)
        XCTAssertEqual(prediction.topClass, .facebookReels)
        XCTAssertEqual(prediction.probability(for: .facebookReels), 0.72, accuracy: 1e-12)
        XCTAssertEqual(prediction.probability(for: .instagramReels), 0)
    }

    func testDisabledFacebookAndAbstentionSkipSpecialist() throws {
        let policy = try metadata().policy
        for values in [[0.03, 0.03, 0.04, 0.9], [0.05, 0.05, 0.8, 0.1], [0.2, 0.2, 0.2, 0.4]] {
            var executed: [String] = []
            let prediction = try policy.predict(enabledApps: [.youtube, .instagram]) { stage in
                executed.append(stage)
                return values
            }
            XCTAssertEqual(executed, ["router"])
            XCTAssertNil(prediction.topClass)
            XCTAssertEqual(prediction.probability(for: .facebookStories), 0)
        }
        XCTAssertEqual(CascadePolicy.enabledApps(youtube: false, reels: false, stories: false,
                                                facebookStories: true), [.facebook])
    }

    func testContractRejectsWrongRouterWidthAndPreservesLegacy() throws {
        let modern = try metadata()
        XCTAssertThrowsError(try modern.policy.route([0.1, 0.1, 0.8]))
        let legacy = try MetadataTests().decode(MetadataTests().document())
        try legacy.validate()
        XCTAssertThrowsError(try legacy.policy.route([0.1, 0.1, 0.1, 0.7]))
        XCTAssertEqual(legacy.surfaceMetadata.appLabels, ["youtube", "instagram", "other"])
        XCTAssertEqual(try legacy.policy.route([0.1, 0.1, 0.8]).reason, "other")
    }

    func testFacebookEvidenceCannotCarryAcrossAppsOrUnknown() {
        var boundary = CascadeEvidenceBoundary()
        var votes: [Bool] = []
        for (index, app) in [SurfaceApp.facebook, .facebook, .instagram, .facebook, .facebook].enumerated() {
            if boundary.observe(app: app, timestamp: Double(index) * 0.25, maxGap: 1.25) { votes = [] }
            XCTAssertLessThan(CascadeEvidenceBoundary.appendVote(app == .facebook, to: &votes, window: 5), 3)
        }
        XCTAssertTrue(boundary.observe(app: nil, timestamp: 1.25, maxGap: 1.25))
    }
}
