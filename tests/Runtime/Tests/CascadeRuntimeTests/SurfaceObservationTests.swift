import XCTest
@testable import CascadeRuntime

final class SurfaceObservationTests: XCTestCase {
    private func append(_ state: inout SurfaceObservationState, _ positive: Bool,
                        hits: Int = 3, window: Int = 5) {
        state.append(youtubeVerdict: positive, instagramReelsVerdict: positive,
                     instagramStoriesVerdict: positive, facebookReelsVerdict: positive,
                     xReelsVerdict: positive, facebookStoriesVerdict: positive,
                     requiredHits: hits, observationWindowFrames: window)
    }

    func testWindowCrossingsAndNegativeCurrentVerdict() {
        var state = SurfaceObservationState()
        for vote in [true, false, true, true, false] { append(&state, vote) }
        XCTAssertEqual(state.youtubeShortsVotes, [true, false, true, true, false])
        XCTAssertEqual(state.youtubeShortsStreak, 3)
        XCTAssertEqual(state.youtubeCandidateEvents, 1)
        // A negative current verdict retains three hits; enforcement remains consumer-specific.
        XCTAssertEqual(state.instagramReelsStreak, 3)
        append(&state, false)
        XCTAssertEqual(state.youtubeShortsStreak, 2)
        append(&state, true)
        XCTAssertEqual(state.youtubeShortsStreak, 3)
        XCTAssertEqual(state.youtubeCandidateEvents, 2)
        XCTAssertEqual(state.instagramCandidateEvents, 2)
        XCTAssertEqual(state.instagramStoriesCandidateEvents, 2)
        XCTAssertEqual(state.facebookCandidateEvents, 2)
        XCTAssertEqual(state.facebookStoriesCandidateEvents, 2)
        XCTAssertEqual(state.xCandidateEvents, 2)
        append(&state, true)
        XCTAssertEqual(state.youtubeCandidateEvents, 2, "staying above threshold is not a new crossing")
    }

    func testEachChannelUsesItsOwnVerdict() {
        var state = SurfaceObservationState()
        state.append(youtubeVerdict: true, instagramReelsVerdict: false,
                     instagramStoriesVerdict: true, facebookReelsVerdict: false,
                     xReelsVerdict: true, facebookStoriesVerdict: false,
                     requiredHits: 1, observationWindowFrames: 5)
        XCTAssertEqual([state.youtubeShortsStreak, state.instagramReelsStreak,
                        state.instagramStoriesStreak, state.facebookReelsStreak,
                        state.xReelsStreak, state.facebookStoriesStreak], [1, 0, 1, 0, 1, 0])
        XCTAssertEqual([state.youtubeCandidateEvents, state.instagramCandidateEvents,
                        state.instagramStoriesCandidateEvents, state.facebookCandidateEvents,
                        state.xCandidateEvents, state.facebookStoriesCandidateEvents], [1, 0, 1, 0, 1, 0])
    }

    func testServiceResetPreservesOtherServicesAndCumulativeCounters() {
        for service in [SurfaceApp.youtube, .instagram, .facebook, .x] {
            var state = SurfaceObservationState()
            for _ in 0..<3 { append(&state, true) }
            state.reset(service: service)
            XCTAssertEqual(state.youtubeShortsStreak, service == .youtube ? 0 : 3)
            XCTAssertEqual(state.instagramReelsStreak, service == .instagram ? 0 : 3)
            XCTAssertEqual(state.instagramStoriesStreak, service == .instagram ? 0 : 3)
            XCTAssertEqual(state.facebookReelsStreak, service == .facebook ? 0 : 3)
            XCTAssertEqual(state.facebookStoriesStreak, service == .facebook ? 0 : 3)
            XCTAssertEqual(state.xReelsStreak, service == .x ? 0 : 3)
            XCTAssertEqual([state.youtubeCandidateEvents, state.instagramCandidateEvents,
                            state.instagramStoriesCandidateEvents, state.facebookCandidateEvents,
                            state.xCandidateEvents, state.facebookStoriesCandidateEvents], [1, 1, 1, 1, 1, 1])
            append(&state, false)
            XCTAssertEqual(state.youtubeShortsVotes.count, service == .youtube ? 1 : 4)
            XCTAssertEqual(state.instagramReelsVotes.count, service == .instagram ? 1 : 4)
            XCTAssertEqual(state.instagramStoriesVotes.count, service == .instagram ? 1 : 4)
            XCTAssertEqual(state.facebookReelsVotes.count, service == .facebook ? 1 : 4)
            XCTAssertEqual(state.facebookStoriesVotes.count, service == .facebook ? 1 : 4)
            XCTAssertEqual(state.xReelsVotes.count, service == .x ? 1 : 4)
        }
    }

    func testObservationResetPreservesCountersButSessionResetClearsThem() {
        var state = SurfaceObservationState()
        for _ in 0..<3 { append(&state, true) }
        state.resetObservations()
        XCTAssertEqual([state.youtubeShortsStreak, state.instagramReelsStreak, state.instagramStoriesStreak,
                        state.facebookReelsStreak, state.facebookStoriesStreak, state.xReelsStreak], [0, 0, 0, 0, 0, 0])
        for _ in 0..<3 { append(&state, true) }
        XCTAssertEqual([state.youtubeCandidateEvents, state.instagramCandidateEvents,
                        state.instagramStoriesCandidateEvents, state.facebookCandidateEvents,
                        state.xCandidateEvents, state.facebookStoriesCandidateEvents], [2, 2, 2, 2, 2, 2])
        state.resetSession()
        append(&state, false)
        XCTAssertEqual(state.youtubeShortsStreak, 0)
        XCTAssertEqual(state.youtubeShortsVotes, [false])
        XCTAssertEqual([state.youtubeCandidateEvents, state.instagramCandidateEvents,
                        state.instagramStoriesCandidateEvents, state.facebookCandidateEvents,
                        state.xCandidateEvents, state.facebookStoriesCandidateEvents], [0, 0, 0, 0, 0, 0])
    }

    func testRoutingAndGapBoundariesDiscardVotesWithoutDiscardingCounters() {
        var state = SurfaceObservationState()
        var boundary = CascadeEvidenceBoundary()
        for (time, app) in [(0.0, SurfaceApp.youtube), (0.25, .youtube), (0.5, .youtube),
                            (0.75, .instagram), (1.0, .instagram), (1.25, .instagram),
                            (3.0, .instagram)] {
            if boundary.observe(app: app, timestamp: time, maxGap: 1.25) { state.resetObservations() }
            append(&state, true)
        }
        XCTAssertEqual(state.youtubeShortsStreak, 1)
        XCTAssertEqual(state.youtubeCandidateEvents, 2)
        if boundary.observe(app: nil, timestamp: 3.25, maxGap: 1.25) { state.resetObservations() }
        XCTAssertEqual(state.youtubeShortsStreak, 0)
        XCTAssertEqual(state.youtubeCandidateEvents, 2)
    }
}
