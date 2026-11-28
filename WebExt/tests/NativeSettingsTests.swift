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
        defaults.set(true, forKey: SharedStoreKey.realtimeFacebookReelsBlockingEnabled)
        defaults.set(true, forKey: SharedStoreKey.realtimeFacebookStoriesBlockingEnabled)
        check(!SharedStore.snapshot().realtimeFacebookBlockingEnabled, "Missing selection disables stale Facebook flags")
        check(!defaults.bool(forKey: SharedStoreKey.realtimeFacebookReelsBlockingEnabled), "Stale Reels flag cleared")
        check(!defaults.bool(forKey: SharedStoreKey.realtimeFacebookStoriesBlockingEnabled), "Stale Stories flag cleared")
        do {
            _ = try SharedStore.setRealtimeFacebookStoriesBlockingEnabled(true)
            preconditionFailure("Facebook enabled without a valid selection")
        } catch SharedStoreError.invalidValue { }
        defaults.set(true, forKey: SharedStoreKey.realtimeXReelsBlockingEnabled)
        check(!SharedStore.snapshot().realtimeXBlockingEnabled, "Invalid X binding disables blocking")
        check(!defaults.bool(forKey: SharedStoreKey.realtimeXReelsBlockingEnabled), "Stale X flag cleared")
        do {
            _ = try SharedStore.setRealtimeXReelsBlockingEnabled(true)
            preconditionFailure("X enabled without a valid selection")
        } catch SharedStoreError.invalidValue { }
        reset()
        _ = try SharedStore.setStrictMode(true)
        let activated = SharedStore.snapshot()
        let start = activated.strictModeStartedAt!
        check(abs(activated.strictModeUntil!.timeIntervalSince(start) - 86400) < 0.001, "Lock still lasts 24 hours")
        check(activated.canCancelStrictMode(at: start), "Cancellation starts immediately")
        check(activated.canCancelStrictMode(at: start.addingTimeInterval(59.999)), "Cancellation lasts until 60 seconds")
        check(!activated.canCancelStrictMode(at: start.addingTimeInterval(60)), "Cancellation ends at exactly 60 seconds")
        check(!activated.canCancelStrictMode(at: start.addingTimeInterval(-1)), "A future activation does not allow cancellation")
        check(SharedStore.snapshot().canCancelStrictMode(), "Grace period survives reading persisted state")
        let repeated = try SharedStore.setStrictMode(true)
        check(repeated.strictModeStartedAt == start && repeated.strictModeUntil == activated.strictModeUntil,
              "Repeated enable preserves both deadlines")
        do {
            _ = try SharedStore.setToggle(site: "youtube", feature: .shorts, enabled: false)
            preconditionFailure("Restrictions must stay locked during the cancellation window")
        } catch SharedStoreError.strictModeActive { }
        let cancelled = try SharedStore.setStrictMode(false)
        check(!cancelled.isStrictModeActive && cancelled.strictModeStartedAt == nil, "Can cancel during grace")
        check(defaults.object(forKey: SharedStoreKey.strictModeStartedAt) == nil, "Cancellation removes persisted activation")
        _ = try SharedStore.setStrictMode(true)
        defaults.set(Date().addingTimeInterval(-61).timeIntervalSince1970, forKey: SharedStoreKey.strictModeStartedAt)
        do {
            _ = try SharedStore.setStrictMode(false)
            preconditionFailure("Cannot cancel after one minute")
        } catch SharedStoreError.strictModeActive { }
        _ = try SharedStore.setStrictMode(true)
        check(!SharedStore.snapshot().canCancelStrictMode(), "Re-enabling cannot reopen an expired grace period")
        defaults.removeObject(forKey: SharedStoreKey.strictModeStartedAt)
        do {
            _ = try SharedStore.setStrictMode(false)
            preconditionFailure("Existing locks without activation metadata stay locked")
        } catch SharedStoreError.strictModeActive { }
        defaults.set(Date().addingTimeInterval(-1).timeIntervalSince1970, forKey: SharedStoreKey.strictModeUntil)
        let renewed = try SharedStore.setStrictMode(true)
        check(renewed.canCancelStrictMode(), "A new activation after expiry gets its own grace period")
        reset()
        let fresh = SharedStore.snapshot()
        for site in SharedState.supportedSites {
            let settings = fresh.toggles[site]!
            check(settings.all == (site == "tiktok"), "Full-site defaults: \(site)")
            check(settings.shorts == ["youtube", "instagram", "facebook", "x"].contains(site), "Content defaults: \(site)")
            check(settings.feed == ["instagram", "facebook"].contains(site), "Feed defaults: \(site)")
        }
        let lightDefaults: [String: SiteFeature] = ["threads": .following, "reddit": .hidePromoted, "linkedin": .hidePromoted]
        for (site, feature) in lightDefaults {
            let enabled = SiteFeature.available(for: site).filter { fresh.toggles[site]![$0] }
            check(enabled == [feature], "Only the light filter starts enabled: \(site)")
            _ = try SharedStore.setToggle(site: site, feature: feature, enabled: false)
            check(!SharedStore.snapshot().toggles[site]![feature], "An explicit opt-out survives reload: \(site)")
            check(SiteBlockingSettings.migrated("off", site: site) == SiteBlockingSettings(), "Legacy off: \(site)")
        }
        let calendar = Calendar.current
        let firstDay = calendar.startOfDay(for: Date())
        let firstShow = calendar.date(byAdding: .hour, value: 20, to: firstDay)!
        let nextWeek = calendar.date(byAdding: .day, value: 7, to: firstDay)!
        for legacyInterval: Int? in [nil, 0, 1, 7, 30] {
            defaults.set(legacyInterval, forKey: "feedReminderDays")
            // Simulate an installation with a reminder shown before the update.
            defaults.set(firstShow.timeIntervalSince1970, forKey: "lastFeedReminder")
            check(!SharedStore.claimFeedReminder(now: nextWeek.addingTimeInterval(-1)), "Reminder stays hidden through day six")
            check(SharedStore.claimFeedReminder(now: nextWeek), "Reminder becomes eligible on day seven")
            check(!SharedStore.claimFeedReminder(now: nextWeek), "Another site must wait a new week")
        }
        defaults.removeObject(forKey: "lastFeedReminder")
        check(SharedStore.claimFeedReminder(now: firstShow), "First feed switch shows a reminder")
        let controls = SharedState.supportedSites.flatMap { SiteBlockingControl.controls(for: $0) }
        check(controls.count == 35, "Every Safari setting has a control")
        check(controls.contains { $0.id == "safari.instagram.stories" }, "Instagram exposes Stories")
        check(!fresh.toggles["instagram"]!.stories, "Stories hard block defaults off")
        let oldJSON = Data(#"{"shorts":false,"feed":true,"all":false}"#.utf8)
        let decoded = try JSONDecoder().decode(SiteBlockingSettings.self, from: oldJSON)
        check(decoded == SiteBlockingSettings(feed: true), "Older Codable settings retain choices")
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
        _ = try SharedStore.setToggle(site: "instagram", feature: .stories, enabled: true)
        _ = try SharedStore.setToggle(site: "instagram", feature: .all, enabled: true)
        _ = try SharedStore.setToggle(site: "instagram", feature: .all, enabled: false)
        check(SharedStore.snapshot().toggles["instagram"]!.stories, "Whole-site toggle preserves Stories")
        _ = try SharedStore.setToggle(site: "instagram", feature: .stories, enabled: false)
        defaults.set(Date().addingTimeInterval(3600).timeIntervalSince1970, forKey: SharedStoreKey.strictModeUntil)
        _ = try SharedStore.setToggle(site: "instagram", feature: .stories, enabled: true)
        do {
            _ = try SharedStore.setToggle(site: "instagram", feature: .stories, enabled: false)
            preconditionFailure("Strict mode allowed disabling Stories")
        } catch SharedStoreError.strictModeActive { }
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
        for (site, feature) in [("x", SiteFeature.feed), ("tiktok", .shorts), ("youtube", .stories), ("facebook", .stories), ("unknown", .all)] {
            do {
                _ = try SharedStore.setToggle(site: site, feature: feature, enabled: true)
                preconditionFailure("Unsupported feature accepted")
            } catch SharedStoreError.invalidValue { }
        }
        check(SiteFeature.available(for: "youtube") == [.shorts, .hideHomeFeed, .feed, .autoplayOff, .hideRelated, .all], "YouTube exposes feed")
        check(SiteFeature.available(for: "tiktok") == [.feed, .following, .hideUpsells, .all], "TikTok exposes feed")
        check(controls.contains { $0.id == "safari.tiktok.feed" }, "TikTok feed UI control")
        for raw: Any in ["off", "shorts", "feed", "all", true, false, ["all": false]] {
            check(!SiteBlockingSettings.migrated(raw, site: "tiktok").feed,
                  "Existing TikTok settings must not opt into feed blocking")
        }
        reset()
        _ = try SharedStore.setToggle(site: "tiktok", feature: .feed, enabled: true)
        _ = try SharedStore.setToggle(site: "tiktok", feature: .all, enabled: false)
        check(SharedStore.snapshot().toggles["tiktok"] == SiteBlockingSettings(feed: true),
              "TikTok feed persists independently of whole-site blocking")
        defaults.set(Date().addingTimeInterval(3600).timeIntervalSince1970, forKey: SharedStoreKey.strictModeUntil)
        do {
            _ = try SharedStore.setToggle(site: "tiktok", feature: .feed, enabled: false)
            preconditionFailure("Strict mode allowed disabling TikTok feed")
        } catch SharedStoreError.strictModeActive { }
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
        reset()
        check(!SharedStore.snapshot().toggles["youtube"]!.hideHomeFeed, "Home hiding defaults off")
        check(!decoded.hideHomeFeed, "Missing Codable flag defaults off")
        check(SiteFeature.available(for: "youtube").contains(.hideHomeFeed), "YouTube exposes home setting")
        for site in ["instagram", "facebook", "x", "tiktok"] {
            check(!SiteFeature.available(for: site).contains(.hideHomeFeed), "Home setting is YouTube-only")
        }
        _ = try SharedStore.setToggle(site: "youtube", feature: .hideHomeFeed, enabled: true)
        _ = try SharedStore.setToggle(site: "youtube", feature: .all, enabled: true)
        _ = try SharedStore.setToggle(site: "youtube", feature: .all, enabled: false)
        let homeSettings = SharedStore.snapshot().toggles["youtube"]!
        check(homeSettings.hideHomeFeed && homeSettings.shorts && !homeSettings.feed, "Independent persisted home choice")
        let roundTrip = try JSONDecoder().decode(SiteBlockingSettings.self, from: JSONEncoder().encode(homeSettings))
        check(roundTrip == homeSettings && homeSettings.dictionary["hideHomeFeed"] == true, "Home setting survives coding and wire serialization")
        _ = try SharedStore.setToggle(site: "youtube", feature: .hideHomeFeed, enabled: false)
        defaults.set(Date().addingTimeInterval(3600).timeIntervalSince1970, forKey: SharedStoreKey.strictModeUntil)
        _ = try SharedStore.setToggle(site: "youtube", feature: .hideHomeFeed, enabled: true)
        do {
            _ = try SharedStore.setToggle(site: "youtube", feature: .hideHomeFeed, enabled: false)
            preconditionFailure("Strict mode allowed showing the home feed")
        } catch SharedStoreError.strictModeActive { }
        print("Native Safari settings: defaults, migration, strict lock, independent toggles and persistence passed")
    }
}
