#if DEBUG && os(iOS)
import Foundation
import ManagedSettings

/// Explicitly armed by the isolated host diagnostic. Never used by Release.
/// Only the dedicated web store is changed by the website button.
enum WebsiteShieldProbe {
    static let storeName = ManagedSettingsStore.Name("Slowth.WebsiteProbe.Web")
    private static let selectionKey = "debug.managedSettings.webProbeTokens"
    private static let actionKey = "debug.managedSettings.webProbeAction"
    private static var appProbeActive: Bool {
        AppGroup.defaults.data(forKey: "debug.managedSettings.oneAppProbe") != nil
    }
    private static var tokens: Set<WebDomainToken> {
        guard let data = AppGroup.defaults.data(forKey: selectionKey),
              let tokens = try? JSONDecoder().decode(Set<WebDomainToken>.self, from: data) else { return [] }
        return tokens
    }

    static func arm(_ tokens: Set<WebDomainToken>) throws {
        guard appProbeActive, !tokens.isEmpty, tokens.count <= 50 else { throw IOSPauseError.unavailable }
        AppGroup.defaults.set(try JSONEncoder().encode(tokens), forKey: selectionKey)
        AppGroup.defaults.removeObject(forKey: actionKey)
        AppGroup.defaults.synchronize()
        ManagedSettingsStore(named: storeName).shield.webDomains = tokens
    }

    static func handles(_ token: WebDomainToken?) -> Bool {
        guard appProbeActive, let token else { return false }
        return tokens.contains(token)
    }

    static func releaseFromButton(_ token: WebDomainToken) -> Bool {
        guard handles(token) else { return false }
        let store = ManagedSettingsStore(named: storeName)
        let before = store.shield.webDomains ?? []
        let after = before.subtracting([token])
        store.shield.webDomains = after.isEmpty ? nil : after
        // Sanitized evidence that the action extension handled this tap.
        AppGroup.defaults.set([
            "at": ISO8601DateFormatter().string(from: Date()),
            "action": "releaseWebsiteOnly",
            "before": before.count,
            "after": after.count
        ], forKey: actionKey)
        AppGroup.defaults.synchronize()
        return true
    }

    static func clear() {
        ManagedSettingsStore(named: storeName).shield.webDomains = nil
        AppGroup.defaults.removeObject(forKey: selectionKey)
        AppGroup.defaults.synchronize()
    }

    static var report: [String: Any] {
        ["selectedDomains": tokens.count,
         "shieldedDomains": ManagedSettingsStore(named: storeName).shield.webDomains?.count ?? 0,
         "lastButton": AppGroup.defaults.dictionary(forKey: actionKey) as Any? ?? NSNull()]
    }
}
#endif
