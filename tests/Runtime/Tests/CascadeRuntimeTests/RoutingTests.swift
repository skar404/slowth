import XCTest
@testable import CascadeRuntime

final class RoutingTests: XCTestCase {
    func policy() throws -> CascadePolicy {
        let helper = MetadataTests()
        return try helper.decode(helper.document()).policy
    }

    func testRouterAbstentionAndInvalidSelectedOutputs() throws {
        let policy = try policy()
        XCTAssertEqual(try policy.route([0.4, 0.3, 0.3]).reason, "low_confidence")
        XCTAssertEqual(try policy.route([0.5, 0.45, 0.05]).reason, "ambiguous")
        XCTAssertEqual(try policy.route([0.5, 0.25, 0.25]).reason, "accepted")
        XCTAssertThrowsError(try policy.route([.nan, 0, 1]))
        XCTAssertThrowsError(try policy.predict(enabledApps: [.youtube]) { stage in
            stage == "router" ? [0.9, 0.05, 0.05] : [.nan, 0]
        })
        let threshold = policy.thresholds["youtube_shorts"]!
        let prediction = try policy.predict(enabledApps: [.youtube]) { stage in
            stage == "router" ? [1, 0, 0] : [threshold, 1 - threshold]
        }
        XCTAssertGreaterThanOrEqual(prediction.probability(for: .youtubeShorts), threshold)
    }

    func testEnabledAppsUsesEitherInstagramSurface() {
        for youtube in [false, true] {
            for reels in [false, true] {
                for stories in [false, true] {
                    let apps = CascadePolicy.enabledApps(youtube: youtube, reels: reels, stories: stories)
                    XCTAssertEqual(apps.contains(.youtube), youtube)
                    XCTAssertEqual(apps.contains(.instagram), reels || stories)
                    XCTAssertFalse(apps.contains(.other))
                }
            }
        }
    }

    func testOnlySelectedEnabledSpecialistRuns() throws {
        let policy = try policy()
        for (apps, enabled, expected, reason) in [
            ([0.9, 0.05, 0.05], Set<SurfaceApp>(), ["router"], "disabled"),
            ([0.05, 0.9, 0.05], Set<SurfaceApp>(), ["router"], "disabled"),
            ([0.05, 0.9, 0.05], Set([SurfaceApp.instagram]), ["router", "instagram"], "accepted"),
            ([0.9, 0.05, 0.05], Set([SurfaceApp.youtube, .instagram]), ["router", "youtube"], "accepted"),
            ([0.1, 0.1, 0.8], Set([SurfaceApp.youtube, .instagram]), ["router"], "other"),
        ] {
            var calls: [String] = []
            let result = try policy.predict(enabledApps: enabled) { stage in
                calls.append(stage)
                return stage == "router" ? apps : stage == "youtube" ? [0.8, 0.2] : [0.6, 0.3, 0.1]
            }
            XCTAssertEqual(calls, expected)
            XCTAssertEqual(result.routing?.reason, reason)
            if expected.count == 1 {
                XCTAssertTrue(result.youtubeContentProbabilities.isEmpty)
                XCTAssertTrue(result.instagramContentProbabilities.isEmpty)
                XCTAssertNil(result.topClass)
                XCTAssertTrue(result.jointProbabilities.values.allSatisfy { $0 == 0 })
            }
        }
    }
}
