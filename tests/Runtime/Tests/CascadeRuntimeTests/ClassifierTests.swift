import CoreVideo
import XCTest
@testable import CascadeRuntime

final class ClassifierTests: XCTestCase {
    func buffer(_ value: UInt8 = 42) throws -> CVPixelBuffer {
        var buffer: CVPixelBuffer?
        XCTAssertEqual(CVPixelBufferCreate(kCFAllocatorDefault, 192, 384, kCVPixelFormatType_32BGRA,
                                          nil, &buffer), kCVReturnSuccess)
        let result = try XCTUnwrap(buffer)
        CVPixelBufferLockBaseAddress(result, [])
        memset(CVPixelBufferGetBaseAddress(result), Int32(value), CVPixelBufferGetBytesPerRow(result) * 384)
        CVPixelBufferUnlockBaseAddress(result, [])
        return result
    }

    func testWarmSpecialistIsCachedAndDiagnosticsMarkNotRun() throws {
        let helper = MetadataTests()
        var loads: [String] = []
        var calls: [String] = []
        let classifier = try CascadeClassifier(specification: helper.decode(helper.document())) { stage in
            loads.append(stage)
            return { _ in
                calls.append(stage)
                return stage == "router" ? [0.9, 0.05, 0.05] : [0.8, 0.2]
            }
        }
        for value: UInt8 in [12, 99] {
            let prediction = try classifier.predict(pixelBuffer: buffer(value), enabledApps: [.youtube])
            XCTAssertEqual(prediction.probability(for: .youtubeShorts), 0.72, accuracy: 1e-12)
            let timings = try XCTUnwrap(prediction.timings)
            XCTAssertEqual(timings.specialist, "youtube")
            XCTAssertNotNil(timings.specialistMS)
            XCTAssertGreaterThanOrEqual(timings.totalMS, timings.resizeMS + timings.routerMS + (timings.specialistMS ?? 0))
            XCTAssertEqual(try classifier.copyModelInputBGRA().data[0], value)
        }
        XCTAssertEqual(loads, ["router", "youtube"])
        XCTAssertEqual(calls, ["router", "youtube", "router", "youtube"])
        let disabled = try classifier.predict(pixelBuffer: buffer(), enabledApps: [])
        XCTAssertEqual(disabled.timings?.specialist, "not_run")
        XCTAssertNil(disabled.timings?.specialistMS)
    }

    func testDisabledMissingSpecialistIsNotLoadedButEnabledMissingThrows() throws {
        let helper = MetadataTests()
        let metadata = try helper.decode(helper.document())
        var loads: [String] = []
        let classifier = try CascadeClassifier(specification: metadata) { stage in
            loads.append(stage)
            guard stage == "router" else { throw CascadeClassifierError.missing(stage) }
            return { _ in [0.9, 0.05, 0.05] }
        }
        XCTAssertEqual(loads, ["router"])
        let source = try buffer()
        let erased: any SurfaceClassifying = classifier
        let disabled = try erased.predict(pixelBuffer: source, enabledApps: [])
        XCTAssertEqual(disabled.routing?.reason, "disabled")
        XCTAssertEqual(loads, ["router"])
        let copy = try erased.copyModelInputBGRA()
        XCTAssertEqual(copy.width, 192)
        XCTAssertEqual(copy.height, 384)
        XCTAssertEqual(copy.data.count, copy.bytesPerRow * copy.height)
        XCTAssertEqual(copy.data[0], 42)
        XCTAssertThrowsError(try erased.predict(pixelBuffer: source, enabledApps: [.youtube]))
        XCTAssertEqual(loads, ["router", "youtube"])
    }
}
