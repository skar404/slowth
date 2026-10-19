import Foundation

/// Migration checks only read existing settings; the welcome flag stays in local defaults.
enum IOSWelcomeEligibility {
    static func isConfigured(_ snapshot: SharedState, authorized: Bool) -> Bool {
        authorized || snapshot.onboardingDone || snapshot.broadcastActive
            || snapshot.youtubeSelectionData != nil || snapshot.instagramSelectionData != nil
            || snapshot.facebookSelectionData != nil || snapshot.xSelectionData != nil
            || snapshot.realtimeShieldEnabled || snapshot.realtimeYouTubeBlockingEnabled
            || snapshot.softYouTubeBlockingEnabled || snapshot.realtimeInstagramBlockingEnabled
            || snapshot.realtimeFacebookBlockingEnabled || snapshot.realtimeXBlockingEnabled
            || snapshot.toggles != SharedState.defaultState.toggles
    }
}
