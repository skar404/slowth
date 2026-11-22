import Foundation

/// Stable IDs are storage identities. Never rotate them during an app update.
enum WebAppProfile: String, CaseIterable {
    case meta, youtube, tiktok, x

    var identifier: UUID {
        let suffix: String
        switch self {
        case .meta: suffix = "01"
        case .youtube: suffix = "02"
        case .tiktok: suffix = "03"
        case .x: suffix = "04"
        }
        return UUID(uuidString: "54C08251-2534-420A-9A92-9814DC8A00" + suffix)!
    }
    var title: String { self == .meta ? "Meta (Instagram + Facebook)" : rawValue.capitalized }
}

extension WebAppService {
    var profile: WebAppProfile {
        switch self {
        case .instagram, .facebook: return .meta
        case .youtube: return .youtube
        case .tiktok: return .tiktok
        case .x: return .x
        }
    }

    static func containing(_ url: URL) -> WebAppService? {
        guard let host = url.host?.lowercased() else { return nil }
        return allCases.first { service in
            let domains = service == .x ? ["x.com", "twitter.com"] : [service.rawValue + ".com"]
            return domains.contains { host == $0 || host.hasSuffix("." + $0) }
        }
    }

    /// Restore only ordinary same-service GET destinations. Never retain credentials,
    /// OAuth query parameters, fragments, login paths, POST bodies or temporary windows.
    func restorableURL(_ url: URL, method: String = "GET") -> URL? {
        guard method == "GET", url.scheme == "https", Self.containing(url) == self,
              let parts = URLComponents(url: url, resolvingAgainstBaseURL: false),
              parts.user == nil, parts.password == nil, parts.port == nil,
              parts.query == nil, parts.fragment == nil else { return nil }
        let path = url.path.lowercased()
        let sensitive = ["login", "signin", "sign-in", "logout", "auth", "oauth", "account", "checkpoint", "challenge", "consent", "verify", "password", "session", "callback", "flow"]
        guard !sensitive.contains(where: { path.contains($0) }) else { return nil }
        return url
    }
}

enum WebAppProtectionState: String { case starting, working, recovering, failed }

enum WebAppNavigationPolicy {
    /// Load clicked web links through WKWebView's public load API, rather than
    /// allowing WebKit to hand a Universal Link to an installed application.
    /// Do not replay forms/POST bodies or turn subframe loads into top-level pages.
    static func loadsClickedLinkInApp(_ url: URL, method: String, isLink: Bool, isMainOrNewWindow: Bool) -> Bool {
        isLink && isMainOrNewWindow && method == "GET"
            && ["http", "https"].contains(url.scheme?.lowercased() ?? "")
    }

    /// Script navigations and redirects can also trigger Universal Links when
    /// they leave the current host. Keep GET requests in the existing web view.
    static func loadsCrossHostNavigationInApp(from source: URL?, to destination: URL, method: String) -> Bool {
        method == "GET" && ["http", "https"].contains(destination.scheme?.lowercased() ?? "")
            && source?.host?.lowercased() != destination.host?.lowercased()
    }

    /// Once a redirect enters a login provider, keep its subsequent links and
    /// account choices in that browsing context (including its sessionStorage).
    /// Explicit provider sign-in links also stay in the current context. Popups
    /// still use WebKit's supplied configuration and retain window.opener.
    static func opensTemporaryWindow(from source: URL?, to destination: URL, service: WebAppService) -> Bool {
        guard let source, WebAppService.containing(source) == service,
              ["http", "https"].contains(destination.scheme ?? ""),
              WebAppService.containing(destination) != service else { return false }
        let host = destination.host?.lowercased() ?? ""
        let authenticationHosts = ["accounts.google.com", "accounts.youtube.com", "appleid.apple.com"]
        return !authenticationHosts.contains(host)
    }
}
