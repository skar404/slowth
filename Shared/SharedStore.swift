import Foundation
#if os(iOS) && canImport(FamilyControls)
import FamilyControls
#endif

// Keys are shared with WebExt/config.js. Legacy modes are read only during migration.
enum SiteFeature: String, CaseIterable {
    case shorts, feed, all

    static func available(for site: String) -> [SiteFeature] {
        switch site {
        case "instagram", "facebook": return [.shorts, .feed, .all]
        case "youtube", "x": return [.shorts, .all]
        case "tiktok": return [.all]
        default: return []
        }
    }

    func label(for site: String) -> String {
        switch self {
        case .all: return AppLocalization.string("Block site")
        case .feed: return AppLocalization.string("Block Infinite Feed")
        case .shorts:
            switch site {
            case "youtube": return AppLocalization.string("Block Shorts")
            case "x": return AppLocalization.string("Block Explore & trends")
            default: return AppLocalization.string("Block Reels")
            }
        }
    }
}

// Form can flatten nested ForEach rows. Scope control identity to both the site
// and feature so repeated features (especially "all") never reuse another site's row.
struct SiteBlockingControl: Identifiable {
    let site: String
    let feature: SiteFeature

    var id: String { "safari.\(site).\(feature.rawValue)" }

    static func controls(for site: String) -> [Self] {
        let features = SiteFeature.available(for: site)
        return features.sorted { ($0 == .all ? 0 : 1) < ($1 == .all ? 0 : 1) }
            .map { Self(site: site, feature: $0) }
    }
}

struct SiteBlockingSettings: Codable, Equatable {
    var shorts = false
    var feed = false
    var all = false

    subscript(feature: SiteFeature) -> Bool {
        get {
            switch feature {
            case .shorts: return shorts
            case .feed: return feed
            case .all: return all
            }
        }
        set {
            switch feature {
            case .shorts: shorts = newValue
            case .feed: feed = newValue
            case .all: all = newValue
            }
        }
    }

    var dictionary: [String: Bool] { ["shorts": shorts, "feed": feed, "all": all] }

    static func defaults(for site: String) -> Self {
        Self(shorts: site != "tiktok", feed: ["instagram", "facebook"].contains(site), all: site == "tiktok")
    }

    static func migrated(_ raw: Any?, site: String) -> Self {
        if let flags = raw as? [String: Bool] {
            var settings = defaults(for: site)
            for feature in SiteFeature.available(for: site) {
                if let value = flags[feature.rawValue] { settings[feature] = value }
            }
            return settings
        }
        let mode: String
        if let value = raw as? String { mode = value }
        else if let enabled = raw as? Bool { mode = enabled ? (site == "tiktok" ? "all" : "shorts") : "off" }
        else { return defaults(for: site) }
        switch mode {
        case "off": return Self()
        case "shorts": return Self(shorts: site != "tiktok")
        case "feed": return Self(shorts: site != "tiktok", feed: ["instagram", "facebook"].contains(site))
        case "all":
            var settings = defaults(for: site)
            settings.all = true
            return settings
        default: return defaults(for: site)
        }
    }
}

struct SharedState: Codable, Equatable {
    var toggles: [String: SiteBlockingSettings]
    var strictModeUntil: Date?
    var rulesFetchedAt: Date?
    var onboardingDone: Bool
    var supportCardDismissed: Bool
    var realtimeShieldEnabled: Bool
    var realtimeYouTubeBlockingEnabled: Bool
    var softYouTubeBlockingEnabled: Bool
    var youtubeShieldRestoreDeferred: Bool
    var realtimeInstagramReelsBlockingEnabled: Bool
    var realtimeInstagramStoriesBlockingEnabled: Bool
    var youtubeSelectionData: Data?
    var instagramSelectionData: Data?
    var broadcastActive: Bool
    var lastYouTubeShortsDetectionAt: Date?
    var lastInstagramReelsDetectionAt: Date?
    var lastInstagramStoriesDetectionAt: Date?
    var lastInstagramShieldPresentedAt: Date?
    var lastShieldActionInvokedAt: Date?
    var realtimeShieldDiagnostics: RealtimeShieldDiagnostics

    static let supportedSites = ["youtube", "instagram", "tiktok", "facebook", "x"]

    static var defaultState: SharedState {
        // ⚠️ Mirrors WebExt/config.js DEFAULT_TOGGLES — keep both in sync.
        SharedState(
            toggles: Dictionary(uniqueKeysWithValues: supportedSites.map { ($0, SiteBlockingSettings.defaults(for: $0)) }),
            strictModeUntil: nil,
            rulesFetchedAt: nil,
            onboardingDone: false,
            supportCardDismissed: false,
            realtimeShieldEnabled: false,
            realtimeYouTubeBlockingEnabled: false,
            softYouTubeBlockingEnabled: false,
            youtubeShieldRestoreDeferred: false,
            realtimeInstagramReelsBlockingEnabled: false,
            realtimeInstagramStoriesBlockingEnabled: false,
            youtubeSelectionData: nil,
            instagramSelectionData: nil,
            broadcastActive: false,
            lastYouTubeShortsDetectionAt: nil,
            lastInstagramReelsDetectionAt: nil,
            lastInstagramStoriesDetectionAt: nil,
            lastInstagramShieldPresentedAt: nil,
            lastShieldActionInvokedAt: nil,
            realtimeShieldDiagnostics: .empty
        )
    }

    var isStrictModeActive: Bool {
        guard let until = strictModeUntil else { return false }
        return until > Date()
    }

    var realtimeInstagramBlockingEnabled: Bool {
        realtimeInstagramReelsBlockingEnabled || realtimeInstagramStoriesBlockingEnabled
    }
}

struct RealtimeShieldDiagnostics: Codable, Equatable {
    var modelStatus: String
    var modelVersion: String?
    var receivedVideoFrames: Int
    var inferenceCount: Int
    var lastApp: String?
    var lastContent: String?
    var appProbabilities: [String: Double]?
    var contentProbabilities: [String: Double]?
    var jointProbabilities: [String: Double]?
    var confidenceThresholds: [String: Double]?
    var requiredConsecutiveHits: Int?
    var lastInferenceDurationMS: Double?
    var inferenceP95MS: Double?
    var youtubeShortsStreak: Int
    var instagramReelsStreak: Int
    var instagramStoriesStreak: Int
    var youtubeCandidateEvents: Int
    var instagramCandidateEvents: Int
    var instagramStoriesCandidateEvents: Int
    var youtubeShieldLatched: Bool
    var instagramShieldLatched: Bool
    var youtubeGraceRemainingSeconds: Double?
    var instagramGraceRemainingSeconds: Double?
    var lastClassifierError: String?
    var availableMemoryMB: Double?
    var currentFootprintMB: Double?
    var peakFootprintMB: Double?
    var updatedAt: Date?

    static let empty = RealtimeShieldDiagnostics(
        modelStatus: "not started",
        modelVersion: nil,
        receivedVideoFrames: 0,
        inferenceCount: 0,
        lastApp: nil,
        lastContent: nil,
        appProbabilities: nil,
        contentProbabilities: nil,
        jointProbabilities: nil,
        confidenceThresholds: nil,
        requiredConsecutiveHits: nil,
        lastInferenceDurationMS: nil,
        inferenceP95MS: nil,
        youtubeShortsStreak: 0,
        instagramReelsStreak: 0,
        instagramStoriesStreak: 0,
        youtubeCandidateEvents: 0,
        instagramCandidateEvents: 0,
        instagramStoriesCandidateEvents: 0,
        youtubeShieldLatched: false,
        instagramShieldLatched: false,
        youtubeGraceRemainingSeconds: nil,
        instagramGraceRemainingSeconds: nil,
        lastClassifierError: nil,
        availableMemoryMB: nil,
        currentFootprintMB: nil,
        peakFootprintMB: nil,
        updatedAt: nil
    )
}

enum SharedStoreKey {
    static let toggles = "toggles" // Legacy modes, retained for migration.
    static let siteBlocking = "siteBlockingV2"
    static let strictModeUntil = "strictModeUntil"
    static let rules = "rules"
    static let rulesEtag = "rulesEtag"
    static let rulesFetchedAt = "rulesFetchedAt"
    static let rulesLastAttemptAt = "rulesLastAttemptAt"
    static let blockedAppsData = "blockedAppsData"
    static let onboardingDone = "onboardingDone"
    static let supportCardDismissed = "supportCardDismissed"
    static let realtimeShieldEnabled = "realtimeShieldEnabled"
    static let realtimeYouTubeBlockingEnabled = "realtimeYouTubeBlockingEnabled"
    static let softYouTubeBlockingEnabled = "softYouTubeBlockingEnabled"
    static let youtubeShieldRestoreDeferred = "youtubeShieldRestoreDeferred"
    static let softYouTubeMonitorGeneration = "softYouTubeMonitorGeneration"
    static let slowthAppForeground = "slowthAppForeground"
    static let realtimeInstagramReelsBlockingEnabled = "realtimeInstagramReelsBlockingEnabled"
    static let realtimeInstagramStoriesBlockingEnabled = "realtimeInstagramStoriesBlockingEnabled"
    static let youtubeSelectionData = "youtubeSelectionData"
    static let instagramSelectionData = "instagramSelectionData"
    static let broadcastActive = "broadcastActive"
    static let lastYouTubeShortsDetectionAt = "lastYouTubeShortsDetectionAt"
    static let lastInstagramReelsDetectionAt = "lastInstagramReelsDetectionAt"
    static let lastInstagramStoriesDetectionAt = "lastInstagramStoriesDetectionAt"
    static let lastInstagramShieldPresentedAt = "lastInstagramShieldPresentedAt"
    static let lastShieldActionInvokedAt = "lastShieldActionInvokedAt"
    static let realtimeRecordingPromptRequestedAt = "realtimeRecordingPromptRequestedAt"
    static let youtubeShieldUnlockRequestedAt = "youtubeShieldUnlockRequestedAt"
    static let instagramShieldUnlockRequestedAt = "instagramShieldUnlockRequestedAt"
    static let realtimeShieldDiagnostics = "realtimeShieldDiagnostics"
}

enum RealtimeShieldSurface: String {
    case youtube
    case instagram
}

enum SharedStoreError: Error {
    case strictModeActive
    case invalidValue
}

enum SharedStore {
    private static var d: UserDefaults { AppGroup.defaults }

    static func snapshot() -> SharedState {
        let stored = d.dictionary(forKey: SharedStoreKey.siteBlocking)
        let legacy = d.dictionary(forKey: SharedStoreKey.toggles) ?? [:]
        let toggles = Dictionary(uniqueKeysWithValues: SharedState.supportedSites.map { site in
            (site, SiteBlockingSettings.migrated(stored?[site] ?? legacy[site], site: site))
        })
        // Representation-only migration is safe during Strict mode: effective blocking is unchanged.
        if stored == nil {
            d.set(toggles.mapValues { $0.dictionary }, forKey: SharedStoreKey.siteBlocking)
        }

        var until: Date? = nil
        if let ts = d.object(forKey: SharedStoreKey.strictModeUntil) as? Double, ts > 0 {
            let date = Date(timeIntervalSince1970: ts)
            if date > Date() { until = date }
        }

        let fetchedAt: Date? = {
            let ts = d.double(forKey: SharedStoreKey.rulesFetchedAt)
            return ts > 0 ? Date(timeIntervalSince1970: ts) : nil
        }()

        let onboardingDone = d.bool(forKey: SharedStoreKey.onboardingDone)
        let supportCardDismissed = d.bool(forKey: SharedStoreKey.supportCardDismissed)
        let realtimeShieldEnabled = d.bool(forKey: SharedStoreKey.realtimeShieldEnabled)
        let hasValidYouTubeSelection = hasValidYouTubeSelection()
        let requestedYouTubeBlocking = d.bool(forKey: SharedStoreKey.realtimeYouTubeBlockingEnabled)
        let realtimeYouTubeBlockingEnabled = requestedYouTubeBlocking && hasValidYouTubeSelection
        let softYouTubeBlockingEnabled = d.bool(forKey: SharedStoreKey.softYouTubeBlockingEnabled)
        var youtubeShieldRestoreDeferred = d.bool(
            forKey: SharedStoreKey.youtubeShieldRestoreDeferred
        )
        if requestedYouTubeBlocking && !hasValidYouTubeSelection {
            // Normalize stale state left by an empty/cancelled picker result:
            // selecting an app later must not silently enable blocking.
            d.set(false, forKey: SharedStoreKey.realtimeYouTubeBlockingEnabled)
        }
        if youtubeShieldRestoreDeferred
            && (!realtimeShieldEnabled
                || !realtimeYouTubeBlockingEnabled
                || !softYouTubeBlockingEnabled) {
            // A deferral only makes sense while every part of soft YouTube
            // blocking is still enabled. Normalize stale cross-process state.
            youtubeShieldRestoreDeferred = false
            d.set(false, forKey: SharedStoreKey.youtubeShieldRestoreDeferred)
        }
        let hasValidInstagramSelection = hasValidInstagramSelection()
        let requestedInstagramReelsBlocking = d.bool(
            forKey: SharedStoreKey.realtimeInstagramReelsBlockingEnabled
        )
        let requestedInstagramStoriesBlocking = d.bool(
            forKey: SharedStoreKey.realtimeInstagramStoriesBlockingEnabled
        )
        let realtimeInstagramReelsBlockingEnabled = requestedInstagramReelsBlocking
            && hasValidInstagramSelection
        let realtimeInstagramStoriesBlockingEnabled = requestedInstagramStoriesBlocking
            && hasValidInstagramSelection
        if !hasValidInstagramSelection {
            if requestedInstagramReelsBlocking {
                d.set(false, forKey: SharedStoreKey.realtimeInstagramReelsBlockingEnabled)
            }
            if requestedInstagramStoriesBlocking {
                d.set(false, forKey: SharedStoreKey.realtimeInstagramStoriesBlockingEnabled)
            }
        }
        let broadcastActive = d.bool(forKey: SharedStoreKey.broadcastActive)

        func date(forKey key: String) -> Date? {
            let ts = d.double(forKey: key)
            return ts > 0 ? Date(timeIntervalSince1970: ts) : nil
        }

        return SharedState(
            toggles: toggles,
            strictModeUntil: until,
            rulesFetchedAt: fetchedAt,
            onboardingDone: onboardingDone,
            supportCardDismissed: supportCardDismissed,
            realtimeShieldEnabled: realtimeShieldEnabled,
            realtimeYouTubeBlockingEnabled: realtimeYouTubeBlockingEnabled,
            softYouTubeBlockingEnabled: softYouTubeBlockingEnabled,
            youtubeShieldRestoreDeferred: youtubeShieldRestoreDeferred,
            realtimeInstagramReelsBlockingEnabled: realtimeInstagramReelsBlockingEnabled,
            realtimeInstagramStoriesBlockingEnabled: realtimeInstagramStoriesBlockingEnabled,
            youtubeSelectionData: d.data(forKey: SharedStoreKey.youtubeSelectionData),
            instagramSelectionData: d.data(forKey: SharedStoreKey.instagramSelectionData),
            broadcastActive: broadcastActive,
            lastYouTubeShortsDetectionAt: date(forKey: SharedStoreKey.lastYouTubeShortsDetectionAt),
            lastInstagramReelsDetectionAt: date(forKey: SharedStoreKey.lastInstagramReelsDetectionAt),
            lastInstagramStoriesDetectionAt: date(
                forKey: SharedStoreKey.lastInstagramStoriesDetectionAt
            ),
            lastInstagramShieldPresentedAt: date(
                forKey: SharedStoreKey.lastInstagramShieldPresentedAt
            ),
            lastShieldActionInvokedAt: date(forKey: SharedStoreKey.lastShieldActionInvokedAt),
            realtimeShieldDiagnostics: {
                guard let data = d.data(forKey: SharedStoreKey.realtimeShieldDiagnostics),
                      let value = try? JSONDecoder().decode(RealtimeShieldDiagnostics.self, from: data) else {
                    return .empty
                }
                return value
            }()
        )
    }

    static func setToggle(site: String, feature: SiteFeature, enabled: Bool) throws -> SharedState {
        var state = snapshot()
        guard SiteFeature.available(for: site).contains(feature),
              var settings = state.toggles[site] else { throw SharedStoreError.invalidValue }
        // Strict mode permits strengthening an existing policy, but never
        // permits weakening it or enabling whole-site blocking.
        if state.isStrictModeActive && (!enabled || feature == .all) {
            throw SharedStoreError.strictModeActive
        }
        settings[feature] = enabled
        state.toggles[site] = settings
        d.set(state.toggles.mapValues { $0.dictionary }, forKey: SharedStoreKey.siteBlocking)
        return state
    }

    static func setStrictMode(_ enabled: Bool) throws -> SharedState {
        var state = snapshot()
        if state.isStrictModeActive && !enabled {
            throw SharedStoreError.strictModeActive
        }
        if enabled {
            let until = Date().addingTimeInterval(24 * 3600)
            state.strictModeUntil = until
            d.set(until.timeIntervalSince1970, forKey: SharedStoreKey.strictModeUntil)
        } else {
            state.strictModeUntil = nil
            d.removeObject(forKey: SharedStoreKey.strictModeUntil)
        }
        return state
    }

    static func saveRules(json: Data, etag: String?) throws {
        let state = snapshot()
        if state.isStrictModeActive { throw SharedStoreError.strictModeActive }
        d.set(json, forKey: SharedStoreKey.rules)
        if let etag = etag, !etag.isEmpty {
            d.set(etag, forKey: SharedStoreKey.rulesEtag)
        }
        d.set(Date().timeIntervalSince1970, forKey: SharedStoreKey.rulesFetchedAt)
    }

    static func rulesJSON() -> Data? {
        d.data(forKey: SharedStoreKey.rules)
    }

    static func rulesEtag() -> String? {
        d.string(forKey: SharedStoreKey.rulesEtag)
    }

    static func rulesLastAttemptAt() -> Date? {
        let ts = d.double(forKey: SharedStoreKey.rulesLastAttemptAt)
        return ts > 0 ? Date(timeIntervalSince1970: ts) : nil
    }

    static func setRulesLastAttemptAt(_ date: Date) {
        d.set(date.timeIntervalSince1970, forKey: SharedStoreKey.rulesLastAttemptAt)
    }

    static func setOnboardingDone(_ value: Bool) {
        d.set(value, forKey: SharedStoreKey.onboardingDone)
    }

    static func setSupportCardDismissed(_ value: Bool) {
        d.set(value, forKey: SharedStoreKey.supportCardDismissed)
    }

    // Local debug escape hatches. Keep these separate from the production
    // setters so Strict mode cannot be weakened through normal app flows.
    #if DEBUG
    static func resetStrictModeForDebug() {
        guard DebugMode.isEnabled else { return }
        d.removeObject(forKey: SharedStoreKey.strictModeUntil)
    }
    #endif

    #if DEBUG
    static func resetTipsDisplayForDebug() {
        guard DebugMode.isEnabled else { return }
        d.set(false, forKey: SharedStoreKey.supportCardDismissed)
    }
    #endif

    static func blockedAppsData() -> Data? {
        d.data(forKey: SharedStoreKey.blockedAppsData)
    }

    static func setBlockedAppsData(_ data: Data?) {
        if let data = data {
            d.set(data, forKey: SharedStoreKey.blockedAppsData)
        } else {
            d.removeObject(forKey: SharedStoreKey.blockedAppsData)
        }
    }

    // MARK: - Real-time (broadcast-gated) app blocking

    static func youtubeSelectionData() -> Data? {
        d.data(forKey: SharedStoreKey.youtubeSelectionData)
    }

    static func hasValidYouTubeSelection() -> Bool {
        #if os(iOS) && canImport(FamilyControls)
        guard let data = youtubeSelectionData(),
              let selection = try? JSONDecoder().decode(FamilyActivitySelection.self, from: data) else {
            return false
        }
        return selection.applicationTokens.count == 1
            && selection.categoryTokens.isEmpty
            && selection.webDomainTokens.isEmpty
        #else
        return false
        #endif
    }

    // Picking (or repointing) which app gets shielded is a loosening move while
    // strict mode is active (it changes what's blocked), so gate it the same
    // disable-direction way as setRealtimeShieldEnabled/setStrictMode(false).
    static func setYouTubeSelectionData(_ data: Data?) throws {
        // Strict mode permits the initial binding (which only adds
        // protection), but freezes an already selected app in place.
        if snapshot().isStrictModeActive && hasValidYouTubeSelection() {
            throw SharedStoreError.strictModeActive
        }
        if let data = data {
            d.set(data, forKey: SharedStoreKey.youtubeSelectionData)
        } else {
            d.removeObject(forKey: SharedStoreKey.youtubeSelectionData)
            d.set(false, forKey: SharedStoreKey.youtubeShieldRestoreDeferred)
            d.removeObject(forKey: SharedStoreKey.softYouTubeMonitorGeneration)
        }
    }

    static func clearYouTubeSelection() throws {
        if snapshot().isStrictModeActive { throw SharedStoreError.strictModeActive }
        d.removeObject(forKey: SharedStoreKey.youtubeSelectionData)
        d.set(false, forKey: SharedStoreKey.realtimeYouTubeBlockingEnabled)
        d.set(false, forKey: SharedStoreKey.youtubeShieldRestoreDeferred)
        d.removeObject(forKey: SharedStoreKey.softYouTubeMonitorGeneration)
    }

    static func instagramSelectionData() -> Data? {
        d.data(forKey: SharedStoreKey.instagramSelectionData)
    }

    static func hasValidInstagramSelection() -> Bool {
        #if os(iOS) && canImport(FamilyControls)
        guard let data = instagramSelectionData(),
              let selection = try? JSONDecoder().decode(FamilyActivitySelection.self, from: data) else {
            return false
        }
        return selection.applicationTokens.count == 1
            && selection.categoryTokens.isEmpty
            && selection.webDomainTokens.isEmpty
        #else
        return false
        #endif
    }

    static func setInstagramSelectionData(_ data: Data?) throws {
        // Strict mode permits the initial binding, but not replacing it.
        if snapshot().isStrictModeActive && hasValidInstagramSelection() {
            throw SharedStoreError.strictModeActive
        }
        if let data = data {
            d.set(data, forKey: SharedStoreKey.instagramSelectionData)
        } else {
            d.removeObject(forKey: SharedStoreKey.instagramSelectionData)
        }
    }

    static func clearInstagramSelection() throws {
        if snapshot().isStrictModeActive { throw SharedStoreError.strictModeActive }
        d.removeObject(forKey: SharedStoreKey.instagramSelectionData)
        d.set(false, forKey: SharedStoreKey.realtimeInstagramReelsBlockingEnabled)
        d.set(false, forKey: SharedStoreKey.realtimeInstagramStoriesBlockingEnabled)
    }

    // Enabling stricter blocking is never blocked by strict mode (mirrors
    // setStrictMode's own asymmetry) — only turning it back off is.
    static func setRealtimeShieldEnabled(_ enabled: Bool) throws -> SharedState {
        var state = snapshot()
        if state.isStrictModeActive && !enabled { throw SharedStoreError.strictModeActive }
        state.realtimeShieldEnabled = enabled
        d.set(enabled, forKey: SharedStoreKey.realtimeShieldEnabled)
        if !enabled {
            d.set(false, forKey: SharedStoreKey.youtubeShieldRestoreDeferred)
            d.removeObject(forKey: SharedStoreKey.softYouTubeMonitorGeneration)
        }
        return snapshot()
    }

    static func setRealtimeYouTubeBlockingEnabled(_ enabled: Bool) throws -> SharedState {
        var state = snapshot()
        if state.isStrictModeActive && !enabled { throw SharedStoreError.strictModeActive }
        if enabled && !hasValidYouTubeSelection() { throw SharedStoreError.invalidValue }
        state.realtimeYouTubeBlockingEnabled = enabled
        d.set(enabled, forKey: SharedStoreKey.realtimeYouTubeBlockingEnabled)
        if !enabled {
            d.set(false, forKey: SharedStoreKey.youtubeShieldRestoreDeferred)
            d.removeObject(forKey: SharedStoreKey.softYouTubeMonitorGeneration)
        }
        return snapshot()
    }

    // Soft mode is a deliberate weakening: while Slowth is foregrounded,
    // YouTube remains unshielded; after Slowth leaves the foreground (or
    // ReplayKit stops), YouTube gets a one-second usage threshold before its
    // shield returns. Strict mode normally blocks enabling soft mode; the
    // initial app binding may explicitly authorize that one-time setup.
    static func setSoftYouTubeBlockingEnabled(
        _ enabled: Bool,
        allowInitialStrictActivation: Bool = false
    ) throws -> SharedState {
        let state = snapshot()
        if state.isStrictModeActive && enabled && !allowInitialStrictActivation {
            throw SharedStoreError.strictModeActive
        }
        if enabled && !state.realtimeYouTubeBlockingEnabled {
            throw SharedStoreError.invalidValue
        }
        d.set(enabled, forKey: SharedStoreKey.softYouTubeBlockingEnabled)
        if !enabled {
            d.set(false, forKey: SharedStoreKey.youtubeShieldRestoreDeferred)
            d.removeObject(forKey: SharedStoreKey.softYouTubeMonitorGeneration)
        }
        return snapshot()
    }

    static func setRealtimeInstagramReelsBlockingEnabled(_ enabled: Bool) throws -> SharedState {
        var state = snapshot()
        if state.isStrictModeActive && !enabled { throw SharedStoreError.strictModeActive }
        if enabled && !hasValidInstagramSelection() { throw SharedStoreError.invalidValue }
        state.realtimeInstagramReelsBlockingEnabled = enabled
        d.set(enabled, forKey: SharedStoreKey.realtimeInstagramReelsBlockingEnabled)
        return state
    }

    static func setRealtimeInstagramStoriesBlockingEnabled(_ enabled: Bool) throws -> SharedState {
        var state = snapshot()
        if state.isStrictModeActive && !enabled { throw SharedStoreError.strictModeActive }
        if enabled && !hasValidInstagramSelection() { throw SharedStoreError.invalidValue }
        state.realtimeInstagramStoriesBlockingEnabled = enabled
        d.set(enabled, forKey: SharedStoreKey.realtimeInstagramStoriesBlockingEnabled)
        return state
    }

    // Written by the Broadcast Upload Extension reacting to OS broadcast
    // lifecycle events, not a user settings change — never gated by strict
    // mode. Gating this could leave the shield's own re-detection loop stuck.
    static func setBroadcastActive(_ active: Bool) {
        d.set(active, forKey: SharedStoreKey.broadcastActive)
        if active {
            // An active broadcast is controlled by the classifier, not by an
            // at-rest restoration deferral left by a previous session.
            d.set(false, forKey: SharedStoreKey.youtubeShieldRestoreDeferred)
            d.removeObject(forKey: SharedStoreKey.softYouTubeMonitorGeneration)
        }
    }

    // Internal lifecycle state shared by the host app and broadcast extension.
    // This is not a user setting, so Strict mode does not gate it.
    static func setYouTubeShieldRestoreDeferred(_ deferred: Bool) {
        d.set(deferred, forKey: SharedStoreKey.youtubeShieldRestoreDeferred)
    }

    static func isSlowthAppForeground() -> Bool {
        d.synchronize()
        return d.bool(forKey: SharedStoreKey.slowthAppForeground)
    }

    static func setSlowthAppForeground(_ foreground: Bool) {
        d.set(foreground, forKey: SharedStoreKey.slowthAppForeground)
        d.synchronize()
    }

    static func softYouTubeMonitorGeneration() -> String? {
        d.synchronize()
        return d.string(forKey: SharedStoreKey.softYouTubeMonitorGeneration)
    }

    static func setSoftYouTubeMonitorGeneration(_ generation: String?) {
        if let generation {
            d.set(generation, forKey: SharedStoreKey.softYouTubeMonitorGeneration)
        } else {
            d.removeObject(forKey: SharedStoreKey.softYouTubeMonitorGeneration)
        }
        d.synchronize()
    }

    @discardableResult
    static func clearSoftYouTubeMonitorGeneration(ifMatching generation: String) -> Bool {
        guard softYouTubeMonitorGeneration() == generation else { return false }
        setSoftYouTubeMonitorGeneration(nil)
        return true
    }

    static func clearRetiredDeviceActivityState() {
        d.removeObject(forKey: "lastInstagramUsageThresholdAt")
    }

    static func setLastYouTubeShortsDetectionAt(_ date: Date) {
        d.set(date.timeIntervalSince1970, forKey: SharedStoreKey.lastYouTubeShortsDetectionAt)
    }

    static func setLastInstagramReelsDetectionAt(_ date: Date) {
        d.set(date.timeIntervalSince1970, forKey: SharedStoreKey.lastInstagramReelsDetectionAt)
    }

    static func setLastInstagramStoriesDetectionAt(_ date: Date) {
        d.set(date.timeIntervalSince1970, forKey: SharedStoreKey.lastInstagramStoriesDetectionAt)
    }

    static func setLastInstagramShieldPresentedAt(_ date: Date) {
        d.set(date.timeIntervalSince1970, forKey: SharedStoreKey.lastInstagramShieldPresentedAt)
    }

    // Diagnostic only: confirms the Shield Action Extension is actually being
    // invoked by the OS, independent of what it does afterwards.
    static func setLastShieldActionInvokedAt(_ date: Date) {
        d.set(date.timeIntervalSince1970, forKey: SharedStoreKey.lastShieldActionInvokedAt)
    }

    static func requestRealtimeRecordingPrompt(at date: Date = Date()) {
        let defaults = d
        defaults.set(date.timeIntervalSince1970,
                     forKey: SharedStoreKey.realtimeRecordingPromptRequestedAt)
        defaults.synchronize()
    }

    static func consumeRealtimeRecordingPromptRequest() -> Bool {
        let defaults = d
        defaults.synchronize()
        guard defaults.double(forKey: SharedStoreKey.realtimeRecordingPromptRequestedAt) > 0 else {
            return false
        }
        defaults.removeObject(forKey: SharedStoreKey.realtimeRecordingPromptRequestedAt)
        defaults.synchronize()
        return true
    }

    static func requestShieldUnlock(surface: RealtimeShieldSurface, at date: Date = Date()) {
        let key = surface == .youtube
            ? SharedStoreKey.youtubeShieldUnlockRequestedAt
            : SharedStoreKey.instagramShieldUnlockRequestedAt
        d.set(date.timeIntervalSince1970, forKey: key)
    }

    static func shieldUnlockRequestedAt(surface: RealtimeShieldSurface) -> Date? {
        let key = surface == .youtube
            ? SharedStoreKey.youtubeShieldUnlockRequestedAt
            : SharedStoreKey.instagramShieldUnlockRequestedAt
        guard let seconds = d.object(forKey: key) as? Double else { return nil }
        return Date(timeIntervalSince1970: seconds)
    }

    static func setRealtimeShieldDiagnostics(_ diagnostics: RealtimeShieldDiagnostics) {
        guard let data = try? JSONEncoder().encode(diagnostics) else { return }
        d.set(data, forKey: SharedStoreKey.realtimeShieldDiagnostics)
    }
}
