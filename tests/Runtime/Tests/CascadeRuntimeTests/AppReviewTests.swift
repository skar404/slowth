import XCTest
@testable import CascadeRuntime

final class AppReviewTests: XCTestCase {
    private let firstDay = Date(timeIntervalSince1970: 1_780_315_200)
    private let day: TimeInterval = 86_400

    private var calendar: Calendar {
        var value = Calendar(identifier: .gregorian)
        value.timeZone = TimeZone(secondsFromGMT: 0)!
        return value
    }

    @MainActor
    private func withStore(_ test: (UserDefaults, AppReviewCoordinator) -> Void) {
        let name = "AppReviewTests-" + UUID().uuidString
        let defaults = UserDefaults(suiteName: name)!
        defer { defaults.removePersistentDomain(forName: name) }
        test(defaults, AppReviewCoordinator(defaults: defaults, calendar: calendar))
    }

    func testNeedsSevenFullDaysAndThreeDistinctOpeningDates() async {
        await MainActor.run {
            withStore { _, coordinator in
                XCTAssertFalse(coordinator.claimRequest(at: firstDay, hasEnabledBlocking: true, isReady: true))
                coordinator.recordOpening(at: firstDay)
                coordinator.recordOpening(at: firstDay.addingTimeInterval(day))
                coordinator.recordOpening(at: firstDay.addingTimeInterval(2 * day))
                XCTAssertFalse(coordinator.claimRequest(at: firstDay.addingTimeInterval(7 * day - 1),
                    hasEnabledBlocking: true, isReady: true))
                XCTAssertTrue(coordinator.claimRequest(at: firstDay.addingTimeInterval(7 * day),
                    hasEnabledBlocking: true, isReady: true))
            }
        }
    }

    func testReopeningAndSwitchingInterfacesDoNotCountAsNewDays() async {
        await MainActor.run {
            withStore { defaults, coordinator in
                for _ in 0..<10 { coordinator.recordOpening(at: firstDay) }
                let otherInterface = AppReviewCoordinator(defaults: defaults, calendar: calendar)
                otherInterface.recordOpening(at: firstDay.addingTimeInterval(8 * day))
                for _ in 0..<10 { coordinator.recordOpening(at: firstDay.addingTimeInterval(8 * day)) }
                XCTAssertFalse(coordinator.claimRequest(at: firstDay.addingTimeInterval(8 * day),
                    hasEnabledBlocking: true, isReady: true))
                coordinator.recordOpening(at: firstDay.addingTimeInterval(9 * day))
                XCTAssertTrue(otherInterface.claimRequest(at: firstDay.addingTimeInterval(9 * day),
                    hasEnabledBlocking: true, isReady: true))
            }
        }
    }

    func testBackgroundDialogsAndDisabledBlockingDoNotConsumeAttempt() async {
        await MainActor.run {
            withStore { _, coordinator in
                for offset in [0, 1, 7] { coordinator.recordOpening(at: firstDay.addingTimeInterval(Double(offset) * day)) }
                let now = firstDay.addingTimeInterval(7 * day)
                XCTAssertFalse(coordinator.claimRequest(at: now, hasEnabledBlocking: true, isReady: false))
                XCTAssertFalse(coordinator.claimRequest(at: now, hasEnabledBlocking: false, isReady: true))
                XCTAssertTrue(coordinator.claimRequest(at: now, hasEnabledBlocking: true, isReady: true))
            }
        }
    }

    func testAttemptSurvivesRelaunchAndUpdatesEvenIfStoreKitShowsNothing() async {
        await MainActor.run {
            withStore { defaults, coordinator in
                for offset in [0, 1, 7] { coordinator.recordOpening(at: firstDay.addingTimeInterval(Double(offset) * day)) }
                XCTAssertTrue(coordinator.claimRequest(at: firstDay.addingTimeInterval(7 * day),
                    hasEnabledBlocking: true, isReady: true))
                XCTAssertTrue(defaults.bool(forKey: "reviewRequestAttempted"))
                let relaunched = AppReviewCoordinator(defaults: defaults, calendar: calendar)
                let nextYear = firstDay.addingTimeInterval(365 * day)
                relaunched.recordOpening(at: nextYear)
                XCTAssertFalse(relaunched.claimRequest(at: nextYear, hasEnabledBlocking: true, isReady: true))
                XCTAssertFalse(coordinator.claimRequest(at: nextYear, hasEnabledBlocking: true, isReady: true))
            }
        }
    }

    func testClockGoingBackDoesNotMakeRequestEligible() async {
        await MainActor.run {
            withStore { _, coordinator in
                for offset in [0, 1, 2] { coordinator.recordOpening(at: firstDay.addingTimeInterval(Double(offset) * day)) }
                XCTAssertFalse(coordinator.claimRequest(at: firstDay.addingTimeInterval(-day),
                    hasEnabledBlocking: true, isReady: true))
            }
        }
    }

    func testManualLinkAlwaysOpensTheAppStoreReviewPage() async {
        await MainActor.run {
            let url = AppReviewCoordinator.reviewURL
            XCTAssertEqual(url.host, "apps.apple.com")
            XCTAssertEqual(url.path, "/app/id6764140763")
            XCTAssertEqual(URLComponents(url: url, resolvingAgainstBaseURL: false)?.queryItems,
                           [URLQueryItem(name: "action", value: "write-review")])
        }
    }

    func testReportsSpecificEligibilityFailureWithoutConsumingAttempt() async {
        await MainActor.run {
            withStore { defaults, coordinator in
                XCTAssertEqual(coordinator.requestBlocker(at: firstDay, hasEnabledBlocking: true, isReady: false), .screenNotReady)
                XCTAssertEqual(coordinator.requestBlocker(at: firstDay, hasEnabledBlocking: false, isReady: true), .blockingDisabled)
                XCTAssertEqual(coordinator.requestBlocker(at: firstDay, hasEnabledBlocking: true, isReady: true), .missingHistory)
                coordinator.recordOpening(at: firstDay)
                let eligibleAfter = firstDay.addingTimeInterval(7 * day)
                XCTAssertEqual(coordinator.requestBlocker(at: firstDay, hasEnabledBlocking: true, isReady: true), .tooEarly(eligibleAfter))
                XCTAssertEqual(coordinator.requestBlocker(at: eligibleAfter, hasEnabledBlocking: true, isReady: true), .tooFewOpeningDates(1))
                coordinator.recordOpening(at: firstDay.addingTimeInterval(day))
                XCTAssertEqual(coordinator.requestBlocker(at: eligibleAfter, hasEnabledBlocking: true, isReady: true), .tooFewOpeningDates(2))
                coordinator.recordOpening(at: eligibleAfter)
                XCTAssertNil(coordinator.requestBlocker(at: eligibleAfter, hasEnabledBlocking: true, isReady: true))
                XCTAssertFalse(defaults.bool(forKey: "reviewRequestAttempted"))
                XCTAssertTrue(coordinator.claimRequest(at: eligibleAfter, hasEnabledBlocking: true, isReady: true))
                XCTAssertEqual(coordinator.requestBlocker(at: eligibleAfter, hasEnabledBlocking: true, isReady: true), .alreadyAttempted)
            }
        }
    }

    #if DEBUG
    func testDebugPreparationUsesRealEligibilityAndAllowsOnlyOneClaim() async {
        await MainActor.run {
            withStore { _, coordinator in
                coordinator.prepareEligibleHistoryForDebug(at: firstDay)
                let status = coordinator.debugStatus()
                XCTAssertEqual(status.firstOpenedAt, firstDay.addingTimeInterval(-7 * day))
                XCTAssertEqual(status.eligibleAfter, firstDay)
                XCTAssertEqual(status.activeDays, 3)
                XCTAssertFalse(status.attempted)
                XCTAssertFalse(coordinator.claimRequest(at: firstDay, hasEnabledBlocking: false, isReady: true))
                XCTAssertFalse(coordinator.claimRequest(at: firstDay, hasEnabledBlocking: true, isReady: false))
                XCTAssertTrue(coordinator.claimRequest(at: firstDay, hasEnabledBlocking: true, isReady: true))
                XCTAssertTrue(coordinator.debugStatus().attempted)
                XCTAssertFalse(coordinator.claimRequest(at: firstDay, hasEnabledBlocking: true, isReady: true))
            }
        }
    }

    func testDebugResetClearsOnlyReviewDataAndCanPrepareAnotherAttempt() async {
        await MainActor.run {
            withStore { defaults, coordinator in
                defaults.set("keep", forKey: "unrelated-setting")
                coordinator.prepareEligibleHistoryForDebug(at: firstDay)
                XCTAssertTrue(coordinator.claimRequest(at: firstDay, hasEnabledBlocking: true, isReady: true))
                coordinator.resetForDebug()
                let reset = AppReviewCoordinator(defaults: defaults, calendar: calendar).debugStatus()
                XCTAssertNil(reset.firstOpenedAt)
                XCTAssertNil(reset.eligibleAfter)
                XCTAssertEqual(reset.activeDays, 0)
                XCTAssertFalse(reset.attempted)
                XCTAssertEqual(defaults.string(forKey: "unrelated-setting"), "keep")
                XCTAssertFalse(coordinator.claimRequest(at: firstDay, hasEnabledBlocking: true, isReady: true))
                coordinator.prepareEligibleHistoryForDebug(at: firstDay)
                XCTAssertTrue(coordinator.claimRequest(at: firstDay, hasEnabledBlocking: true, isReady: true))
                XCTAssertEqual(defaults.string(forKey: "unrelated-setting"), "keep")
            }
        }
    }
    #endif
}
