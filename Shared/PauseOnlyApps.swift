import Foundation

/// User-confirmed navigation only. Never used to select a Shield or grant access.
enum ShieldNavigationBindings {
    private static let key = "shield.navigationBindings.v1"
    private struct Entry: Codable {
        let token: Data
        let target: String
        let selection: Data
    }
    struct Choice {
        let token: Data
        let selections: [String: Data]
    }
    private static func entries(_ defaults: UserDefaults) -> [Entry] {
        guard let data = defaults.data(forKey: key),
              let entries = try? JSONDecoder().decode([Entry].self, from: data) else { return [] }
        return entries
    }
    static func target(for token: Data, selections: [String: Data], defaults: UserDefaults) -> String? {
        entries(defaults).first {
            $0.token == token && selections[$0.target] == $0.selection
        }?.target
    }
    static func confirm(_ choice: Choice, target: String, selections: [String: Data], defaults: UserDefaults) {
        guard let selection = choice.selections[target], selections[target] == selection else { return }
        var entries = entries(defaults).filter {
            $0.token != choice.token && selections[$0.target] == $0.selection
        }
        entries.append(Entry(token: choice.token, target: target, selection: selection))
        defaults.set(try? JSONEncoder().encode(Array(entries.suffix(32))), forKey: key)
        defaults.synchronize()
    }
    static func invalidate(_ target: String, defaults: UserDefaults) {
        defaults.set(try? JSONEncoder().encode(entries(defaults).filter { $0.target != target }), forKey: key)
        defaults.synchronize()
    }
}

#if os(iOS) && canImport(FamilyControls)
import Foundation
import FamilyControls
import ManagedSettings
#if DEBUG
import CryptoKit
#endif

/// Whole-app protection independent of the recording/classifier settings.
/// Selection data stays native-only; Safari's settings contract is unchanged.
enum PauseOnlyApps {
    static let targets = ["tiktok", "snapchat"]
    static func contains(_ target: String) -> Bool { targets.contains(target) }
    /// Refresh at extension entry points, before resolving a newly configured app.
    static func refreshSelections() {
        AppGroup.defaults.synchronize()
    }

    static func target(containing token: ApplicationToken) -> String? {
        targets.first { selection($0)?.applicationTokens.contains(token) == true }
    }

    /// The enforcing store can retain the system's current representation even
    /// when a token delivered to a shield differs from the persisted picker token.
    /// Ambiguous matches must not guess which app the user opened.
    static func systemTarget(containing token: ApplicationToken) -> String? {
        let services = ["youtube", "instagram", "facebook", "x"] + targets
        let matches = services.filter {
            ManagedSettingsStore(named: .init("RealtimeShield." + $0))
                .shield.applications?.contains(token) == true
        }
        return matches.count == 1 ? matches[0] : nil
    }

    static func data(_ target: String) -> Data? {
        guard contains(target) else { return nil }
        return AppGroup.defaults.data(forKey: "pauseOnly.\(target).selection")
    }
    static func selection(_ target: String) -> FamilyActivitySelection? {
        guard let data = data(target),
              let selection = try? JSONDecoder().decode(FamilyActivitySelection.self, from: data),
              selection.applicationTokens.count == 1,
              selection.categoryTokens.isEmpty, selection.webDomainTokens.isEmpty else { return nil }
        return selection
    }
    /// Bounded, local-only routing diagnostics for physical-device Debug builds.
    /// Store token fingerprints, never tokens or screen content.
    static func recordRouting(_ stage: String, token: ApplicationToken? = nil,
                              target: String? = nil, appName: String? = nil, source: String? = nil) {
        #if DEBUG
        func fingerprint(_ token: ApplicationToken) -> String {
            guard let data = try? JSONEncoder().encode(token) else { return "unencodable" }
            return SHA256.hash(data: data).prefix(6).map { String(format: "%02x", $0) }.joined()
        }
        let defaults = AppGroup.defaults
        let key = "debug.pauseOnlyRouting." + (Bundle.main.bundleIdentifier ?? "unknown")
        var events = defaults.array(forKey: key) as? [[String: Any]] ?? []
        var event: [String: Any] = ["at": Date().timeIntervalSince1970,
                                    "stage": stage, "target": target ?? "unmatched"]
        event["callback"] = token.map(fingerprint) ?? "none"
        let name = appName?.lowercased() ?? ""
        event["knownApp"] = name.contains("snapchat") ? "snapchat" : name.contains("tiktok") ? "tiktok" : "other-or-unavailable"
        event["hasName"] = appName != nil
        event["source"] = source ?? "token"
        for service in targets {
            event[service] = selection(service)?.applicationTokens.map(fingerprint).sorted() ?? []
        }
        for service in ["youtube", "instagram", "facebook", "x"] + targets {
            event["system." + service] = ManagedSettingsStore(named: .init("RealtimeShield." + service))
                .shield.applications?.map(fingerprint).sorted() ?? []
        }
        events.append(event)
        defaults.set(Array(events.suffix(12)), forKey: key)
        defaults.synchronize()
        #endif
    }

    static func save(_ selection: FamilyActivitySelection, target: String) throws {
        guard contains(target) else { throw SharedStoreError.invalidValue }
        let empty = selection.applicationTokens.isEmpty && selection.categoryTokens.isEmpty && selection.webDomainTokens.isEmpty
        guard empty || (selection.applicationTokens.count == 1 && selection.categoryTokens.isEmpty && selection.webDomainTokens.isEmpty) else {
            throw SharedStoreError.invalidValue
        }
        if SharedStore.snapshot().isStrictModeActive && (empty || self.selection(target) != nil) {
            throw SharedStoreError.strictModeActive
        }
        let key = "pauseOnly.\(target).selection"
        let defaults = AppGroup.defaults
        if empty { defaults.removeObject(forKey: key) }
        else { defaults.set(try JSONEncoder().encode(selection), forKey: key) }
        // Publish before ManagedSettings can invoke either shield extension.
        defaults.synchronize()
        recordRouting("saved", target: target)
    }
}
#endif

#if (os(iOS) && canImport(FamilyControls)) || GROUPED_APPS_TESTS
/// MVP: a single opaque application set owns one pause and one detection rest.
/// Legacy selections remain stored for rollback, but do not enforce after opt-in.
enum GroupedApps {
    static let settingsKey = "groupedApps.settings.v2"
    static let softSessionKey = "groupedApps.softSession.v2"
    static var configuration: AppBlockingConfiguration<ApplicationToken>? {
        guard let data = AppGroup.defaults.data(forKey: settingsKey),
              let value = try? JSONDecoder().decode(AppBlockingConfiguration<ApplicationToken>.self, from: data),
              value.version == 2 else { return nil }
        return value
    }
    static var usesAppSettings: Bool { configuration != nil }
    static func settings(for token: ApplicationToken) -> AppBlockingSettings<ApplicationToken> {
        configuration?.settings(for: token) ?? .init(token: token,
            shortVideos: legacyContentRules.shortVideos && !exception(for: token).allowShortVideos,
            stories: legacyContentRules.stories && !exception(for: token).allowStories,
            soft: softSelection?.applicationTokens.contains(token) == true)
    }
    /// Called only under the coordinator lock, before changing the selected tokens.
    static func migrateSettings() throws {
        if let data = AppGroup.defaults.data(forKey: settingsKey) {
            let existing = try JSONDecoder().decode(AppBlockingConfiguration<ApplicationToken>.self, from: data)
            guard existing.version == 2 else { throw SharedStoreError.invalidValue }
            return
        }
        let value = AppBlockingConfiguration.migrate(tokens: savedSelection?.applicationTokens ?? [],
            rules: legacyContentRules, exceptions: exceptions, softTokens: softSelection?.applicationTokens ?? [])
        try saveConfiguration(value)
    }
    private static func saveConfiguration(_ value: AppBlockingConfiguration<ApplicationToken>) throws {
        AppGroup.defaults.set(try JSONEncoder().encode(value), forKey: settingsKey)
        AppGroup.defaults.synchronize()
    }
    static func setSettings(_ settings: AppBlockingSettings<ApplicationToken>) throws {
        guard selection?.applicationTokens.contains(settings.token) == true else { throw SharedStoreError.invalidValue }
        try migrateSettings()
        guard var value = configuration else { throw SharedStoreError.invalidValue }
        if SharedStore.snapshot().isStrictModeActive && settings.weakens(value.settings(for: settings.token)) {
            throw SharedStoreError.strictModeActive
        }
        value.set(settings)
        try saveConfiguration(value)
    }
    static var softTokens: Set<ApplicationToken> {
        Set((selection?.applicationTokens ?? []).filter { settings(for: $0).soft })
    }
    static var softSession: GroupedSoftSession<ApplicationToken>? {
        get {
            AppGroup.defaults.data(forKey: softSessionKey).flatMap {
                try? JSONDecoder().decode(GroupedSoftSession<ApplicationToken>.self, from: $0)
            }
        }
        set {
            AppGroup.defaults.set(newValue.flatMap { try? JSONEncoder().encode($0) }, forKey: softSessionKey)
            AppGroup.defaults.synchronize()
        }
    }
    static var contentRules: GroupedContentRules {
        guard let value = configuration else { return legacyContentRules }
        let settings = (selection?.applicationTokens ?? []).map { value.settings(for: $0) }
        return .init(shortVideos: settings.contains { $0.shortVideos }, stories: settings.contains { $0.stories })
    }
    private static var legacyContentRules: GroupedContentRules {
        GroupedContentRules(
            shortVideos: AppGroup.defaults.object(forKey: "groupedApps.shortVideos.v1") as? Bool ?? true,
            stories: AppGroup.defaults.object(forKey: "groupedApps.stories.v1") as? Bool ?? true)
    }
    static func contentRuleKey(_ kind: GroupedContentRules.Kind) -> String {
        kind == .shortVideos ? "groupedApps.shortVideos.v1" : "groupedApps.stories.v1"
    }
    static func setContentBlocking(_ kind: GroupedContentRules.Kind, enabled: Bool) throws {
        let state = SharedStore.snapshot()
        if state.isStrictModeActive && !enabled { throw SharedStoreError.strictModeActive }
        let key = contentRuleKey(kind)
        AppGroup.defaults.set(enabled, forKey: key)
        AppGroup.defaults.synchronize()
    }
    static let exceptionsKey = "groupedApps.exceptions.v1"
    static var exceptions: [GroupedContentException<ApplicationToken>] {
        guard let data = AppGroup.defaults.data(forKey: exceptionsKey),
              let rules = try? JSONDecoder().decode([GroupedContentException<ApplicationToken>].self, from: data) else { return [] }
        return rules
    }
    static func exception(for token: ApplicationToken) -> GroupedContentException<ApplicationToken> {
        exceptions.first { $0.token == token } ?? .init(token: token)
    }
    static func setException(_ rule: GroupedContentException<ApplicationToken>) throws {
        let state = SharedStore.snapshot()
        guard selection?.applicationTokens.contains(rule.token) == true else { throw SharedStoreError.invalidValue }
        let old = exception(for: rule.token)
        if state.isStrictModeActive && ((!old.allowShortVideos && rule.allowShortVideos) || (!old.allowStories && rule.allowStories)) {
            throw SharedStoreError.strictModeActive
        }
        var rules = exceptions.filter { $0.token != rule.token && selection?.applicationTokens.contains($0.token) == true }
        if rule.isException { rules.append(rule) }
        AppGroup.defaults.set(try JSONEncoder().encode(rules), forKey: exceptionsKey)
        AppGroup.defaults.synchronize()
    }
    static func blockedSelection(for kinds: Set<GroupedContentRules.Kind>) -> FamilyActivitySelection? {
        guard var selected = selection else { return nil }
        if let value = configuration {
            selected.applicationTokens = selected.applicationTokens.filter {
                let rule = value.settings(for: $0)
                return (rule.shortVideos && kinds.contains(.shortVideos)) || (rule.stories && kinds.contains(.stories))
            }
        } else {
            selected.applicationTokens = contentRules.blockedTokens(from: selected.applicationTokens, kinds: kinds, exceptions: exceptions)
        }
        return selected.applicationTokens.isEmpty ? nil : selected
    }
    static let key = "groupedApps.selection.v1"
    static var isEnabled: Bool { AppGroup.defaults.bool(forKey: "groupedApps.enabled.v1") }
    static var data: Data? { AppGroup.defaults.data(forKey: key) }
    static var selection: FamilyActivitySelection? {
        guard let value = savedSelection,
              BlockingRules.supportsApplicationCount(value.applicationTokens.count) else { return nil }
        return value
    }
    // Preserve older oversized lists for correction in the picker, but never
    // report them as a working protection configuration or silently truncate.
    private static var savedSelection: FamilyActivitySelection? {
        guard let data, let value = try? JSONDecoder().decode(FamilyActivitySelection.self, from: data),
              !value.applicationTokens.isEmpty, value.categoryTokens.isEmpty, value.webDomainTokens.isEmpty else { return nil }
        return value
    }
    // Categories are expanded by the system picker; persist a snapshot of apps only.
    static var pickerSelection: FamilyActivitySelection {
        var value = FamilyActivitySelection(includeEntireCategory: true)
        value.applicationTokens = savedSelection?.applicationTokens ?? []
        return value
    }
    static var orderedTokens: [ApplicationToken] {
        Array(savedSelection?.applicationTokens ?? []).sorted {
            (try? JSONEncoder().encode($0).base64EncodedString()) ?? "" < (try? JSONEncoder().encode($1).base64EncodedString()) ?? ""
        }
    }
    static var softSelection: FamilyActivitySelection? {
        let state = SharedStore.snapshot()
        guard state.softYouTubeBlockingEnabled,
              let data = state.youtubeSelectionData,
              let value = try? JSONDecoder().decode(FamilyActivitySelection.self, from: data),
              value.applicationTokens.count == 1,
              value.applicationTokens.isSubset(of: selection?.applicationTokens ?? []) else { return nil }
        return value
    }
    static func rememberReturn(token: ApplicationToken?, name: String?) {
        guard let token, let data = try? JSONEncoder().encode(token), let name else { return }
        let names = ["youtube": "youtube", "instagram": "instagram", "facebook": "facebook", "x": "x", "twitter": "x"]
        guard let target = names[name.lowercased()] else { return }
        var links = AppGroup.defaults.dictionary(forKey: "groupedApps.returnLinks") as? [String: String] ?? [:]
        links[data.base64EncodedString()] = target
        AppGroup.defaults.set(links, forKey: "groupedApps.returnLinks")
    }
    static func prepareReturn(token: ApplicationToken) {
        AppGroup.defaults.synchronize()
        let data = try? JSONEncoder().encode(token)
        let links = AppGroup.defaults.dictionary(forKey: "groupedApps.returnLinks") as? [String: String] ?? [:]
        let target = data.flatMap { links[$0.base64EncodedString()] }
        AppGroup.defaults.set(target, forKey: "groupedApps.returnTarget")
        AppGroup.defaults.synchronize()
    }
    static var returnTarget: String? { AppGroup.defaults.string(forKey: "groupedApps.returnTarget") }
}
#endif
