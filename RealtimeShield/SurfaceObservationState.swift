import Foundation

/// Sliding-window votes and cumulative threshold crossings, without enforcement policy.
struct SurfaceObservationState {
    private(set) var youtubeShortsStreak = 0
    private(set) var instagramReelsStreak = 0
    private(set) var facebookReelsStreak = 0
    private(set) var xReelsStreak = 0
    private(set) var instagramStoriesStreak = 0
    private(set) var facebookStoriesStreak = 0
    private(set) var youtubeShortsVotes: [Bool] = []
    private(set) var instagramReelsVotes: [Bool] = []
    private(set) var facebookReelsVotes: [Bool] = []
    private(set) var xReelsVotes: [Bool] = []
    private(set) var instagramStoriesVotes: [Bool] = []
    private(set) var facebookStoriesVotes: [Bool] = []
    private(set) var youtubeCandidateEvents = 0
    private(set) var instagramCandidateEvents = 0
    private(set) var facebookCandidateEvents = 0
    private(set) var xCandidateEvents = 0
    private(set) var instagramStoriesCandidateEvents = 0
    private(set) var facebookStoriesCandidateEvents = 0

    mutating func append(
        youtubeVerdict: Bool,
        instagramReelsVerdict: Bool,
        instagramStoriesVerdict: Bool,
        facebookReelsVerdict: Bool,
        xReelsVerdict: Bool,
        facebookStoriesVerdict: Bool,
        requiredHits: Int,
        observationWindowFrames: Int
    ) {
        let previousYouTubeHits = youtubeShortsStreak
        let previousReelsHits = instagramReelsStreak
        let previousStoriesHits = instagramStoriesStreak
        youtubeShortsStreak = CascadeEvidenceBoundary.appendVote(
            youtubeVerdict, to: &youtubeShortsVotes, window: observationWindowFrames
        )
        instagramReelsStreak = CascadeEvidenceBoundary.appendVote(
            instagramReelsVerdict, to: &instagramReelsVotes, window: observationWindowFrames
        )
        instagramStoriesStreak = CascadeEvidenceBoundary.appendVote(
            instagramStoriesVerdict, to: &instagramStoriesVotes, window: observationWindowFrames
        )
        if previousYouTubeHits < requiredHits && youtubeShortsStreak >= requiredHits {
            youtubeCandidateEvents += 1
        }
        if previousReelsHits < requiredHits && instagramReelsStreak >= requiredHits {
            instagramCandidateEvents += 1
        }
        if previousStoriesHits < requiredHits && instagramStoriesStreak >= requiredHits {
            instagramStoriesCandidateEvents += 1
        }
        let previousFacebookReelsHits = facebookReelsStreak
        let previousXReelsHits = xReelsStreak
        let previousFacebookStoriesHits = facebookStoriesStreak
        facebookReelsStreak = CascadeEvidenceBoundary.appendVote(facebookReelsVerdict, to: &facebookReelsVotes, window: observationWindowFrames)
        xReelsStreak = CascadeEvidenceBoundary.appendVote(xReelsVerdict, to: &xReelsVotes, window: observationWindowFrames)
        facebookStoriesStreak = CascadeEvidenceBoundary.appendVote(facebookStoriesVerdict, to: &facebookStoriesVotes, window: observationWindowFrames)
        if previousFacebookReelsHits < requiredHits && facebookReelsStreak >= requiredHits { facebookCandidateEvents += 1 }
        if previousXReelsHits < requiredHits && xReelsStreak >= requiredHits { xCandidateEvents += 1 }
        if previousFacebookStoriesHits < requiredHits && facebookStoriesStreak >= requiredHits { facebookStoriesCandidateEvents += 1 }

    }

    mutating func resetObservations() {
        youtubeShortsStreak = 0
        instagramReelsStreak = 0
        facebookReelsStreak = 0
        xReelsStreak = 0
        instagramStoriesStreak = 0
        facebookStoriesStreak = 0
        youtubeShortsVotes.removeAll(keepingCapacity: true)
        instagramReelsVotes.removeAll(keepingCapacity: true)
        facebookReelsVotes.removeAll(keepingCapacity: true)
        xReelsVotes.removeAll(keepingCapacity: true)
        instagramStoriesVotes.removeAll(keepingCapacity: true)
        facebookStoriesVotes.removeAll(keepingCapacity: true)
    }

    mutating func reset(service: SurfaceApp) {
        switch service {
        case .youtube:
            youtubeShortsVotes.removeAll(keepingCapacity: true)
            youtubeShortsStreak = 0
        case .instagram:
            instagramReelsVotes.removeAll(keepingCapacity: true)
            instagramReelsStreak = 0
            instagramStoriesVotes.removeAll(keepingCapacity: true)
            instagramStoriesStreak = 0
        case .facebook:
            facebookReelsVotes.removeAll(keepingCapacity: true)
            facebookReelsStreak = 0
            facebookStoriesVotes.removeAll(keepingCapacity: true)
            facebookStoriesStreak = 0
        case .x:
            xReelsVotes.removeAll(keepingCapacity: true)
            xReelsStreak = 0
        case .other: break
        }
    }

    mutating func resetSession() {
        resetObservations()
        youtubeCandidateEvents = 0
        instagramCandidateEvents = 0
        facebookCandidateEvents = 0
        xCandidateEvents = 0
        instagramStoriesCandidateEvents = 0
        facebookStoriesCandidateEvents = 0
    }
}
