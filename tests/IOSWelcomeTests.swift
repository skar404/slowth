// Run from the repository root:
// xcrun swiftc -module-cache-path /tmp/slowth-welcome-module-cache Shared/AppLocalization.swift Shared/SharedStore.swift iOS/IOSWelcomeEligibility.swift tests/IOSWelcomeTests.swift -o /tmp/slowth-welcome-tests
// /tmp/slowth-welcome-tests

import Foundation

enum AppGroup {
    static let identifier = "test.ios-welcome.\(UUID().uuidString)"
    static let defaults = UserDefaults(suiteName: identifier)!
}

@main
struct IOSWelcomeTests {
    static func main() throws {
        defer { AppGroup.defaults.removePersistentDomain(forName: AppGroup.identifier) }
        let fresh = SharedStore.snapshot()
        precondition(!IOSWelcomeEligibility.isConfigured(fresh, authorized: false), "Default-on Safari rules must not suppress a fresh welcome")
        precondition(IOSWelcomeEligibility.isConfigured(fresh, authorized: true))
        let flags: [WritableKeyPath<SharedState, Bool>] = [
            \.onboardingDone, \.broadcastActive, \.realtimeShieldEnabled,
            \.realtimeYouTubeBlockingEnabled, \.softYouTubeBlockingEnabled,
            \.realtimeInstagramReelsBlockingEnabled, \.realtimeInstagramStoriesBlockingEnabled,
            \.realtimeFacebookReelsBlockingEnabled, \.realtimeFacebookStoriesBlockingEnabled,
            \.realtimeXReelsBlockingEnabled
        ]
        for flag in flags {
            var snapshot = fresh
            snapshot[keyPath: flag] = true
            precondition(IOSWelcomeEligibility.isConfigured(snapshot, authorized: false))
        }
        let selections: [WritableKeyPath<SharedState, Data?>] = [
            \.youtubeSelectionData, \.instagramSelectionData, \.facebookSelectionData, \.xSelectionData
        ]
        for selection in selections {
            var snapshot = fresh
            snapshot[keyPath: selection] = Data([1])
            precondition(IOSWelcomeEligibility.isConfigured(snapshot, authorized: false), "Preserve users with saved selections even after permission revocation")
        }
        for site in SharedState.supportedSites {
            for feature in SiteFeature.available(for: site) {
                var snapshot = fresh
                snapshot.toggles[site]![feature].toggle()
                precondition(IOSWelcomeEligibility.isConfigured(snapshot, authorized: false))
            }
        }
        precondition(SharedStore.snapshot() == fresh, "Eligibility must not mutate existing settings")
        print("Welcome migration checks passed (authorization, 10 flags, 4 selections, every Safari control, no mutation)")
    }
}
