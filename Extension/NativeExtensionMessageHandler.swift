import Foundation

/// One message contract for Safari and the in-app WebKit extension.
enum NativeExtensionMessageHandler {
    static func handle(payload: [String: Any]) -> [String: Any] {
        let action = (payload["action"] as? String) ?? ""

        #if os(iOS)
        if action == "activatePause" || action == "cancelPausePreparation" {
            do {
                guard let id = payload["id"] as? String else { return ["ok": false] }
                if action == "activatePause" { try IOSPauseCoordinator.acknowledgeSafari(id) }
                else { try IOSPauseCoordinator.cancelSafariPreparation(id) }
                return ["ok": true, "state": stateDict()]
            } catch { return ["ok": false, "reason": String(describing: error)] }
        }
        #endif

        switch action {
        case "getState":
            return ["ok": true, "state": stateDict()]

        case "setToggle":
            guard let site = payload["site"] as? String,
                  let key = payload["feature"] as? String,
                  let feature = SiteFeature(rawValue: key),
                  let enabled = payload["enabled"] as? Bool else {
                return ["ok": false, "reason": "invalid_args"]
            }
            do {
                _ = try SharedStore.setToggle(site: site, feature: feature, enabled: enabled)
                return ["ok": true, "state": stateDict()]
            } catch SharedStoreError.strictModeActive {
                return ["ok": false, "reason": "strict", "state": stateDict()]
            } catch {
                return ["ok": false, "reason": "unknown"]
            }

        case "setStrictMode":
            guard let enabled = payload["enabled"] as? Bool else {
                return ["ok": false, "reason": "invalid_args"]
            }
            do {
                _ = try SharedStore.setStrictMode(enabled)
                return ["ok": true, "state": stateDict()]
            } catch SharedStoreError.strictModeActive {
                return ["ok": false, "reason": "strict", "state": stateDict()]
            } catch {
                return ["ok": false, "reason": "unknown"]
            }

        case "saveRules":
            guard let rulesString = payload["rules"] as? String,
                  let data = rulesString.data(using: .utf8) else {
                return ["ok": false, "reason": "invalid_args"]
            }
            let etag = payload["etag"] as? String
            do {
                try SharedStore.saveRules(json: data, etag: etag)
                return ["ok": true, "state": stateDict()]
            } catch SharedStoreError.strictModeActive {
                return ["ok": false, "reason": "strict"]
            } catch {
                return ["ok": false, "reason": "unknown"]
            }

        case "rulesAttempt":
            SharedStore.setRulesLastAttemptAt(Date())
            return ["ok": true]

        case "setOnboardingDone":
            SharedStore.setOnboardingDone((payload["value"] as? Bool) ?? true)
            return ["ok": true]

        default:
            return ["ok": false, "reason": "unknown_action"]
        }
    }

    private static func stateDict() -> [String: Any] {
        let s = SharedStore.snapshot()
        let togglesRaw = s.toggles.mapValues { $0.dictionary }
        var dict: [String: Any] = [
            "toggles": togglesRaw,
            "settingsVersion": 2,
            "strictModeUntil": s.strictModeUntil?.timeIntervalSince1970 ?? 0,
            "strictModeStartedAt": s.strictModeStartedAt?.timeIntervalSince1970 ?? 0,
            "onboardingDone": s.onboardingDone,
            "rulesFetchedAt": s.rulesFetchedAt?.timeIntervalSince1970 ?? 0
        ]
        if let data = SharedStore.rulesJSON(), let str = String(data: data, encoding: .utf8) {
            dict["rules"] = str
        }
        if let etag = SharedStore.rulesEtag() {
            dict["rulesEtag"] = etag
        }
        #if os(iOS)
        dict["pause"] = IOSPauseCoordinator.safariState() ?? [:]
        #endif
        return dict
    }
}
