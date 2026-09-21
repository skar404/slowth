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
        let fresh = SharedStore.snapshot()
        for site in SharedState.supportedSites {
            let settings = fresh.toggles[site]!
            check(settings.all == (site == "tiktok"), "Full-site defaults: \(site)")
            check(settings.shorts == (site != "tiktok"), "Content defaults: \(site)")
            check(settings.feed == ["instagram", "facebook"].contains(site), "Feed defaults: \(site)")
        }
        let controls = SharedState.supportedSites.flatMap { SiteBlockingControl.controls(for: $0) }
        check(controls.count == 11, "Every Safari setting has a control")
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
        for (site, feature) in [("youtube", SiteFeature.feed), ("tiktok", .shorts), ("unknown", .all)] {
            do {
                _ = try SharedStore.setToggle(site: site, feature: feature, enabled: true)
                preconditionFailure("Unsupported feature accepted")
            } catch SharedStoreError.invalidValue { }
        }
        print("Native Safari settings: defaults, migration, strict lock, independent toggles and persistence passed")
    }
}
