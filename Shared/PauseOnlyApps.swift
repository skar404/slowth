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
                              target: String? = nil, appName: String? = nil) {
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
