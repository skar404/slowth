import Foundation
#if canImport(FamilyControls)
import FamilyControls
#endif

// Per-site blocking modes. The settings UI exists in TWO parallel implementations
// that BOTH enumerate these modes — when you add/rename/remove a mode, update both:
//   • Swift host apps: this enum + `defaultState` below + `modeLabel()` and the
//     `sites` arrays in Shared/ContentView_iOS.swift and Shared/ContentView_macOS.swift.
//   • JS Safari popup: WebExt/config.js (MODES, SITE_AVAILABLE_MODES, DEFAULT_TOGGLES)
//     and the label map in WebExt/app.js, plus enforcement in WebExt/background.js and
//     WebExt/content/common.js.
// Raw values are the wire format shared with JS — keep them identical to config.js.
enum SiteMode: String, Codable, CaseIterable {
    case off
    case shorts
    case feed
    case all
}

struct SharedState: Codable, Equatable {
    var toggles: [String: SiteMode]
    var strictModeUntil: Date?
    var rulesFetchedAt: Date?
    var onboardingDone: Bool
    var supportCardDismissed: Bool
    var realtimeShieldEnabled: Bool
    var realtimeYouTubeBlockingEnabled: Bool
    var realtimeInstagramReelsBlockingEnabled: Bool
    var realtimeInstagramStoriesBlockingEnabled: Bool
    var youtubeSelectionData: Data?
    var instagramSelectionData: Data?
    var broadcastActive: Bool
    var lastYouTubeShortsDetectionAt: Date?
    var lastInstagramReelsDetectionAt: Date?
    var lastInstagramStoriesDetectionAt: Date?
    var lastShieldActionInvokedAt: Date?
    var realtimeShieldDiagnostics: RealtimeShieldDiagnostics

    static let supportedSites = ["youtube", "instagram", "tiktok", "facebook", "x"]

    static var defaultState: SharedState {
        // ⚠️ Mirrors WebExt/config.js DEFAULT_TOGGLES — keep both in sync.
        SharedState(
            toggles: [
                "youtube":   .shorts,
                "instagram": .feed,
                "tiktok":    .all,
                "facebook":  .feed,
                "x":         .shorts
            ],
            strictModeUntil: nil,
            rulesFetchedAt: nil,
            onboardingDone: false,
            supportCardDismissed: false,
            realtimeShieldEnabled: false,
            realtimeYouTubeBlockingEnabled: false,
            realtimeInstagramReelsBlockingEnabled: false,
            realtimeInstagramStoriesBlockingEnabled: false,
            youtubeSelectionData: nil,
            instagramSelectionData: nil,
            broadcastActive: false,
            lastYouTubeShortsDetectionAt: nil,
            lastInstagramReelsDetectionAt: nil,
            lastInstagramStoriesDetectionAt: nil,
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
    static let toggles = "toggles"
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
    static let realtimeInstagramReelsBlockingEnabled = "realtimeInstagramReelsBlockingEnabled"
    static let realtimeInstagramStoriesBlockingEnabled = "realtimeInstagramStoriesBlockingEnabled"
    static let youtubeSelectionData = "youtubeSelectionData"
    static let instagramSelectionData = "instagramSelectionData"
    static let broadcastActive = "broadcastActive"
    static let lastYouTubeShortsDetectionAt = "lastYouTubeShortsDetectionAt"
    static let lastInstagramReelsDetectionAt = "lastInstagramReelsDetectionAt"
    static let lastInstagramStoriesDetectionAt = "lastInstagramStoriesDetectionAt"
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
        let raw = d.object(forKey: SharedStoreKey.toggles)
        var toggles = SharedState.defaultState.toggles
        if let dict = raw as? [String: String] {
            for site in SharedState.supportedSites {
                if let v = dict[site], let mode = SiteMode(rawValue: v) {
                    toggles[site] = mode
                }
            }
        } else if let bools = raw as? [String: Bool] {
            for site in SharedState.supportedSites {
                if let on = bools[site] {
                    toggles[site] = on ? (site == "tiktok" ? .all : .shorts) : .off
                }
            }
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
        if requestedYouTubeBlocking && !hasValidYouTubeSelection {
            // Normalize stale state left by an empty/cancelled picker result:
            // selecting an app later must not silently enable blocking.
            d.set(false, forKey: SharedStoreKey.realtimeYouTubeBlockingEnabled)
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

    static func setToggle(site: String, mode: SiteMode) throws -> SharedState {
        var state = snapshot()
        if state.isStrictModeActive { throw SharedStoreError.strictModeActive }
        guard SharedState.supportedSites.contains(site) else { throw SharedStoreError.invalidValue }
        state.toggles[site] = mode
        let dict = state.toggles.mapValues { $0.rawValue }
        d.set(dict, forKey: SharedStoreKey.toggles)
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
    static func resetStrictModeForDebug() {
        guard DebugMode.isEnabled else { return }
        d.removeObject(forKey: SharedStoreKey.strictModeUntil)
    }

    static func resetTipsDisplayForDebug() {
        guard DebugMode.isEnabled else { return }
        d.set(false, forKey: SharedStoreKey.supportCardDismissed)
    }

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
        #if canImport(FamilyControls)
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
        if snapshot().isStrictModeActive { throw SharedStoreError.strictModeActive }
        if let data = data {
            d.set(data, forKey: SharedStoreKey.youtubeSelectionData)
        } else {
            d.removeObject(forKey: SharedStoreKey.youtubeSelectionData)
        }
    }

    static func clearYouTubeSelection() throws {
        if snapshot().isStrictModeActive { throw SharedStoreError.strictModeActive }
        d.removeObject(forKey: SharedStoreKey.youtubeSelectionData)
        d.set(false, forKey: SharedStoreKey.realtimeYouTubeBlockingEnabled)
    }

    static func instagramSelectionData() -> Data? {
        d.data(forKey: SharedStoreKey.instagramSelectionData)
    }

    static func hasValidInstagramSelection() -> Bool {
        #if canImport(FamilyControls)
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
        if snapshot().isStrictModeActive { throw SharedStoreError.strictModeActive }
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
        return state
    }

    static func setRealtimeYouTubeBlockingEnabled(_ enabled: Bool) throws -> SharedState {
        var state = snapshot()
        if state.isStrictModeActive && !enabled { throw SharedStoreError.strictModeActive }
        if enabled && !hasValidYouTubeSelection() { throw SharedStoreError.invalidValue }
        state.realtimeYouTubeBlockingEnabled = enabled
        d.set(enabled, forKey: SharedStoreKey.realtimeYouTubeBlockingEnabled)
        return state
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
