import Foundation

// Compile with Shared/SharedStore.swift, excluding the production AppGroup.
enum AppGroup {
    static let identifier = "test.safari-settings.\(UUID().uuidString)"
    static let defaults = UserDefaults(suiteName: identifier)!
}

@main
struct NativeSettingsTests {
    static func main() throws {
        let defaults = AppGroup.defaults
        defer { defaults.removePersistentDomain(forName: AppGroup.identifier) }
        func reset() { defaults.removePersistentDomain(forName: AppGroup.identifier) }
        func check(_ condition: @autoclosure () -> Bool, _ message: String) {
            precondition(condition(), message)
        }
        // Separate Facebook requests must never release Instagram or YouTube.
        let unlock = Date(timeIntervalSince1970: 12345)
        SharedStore.requestShieldUnlock(surface: .facebook, at: unlock)
        check(SharedStore.shieldUnlockRequestedAt(surface: .facebook) == unlock, "Facebook unlock persisted")
        check(SharedStore.shieldUnlockRequestedAt(surface: .instagram) == nil, "Instagram unlock independent")
        check(SharedStore.shieldUnlockRequestedAt(surface: .youtube) == nil, "YouTube unlock independent")
        defaults.set(true, forKey: SharedStoreKey.realtimeFacebookReelsBlockingEnabled)
        defaults.set(true, forKey: SharedStoreKey.realtimeFacebookStoriesBlockingEnabled)
        check(!SharedStore.snapshot().realtimeFacebookBlockingEnabled, "Missing selection disables stale Facebook flags")
        check(!defaults.bool(forKey: SharedStoreKey.realtimeFacebookReelsBlockingEnabled), "Stale Reels flag cleared")
        check(!defaults.bool(forKey: SharedStoreKey.realtimeFacebookStoriesBlockingEnabled), "Stale Stories flag cleared")
        do {
            _ = try SharedStore.setRealtimeFacebookStoriesBlockingEnabled(true)
            preconditionFailure("Facebook enabled without a valid selection")
        } catch SharedStoreError.invalidValue { }
        check(SharedStore.shieldUnlockRequestedAt(surface: .x) == nil, "X unlock independent")
        SharedStore.requestShieldUnlock(surface: .x, at: unlock.addingTimeInterval(1))
        check(SharedStore.shieldUnlockRequestedAt(surface: .x) == unlock.addingTimeInterval(1), "X unlock persisted")
        check(SharedStore.shieldUnlockRequestedAt(surface: .facebook) == unlock, "X unlock preserves Facebook request")
        defaults.set(true, forKey: SharedStoreKey.realtimeXReelsBlockingEnabled)
        check(!SharedStore.snapshot().realtimeXBlockingEnabled, "Invalid X binding disables blocking")
        check(!defaults.bool(forKey: SharedStoreKey.realtimeXReelsBlockingEnabled), "Stale X flag cleared")
        do {
            _ = try SharedStore.setRealtimeXReelsBlockingEnabled(true)
            preconditionFailure("X enabled without a valid selection")
        } catch SharedStoreError.invalidValue { }
        reset()
        let fresh = SharedStore.snapshot()
        for site in SharedState.supportedSites {
            let settings = fresh.toggles[site]!
            check(settings.all == (site == "tiktok"), "Full-site defaults: \(site)")
            check(settings.shorts == (site != "tiktok"), "Content defaults: \(site)")
            check(settings.feed == ["instagram", "facebook"].contains(site), "Feed defaults: \(site)")
        }
        let controls = SharedState.supportedSites.flatMap { SiteBlockingControl.controls(for: $0) }
        check(controls.count == 12, "Every Safari setting has a control")
        check(Set(controls.map(\.id)).count == controls.count, "Control IDs must be unique across sites")
        // For each UI control descriptor, flip its stored value in both directions
        // and compare every site's
        // complete persisted settings, including TikTok's default-on site block.
        for control in controls {
            for _ in 0..<2 {
                let before = SharedStore.snapshot().toggles
                var expected = before
                expected[control.site]![control.feature].toggle()
                _ = try SharedStore.setToggle(
                    site: control.site, feature: control.feature,
                    enabled: expected[control.site]![control.feature]
                )
                check(SharedStore.snapshot().toggles == expected,
                      "Changing \(control.id) must not change another control")
            }
        }
        for mode in ["off", "shorts", "feed", "all"] {
            reset()
            defaults.set(["instagram": mode, "facebook": mode], forKey: SharedStoreKey.toggles)
            let lock = Date().addingTimeInterval(3600).timeIntervalSince1970
            defaults.set(lock, forKey: SharedStoreKey.strictModeUntil)
            for site in ["instagram", "facebook"] {
                let settings = SharedStore.snapshot().toggles[site]!
                check(settings.all == (mode == "all"), "Migrate whole site")
                check(settings.shorts == (mode != "off"), "Migrate Reels")
                check(settings.feed == ["feed", "all"].contains(mode), "Migrate feed")
            }
            check(defaults.double(forKey: SharedStoreKey.strictModeUntil) == lock, "Migration preserves strict expiry")
            do {
                _ = try SharedStore.setToggle(site: "instagram", feature: .feed, enabled: false)
                preconditionFailure("Strict mode allowed a change")
            } catch SharedStoreError.strictModeActive { }
        }
        reset()
        defaults.set(["youtube": false, "instagram": true, "tiktok": true], forKey: SharedStoreKey.toggles)
        var state = SharedStore.snapshot()
        check(state.toggles["youtube"] == SiteBlockingSettings(), "Legacy disabled boolean")
        check(state.toggles["instagram"] == SiteBlockingSettings(shorts: true), "Legacy enabled boolean")
        check(state.toggles["tiktok"]!.all, "Legacy TikTok boolean")
        reset()
        for site in ["instagram", "facebook"] {
            _ = try SharedStore.setToggle(site: site, feature: .shorts, enabled: false)
            check(SharedStore.snapshot().toggles[site]!.feed, "Reels change must preserve feed")
            _ = try SharedStore.setToggle(site: site, feature: .all, enabled: true)
            _ = try SharedStore.setToggle(site: site, feature: .all, enabled: false)
            state = SharedStore.snapshot()
            check(!state.toggles[site]!.shorts && state.toggles[site]!.feed, "Whole-site toggle preserves content choices")
            _ = try SharedStore.setToggle(site: site, feature: .feed, enabled: false)
            _ = try SharedStore.setToggle(site: site, feature: .shorts, enabled: true)
            check(!SharedStore.snapshot().toggles[site]!.feed, "Reels must not enable feed")
        }
        // Migration is persisted once; subsequent legacy writes cannot erase choices.
        defaults.set(["instagram": "off"], forKey: SharedStoreKey.toggles)
        check(SharedStore.snapshot().toggles["instagram"]!.shorts, "V2 settings take priority")
        for (site, feature) in [("x", SiteFeature.feed), ("tiktok", .shorts), ("unknown", .all)] {
            do {
                _ = try SharedStore.setToggle(site: site, feature: feature, enabled: true)
                preconditionFailure("Unsupported feature accepted")
            } catch SharedStoreError.invalidValue { }
        }
        check(SiteFeature.available(for: "youtube") == [.shorts, .feed, .all], "YouTube exposes feed")
        check(controls.contains { $0.id == "safari.youtube.feed" }, "YouTube feed UI control")
        for raw: Any in ["off", "shorts", "feed", "all", true, false,
                         ["shorts": false, "all": true]] {
            reset()
            defaults.set(["youtube": raw], forKey: SharedStoreKey.toggles)
            let migrated = SharedStore.snapshot().toggles["youtube"]!
            check(!migrated.feed, "Legacy YouTube settings must not enable feed")
            check(SharedStore.snapshot().toggles["youtube"] == migrated, "Migration persists")
        }
        reset()
        defaults.set(["youtube": ["shorts": false, "all": true]], forKey: SharedStoreKey.siteBlocking)
        check(SharedStore.snapshot().toggles["youtube"] == SiteBlockingSettings(all: true),
              "Missing V2 feed defaults off and preserves choices")
        _ = try SharedStore.setToggle(site: "youtube", feature: .feed, enabled: true)
        _ = try SharedStore.setToggle(site: "youtube", feature: .all, enabled: false)
        check(SharedStore.snapshot().toggles["youtube"] == SiteBlockingSettings(feed: true),
              "YouTube feed persists independently of Shorts and whole-site blocking")
        reset()
        defaults.set(Date().addingTimeInterval(3600).timeIntervalSince1970, forKey: SharedStoreKey.strictModeUntil)
        _ = try SharedStore.setToggle(site: "youtube", feature: .feed, enabled: true)
        check(SharedStore.snapshot().toggles["youtube"]!.feed, "Strict mode permits enabling feed")
        do {
            _ = try SharedStore.setToggle(site: "youtube", feature: .feed, enabled: false)
            preconditionFailure("Strict mode allowed disabling YouTube feed")
        } catch SharedStoreError.strictModeActive { }
        do {
            _ = try SharedStore.setToggle(site: "youtube", feature: .all, enabled: true)
            preconditionFailure("Strict mode allowed enabling whole-site blocking")
        } catch SharedStoreError.strictModeActive { }
        defaults.set(Date().addingTimeInterval(-1).timeIntervalSince1970, forKey: SharedStoreKey.strictModeUntil)
        _ = try SharedStore.setToggle(site: "youtube", feature: .feed, enabled: false)
        check(!SharedStore.snapshot().toggles["youtube"]!.feed, "Expired strict lock permits disabling feed")
        print("Native Safari settings: defaults, migration, strict lock, independent toggles and persistence passed")
    }
}
