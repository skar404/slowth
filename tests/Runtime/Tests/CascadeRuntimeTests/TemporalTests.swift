import XCTest
@testable import CascadeRuntime

final class TemporalTests: XCTestCase {
    func testThreeOfFiveRetainsNegativesAndUnknownClearsCandidates() {
        var votes: [Bool] = []
        var boundary = CascadeEvidenceBoundary()
        let observations: [(Double, SurfaceApp?, Bool, Int)] = [
            (0, .youtube, true, 1), (0.25, .youtube, false, 1),
            (0.5, .youtube, true, 2), (0.75, .youtube, false, 2),
            (1, .youtube, true, 3), (1.25, nil, false, 0),
            (1.5, .youtube, true, 1), (3, .youtube, true, 1),
        ]
        for (time, app, positive, hits) in observations {
            if boundary.observe(app: app, timestamp: time, maxGap: 1.25) { votes.removeAll() }
            XCTAssertEqual(CascadeEvidenceBoundary.appendVote(positive, to: &votes, window: 5), hits)
        }
    }

    func testEvidenceResetsOnUnknownRouteSwitchGapAndNonIncreasingTime() {
        var evidence = CascadeEvidenceBoundary()
        XCTAssertTrue(evidence.observe(app: .youtube, timestamp: 0, maxGap: 1.25))
        XCTAssertFalse(evidence.observe(app: .youtube, timestamp: 0.25, maxGap: 1.25))
        XCTAssertTrue(evidence.observe(app: nil, timestamp: 0.5, maxGap: 1.25))
        XCTAssertTrue(evidence.observe(app: .youtube, timestamp: 0.75, maxGap: 1.25))
        XCTAssertTrue(evidence.observe(app: .instagram, timestamp: 1, maxGap: 1.25))
        XCTAssertFalse(evidence.observe(app: .instagram, timestamp: 2.25, maxGap: 1.25))
        XCTAssertTrue(evidence.observe(app: .instagram, timestamp: 4, maxGap: 1.25))
        XCTAssertTrue(evidence.observe(app: .instagram, timestamp: 4, maxGap: 1.25))
        XCTAssertTrue(evidence.observe(app: .instagram, timestamp: 3, maxGap: 1.25))
        evidence = CascadeEvidenceBoundary() // pause/resume/unlock/failure candidate reset
        XCTAssertTrue(evidence.observe(app: .instagram, timestamp: 3.25, maxGap: 1.25))
    }

    func testInvalidPTSUsesUptimeDeltaNotDateEpoch() {
        var clock = CascadeTimestampClock()
        XCTAssertEqual(clock.resolve(pts: 10, uptime: 100).seconds, 100)
        let invalid = clock.resolve(pts: .nan, uptime: 100.25)
        XCTAssertEqual(invalid.seconds, 100.25)
        XCTAssertTrue(invalid.reset)
        let recovered = clock.resolve(pts: 10.5, uptime: 100.5)
        XCTAssertEqual(recovered.seconds, 100.5)
        XCTAssertTrue(recovered.reset)
        XCTAssertEqual(clock.resolve(pts: 10.75, uptime: 100.75).seconds, 100.75)
        XCTAssertTrue(clock.resolve(pts: 9, uptime: 101).reset)
    }

    func testRollbackIsAcceptedAndResetsBeforeThrottle() {
        XCTAssertEqual(CascadeSampling.decide(timestamp: 9, previous: 10, interval: 0.25), .sample(reset: true))
        XCTAssertEqual(CascadeSampling.decide(timestamp: 10, previous: 10, interval: 0.25), .sample(reset: true))
        XCTAssertEqual(CascadeSampling.decide(timestamp: 10.1, previous: 10, interval: 0.25), .skip)
        XCTAssertEqual(CascadeSampling.decide(timestamp: 10.25, previous: 10, interval: 0.25), .sample(reset: false))
    }
}
