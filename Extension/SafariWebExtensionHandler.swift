import SafariServices
import Foundation
import os.log

class SafariWebExtensionHandler: NSObject, NSExtensionRequestHandling {

    func beginRequest(with context: NSExtensionContext) {
        let request = context.inputItems.first as? NSExtensionItem
        let raw: Any?
        if #available(iOS 17.0, macOS 14.0, *) {
            raw = request?.userInfo?[SFExtensionMessageKey]
        } else {
            raw = request?.userInfo?["message"]
        }

        let response = NSExtensionItem()
        let payload = (raw as? [String: Any]) ?? [:]
        let result = handle(payload: payload)

        if #available(iOS 17.0, macOS 14.0, *) {
            response.userInfo = [SFExtensionMessageKey: result]
        } else {
            response.userInfo = ["message": result]
        }

        context.completeRequest(returningItems: [response], completionHandler: nil)
    }

    private func handle(payload: [String: Any]) -> [String: Any] {
        let action = (payload["action"] as? String) ?? ""

        switch action {
        case "getState":
            return ["ok": true, "state": stateDict()]

        case "setToggle":
            guard let site = payload["site"] as? String,
                  let value = payload["value"] as? String,
                  let mode = SiteMode(rawValue: value) else {
                return ["ok": false, "reason": "invalid_args"]
            }
            do {
                _ = try SharedStore.setToggle(site: site, mode: mode)
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

    private func stateDict() -> [String: Any] {
        let s = SharedStore.snapshot()
        let togglesRaw = s.toggles.mapValues { $0.rawValue }
        var dict: [String: Any] = [
            "toggles": togglesRaw,
            "strictModeUntil": s.strictModeUntil?.timeIntervalSince1970 ?? 0,
            "onboardingDone": s.onboardingDone,
            "rulesFetchedAt": s.rulesFetchedAt?.timeIntervalSince1970 ?? 0
        ]
        if let data = SharedStore.rulesJSON(), let str = String(data: data, encoding: .utf8) {
            dict["rules"] = str
        }
        if let etag = SharedStore.rulesEtag() {
            dict["rulesEtag"] = etag
        }
        return dict
    }
}
