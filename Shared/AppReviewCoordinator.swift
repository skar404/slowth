import Foundation

/// Host-app preferences survive updates and are shared by both interface styles.
/// StoreKit doesn't report whether a request was displayed or a review was left.
@MainActor
final class AppReviewCoordinator {
    static let shared = AppReviewCoordinator()
    static let reviewURL = URL(string: "https://apps.apple.com/app/id6764140763?action=write-review")!

    private enum Key {
        static let firstOpenedAt = "appReview.firstOpenedAt"
        static let activeDays = "appReview.activeDays"
        static let attempted = "reviewRequestAttempted"
    }

    private let defaults: UserDefaults
    private let calendar: Calendar

    enum RequestBlocker: Equatable {
        case screenNotReady
        case blockingDisabled
        case alreadyAttempted
        case missingHistory
        case tooEarly(Date)
        case tooFewOpeningDates(Int)

        #if DEBUG
        var explanation: String {
            switch self {
            case .screenNotReady: return "The app must be active with no open dialogs or pending authorization."
            case .blockingDisabled: return "No blocking is enabled. Enable a Safari blocking switch or configured in-app blocking."
            case .alreadyAttempted: return "The attempt is already saved. Use Prepare review test to allow another test."
            case .missingHistory: return "No opening history exists. Use Prepare review test first."
            case .tooEarly(let date): return "Seven days have not elapsed. Eligible after \(date.formatted(date: .abbreviated, time: .standard))."
            case .tooFewOpeningDates(let count): return "Only \(count) of 3 opening dates are recorded. Use Prepare review test."
            }
        }
        #endif
    }

    init(defaults: UserDefaults = .standard, calendar: Calendar = Calendar(identifier: .gregorian)) {
        self.defaults = defaults
        self.calendar = calendar
    }

    func recordOpening(at now: Date = Date()) {
        guard !defaults.bool(forKey: Key.attempted) else { return }
        if defaults.object(forKey: Key.firstOpenedAt) == nil {
            defaults.set(now, forKey: Key.firstOpenedAt)
        }
        var days = Set(defaults.stringArray(forKey: Key.activeDays) ?? [])
        // Three distinct calendar dates suffice; don't retain a usage history.
        guard days.count < 3 else { return }
        let parts = calendar.dateComponents([.year, .month, .day], from: now)
        days.insert("\(parts.year!)-\(parts.month!)-\(parts.day!)")
        defaults.set(days.sorted(), forKey: Key.activeDays)
    }

    /// Claim synchronously on the main actor before calling StoreKit, including
    /// when two windows or interface styles become eligible together.
    func claimRequest(at now: Date = Date(), hasEnabledBlocking: Bool, isReady: Bool) -> Bool {
        guard requestBlocker(at: now, hasEnabledBlocking: hasEnabledBlocking, isReady: isReady) == nil else { return false }
        defaults.set(true, forKey: Key.attempted)
        return true
    }

    /// The Debug panel reports the same conditions that control the real claim.
    func requestBlocker(at now: Date = Date(), hasEnabledBlocking: Bool, isReady: Bool) -> RequestBlocker? {
        guard isReady else { return .screenNotReady }
        guard hasEnabledBlocking else { return .blockingDisabled }
        guard !defaults.bool(forKey: Key.attempted) else { return .alreadyAttempted }
        guard let firstOpenedAt = defaults.object(forKey: Key.firstOpenedAt) as? Date else { return .missingHistory }
        let eligibleAfter = firstOpenedAt.addingTimeInterval(7 * 24 * 60 * 60)
        guard now >= eligibleAfter else { return .tooEarly(eligibleAfter) }
        let days = Set(defaults.stringArray(forKey: Key.activeDays) ?? []).count
        guard days >= 3 else { return .tooFewOpeningDates(days) }
        return nil
    }

    #if DEBUG
    struct DebugStatus {
        let firstOpenedAt: Date?
        let activeDays: Int
        let attempted: Bool
        var eligibleAfter: Date? { firstOpenedAt?.addingTimeInterval(7 * 24 * 60 * 60) }
    }

    func debugStatus() -> DebugStatus {
        DebugStatus(firstOpenedAt: defaults.object(forKey: Key.firstOpenedAt) as? Date,
                    activeDays: Set(defaults.stringArray(forKey: Key.activeDays) ?? []).count,
                    attempted: defaults.bool(forKey: Key.attempted))
    }

    func resetForDebug() {
        for key in [Key.firstOpenedAt, Key.activeDays, Key.attempted] {
            defaults.removeObject(forKey: key)
        }
    }

    /// Seed only review preferences; blocking settings and other app data stay intact.
    func prepareEligibleHistoryForDebug(at now: Date = Date()) {
        resetForDebug()
        recordOpening(at: now.addingTimeInterval(-7 * 24 * 60 * 60))
        recordOpening(at: now.addingTimeInterval(-24 * 60 * 60))
        recordOpening(at: now)
    }
    #endif
}
