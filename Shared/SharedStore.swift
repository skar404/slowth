import Foundation

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
            onboardingDone: false
        )
    }

    var isStrictModeActive: Bool {
        guard let until = strictModeUntil else { return false }
        return until > Date()
    }
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

        return SharedState(
            toggles: toggles,
            strictModeUntil: until,
            rulesFetchedAt: fetchedAt,
            onboardingDone: onboardingDone
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
}
