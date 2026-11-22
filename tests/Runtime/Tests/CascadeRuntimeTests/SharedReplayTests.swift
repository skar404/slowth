import Foundation
import XCTest
@testable import CascadeRuntime

final class SharedReplayTests: XCTestCase {
    struct Trace: Decodable {
        let policy: CascadePolicy
        let frames: [Frame]
    }
    struct Frame: Decodable {
        let time: Double
        let app: [Double]
        let content: [Double]
        let enabled: [String]?
        let route: String
        let reason: String
        let events: [String]
    }

    func testSameTraceAsPython() throws {
        let url = try XCTUnwrap(Bundle.module.url(forResource: "cascade-replay", withExtension: "json", subdirectory: "Fixtures"))
        let decoder = JSONDecoder()
        decoder.keyDecodingStrategy = .convertFromSnakeCase
        let trace = try decoder.decode(Trace.self, from: Data(contentsOf: url))
        try trace.policy.validate()
        var boundary = CascadeEvidenceBoundary()
        let targets: [SurfaceClass] = [.youtubeShorts, .instagramReels, .instagramStories]
        var votes = [[Bool]](repeating: [], count: targets.count)
        for frame in trace.frames {
            let enabled = Set((frame.enabled ?? ["youtube", "instagram"]).compactMap(SurfaceApp.init(rawValue:)))
            let prediction = try trace.policy.predict(enabledApps: enabled) { stage in
                stage == "router" ? frame.app : frame.content
            }
            let routing = try XCTUnwrap(prediction.routing)
            XCTAssertEqual(routing.app?.rawValue ?? "unknown", frame.route)
            XCTAssertEqual(routing.reason, frame.reason)
            if boundary.observe(app: routing.app, timestamp: frame.time, maxGap: trace.policy.temporal.maxGapSeconds) {
                votes = [[Bool]](repeating: [], count: targets.count)
            }
            var events: [String] = []
            for (index, target) in targets.enumerated() {
                let threshold = try XCTUnwrap(trace.policy.thresholds[target.rawValue])
                let positive = prediction.probability(for: target) >= threshold
                let count = CascadeEvidenceBoundary.appendVote(positive, to: &votes[index], window: trace.policy.temporal.windowFrames)
                if positive && count >= trace.policy.temporal.requiredHits { events.append(target.rawValue) }
            }
            XCTAssertEqual(events, frame.events, "at \(frame.time)")
        }
    }
}
