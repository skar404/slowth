import XCTest
@testable import CascadeRuntime

final class FlatClassifierTests: XCTestCase {
    func testFlat15CompiledBundle() throws {
        guard let path = ProcessInfo.processInfo.environment["FLAT15_BUNDLE"] else {
            throw XCTSkip("Set FLAT15_BUNDLE to the Flat 15 bundle")
        }
        let bundle = try XCTUnwrap(Bundle(path: path))
        let model = try FlatClassifier(bundle: bundle, candidate: .flat15, computeUnits: .cpuOnly)
        XCTAssertEqual(model.metadata.modelVersion, "flat-15-seed7-20261028")
        XCTAssertEqual(model.metadata.requiredConsecutiveHits, 3)
        XCTAssertEqual(model.metadata.effectiveObservationWindowFrames, 5)
        let result = try model.predict(pixelBuffer: ClassifierTests().buffer(), enabledApps: Set(SurfaceApp.allCases))
        XCTAssertEqual(result.jointProbabilities.count, 11)
        XCTAssertEqual(result.jointProbabilities.values.reduce(0, +), 1, accuracy: 0.00001)
        XCTAssertThrowsError(try FlatClassifier(bundle: bundle, candidate: .flat13, computeUnits: .cpuOnly))
        XCTAssertThrowsError(try FlatClassifier(bundle: Bundle.main, candidate: .flat15, computeUnits: .cpuOnly))
    }

    func testFlat14CompiledBundle() throws {
        guard let path = ProcessInfo.processInfo.environment["FLAT14_BUNDLE"] else {
            throw XCTSkip("Set FLAT14_BUNDLE to the Flat 14 bundle")
        }
        let bundle = try XCTUnwrap(Bundle(path: path))
        let model = try FlatClassifier(bundle: bundle, candidate: .flat14, computeUnits: .cpuOnly)
        XCTAssertEqual(model.metadata.modelVersion, "flat-14-seed7-20261028")
        XCTAssertEqual(model.metadata.requiredConsecutiveHits, 3)
        XCTAssertEqual(model.metadata.effectiveObservationWindowFrames, 5)
        let result = try model.predict(pixelBuffer: ClassifierTests().buffer(), enabledApps: Set(SurfaceApp.allCases))
        XCTAssertEqual(result.jointProbabilities.count, 11)
        XCTAssertEqual(result.jointProbabilities.values.reduce(0, +), 1, accuracy: 0.00001)
        XCTAssertThrowsError(try FlatClassifier(bundle: bundle, candidate: .flat13, computeUnits: .cpuOnly))
        XCTAssertThrowsError(try FlatClassifier(bundle: Bundle.main, candidate: .flat14, computeUnits: .cpuOnly))
    }

    func testFlat13CompiledBundle() throws {
        guard let path = ProcessInfo.processInfo.environment["FLAT13_BUNDLE"] else {
            throw XCTSkip("Set FLAT13_BUNDLE to the Flat 13 bundle")
        }
        let bundle = try XCTUnwrap(Bundle(path: path))
        let model = try FlatClassifier(bundle: bundle, candidate: .flat13, computeUnits: .cpuOnly)
        XCTAssertEqual(model.metadata.modelVersion, "flat-13-seed7-20261027")
        XCTAssertEqual(model.metadata.requiredConsecutiveHits, 3)
        XCTAssertEqual(model.metadata.effectiveObservationWindowFrames, 5)
        let result = try model.predict(pixelBuffer: ClassifierTests().buffer(), enabledApps: Set(SurfaceApp.allCases))
        XCTAssertEqual(result.jointProbabilities.count, 11)
        XCTAssertEqual(result.jointProbabilities.values.reduce(0, +), 1, accuracy: 0.00001)
        XCTAssertThrowsError(try FlatClassifier(bundle: bundle, computeUnits: .cpuOnly))
    }

    func testFlat12CompiledBundle() throws {
        guard let path = ProcessInfo.processInfo.environment["FLAT12_BUNDLE"] else {
            throw XCTSkip("Set FLAT12_BUNDLE to the Flat 12 bundle")
        }
        let bundle = try XCTUnwrap(Bundle(path: path))
        let model = try FlatClassifier(bundle: bundle, candidate: .flat12, computeUnits: .cpuOnly)
        XCTAssertEqual(model.metadata.modelVersion, "flat-12-seed7-20261027")
        XCTAssertEqual(model.metadata.requiredConsecutiveHits, 3)
        XCTAssertEqual(model.metadata.effectiveObservationWindowFrames, 5)
        let result = try model.predict(pixelBuffer: ClassifierTests().buffer(), enabledApps: Set(SurfaceApp.allCases))
        XCTAssertEqual(result.jointProbabilities.count, 11)
        XCTAssertEqual(result.jointProbabilities.values.reduce(0, +), 1, accuracy: 0.00001)
        XCTAssertThrowsError(try FlatClassifier(bundle: bundle, computeUnits: .cpuOnly))
    }

    #if DEBUG
    func testCandidateCompiledBundle() throws {
        guard let path = ProcessInfo.processInfo.environment["FLAT_CANDIDATE_BUNDLE"] else {
            throw XCTSkip("Set FLAT_CANDIDATE_BUNDLE to the candidate bundle")
        }
        let bundle = try XCTUnwrap(Bundle(path: path))
        let model = try FlatClassifier(bundle: bundle, candidate: .iphone13ProMax, computeUnits: .cpuOnly)
        XCTAssertEqual(model.metadata.modelVersion, "flat-11-seed7-iphone13promax-20261026")
        let result = try model.predict(pixelBuffer: ClassifierTests().buffer(), enabledApps: Set(SurfaceApp.allCases))
        XCTAssertEqual(result.jointProbabilities.count, 11)
        XCTAssertEqual(result.jointProbabilities.values.reduce(0, +), 1, accuracy: 0.00001)
        XCTAssertNil(result.routing)
        // A candidate bundle cannot silently stand in for the default.
        XCTAssertThrowsError(try FlatClassifier(bundle: bundle, computeUnits: .cpuOnly))
    }
    #endif

    func testDirectScoresAndDisabledApps() throws {
        let values: [Double] = [0.02,0.03,0.04,0.05,0.06,0.1,0.1,0.1,0.1,0.3,0.1]
        let prediction = try FlatClassifier.prediction(probabilities: values, enabledApps: Set(SurfaceApp.allCases))
        XCTAssertNil(prediction.routing)
        XCTAssertEqual(prediction.topClass, .xReels)
        for (index, label) in SurfaceClass.allCases.enumerated() {
            XCTAssertEqual(prediction.probability(for: label), values[index])
        }
        let disabled = try FlatClassifier.prediction(probabilities: values, enabledApps: [.youtube])
        XCTAssertEqual(disabled.probability(for: .xReels), 0)
        XCTAssertEqual(disabled.probability(for: .youtubeShorts), values[0])
        XCTAssertThrowsError(try FlatClassifier.prediction(probabilities: [1], enabledApps: []))
        XCTAssertThrowsError(try FlatClassifier.prediction(probabilities: Array(repeating: .nan, count: 11), enabledApps: []))
    }

    func testCompiledBundle() throws {
        guard let path = ProcessInfo.processInfo.environment["FLAT_BUNDLE"] else {
            throw XCTSkip("Set FLAT_BUNDLE to a compiled model bundle")
        }
        let model = try FlatClassifier(bundle: XCTUnwrap(Bundle(path: path)), computeUnits: .cpuOnly)
        XCTAssertEqual(model.metadata.modelVersion, "flat-11-seed7-20261015")
        XCTAssertEqual(model.metadata.requiredConsecutiveHits, 3)
        XCTAssertEqual(model.metadata.effectiveObservationWindowFrames, 5)
        XCTAssertEqual(model.metadata.confidenceThresholds.count, 6)
        let result = try model.predict(pixelBuffer: ClassifierTests().buffer(), enabledApps: Set(SurfaceApp.allCases))
        XCTAssertEqual(result.jointProbabilities.values.reduce(0, +), 1, accuracy: 0.00001)
        XCTAssertNil(result.routing)
        XCTAssertEqual(result.jointProbabilities.count, 11)
    }
}
