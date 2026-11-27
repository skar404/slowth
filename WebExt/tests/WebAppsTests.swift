import Foundation

enum AppGroup {
    static let identifier = "test.web-apps.\(UUID().uuidString)"
    static let defaults = UserDefaults(suiteName: identifier)!
}

@main
struct WebAppsTests {
    @MainActor
    static func main() throws {
        defer { AppGroup.defaults.removePersistentDomain(forName: AppGroup.identifier) }
        for service in WebAppService.allCases {
            precondition(WebAppService(shortcut: URL(string: "slowth://web/" + service.id)!) == service)
            precondition(service.url.scheme == "https")
            precondition(service.shortcutURL.host == "slowth.app")
        }
        for value in ["https://web/instagram", "slowth://labeler/instagram", "slowth://web/reddit",
                      "slowth://web/instagram?url=https://evil.test", "slowth://web/instagram#x",
                      "slowth://user@web/instagram", "slowth://web:443/instagram", "slowth://web/instagram/",
                      "slowth://web//instagram", "slowth://web/%69nstagram", "slowth://web/../instagram",
                      "slowth://web/Instagram", "slowth://web/"] {
            precondition(WebAppService(shortcut: URL(string: value)!) == nil, "Accepted invalid route: \(value)")
        }
        precondition(WebAppService.x.url.absoluteString == "https://x.com/")
        precondition(Set(WebAppProfile.allCases.map(\.identifier)).count == 4)
        precondition(WebAppService.instagram.profile == WebAppService.facebook.profile)
        precondition(WebAppService.youtube.profile != WebAppService.tiktok.profile)
        for service in WebAppService.allCases {
            precondition(service.restorableURL(service.url) == service.url)
            precondition(service.restorableURL(service.url, method: "POST") == nil)
        }
        for value in ["https://www.youtube.com/login", "https://www.youtube.com/watch?v=secret", "https://www.youtube.com/#token", "https://accounts.google.com/", "http://www.youtube.com/", "https://youtube.com.evil.test/", "https://user:pass@youtube.com/", "https://youtube.com:1234/", "https://www.youtube.com/callback"] {
            precondition(WebAppService.youtube.restorableURL(URL(string: value)!) == nil)
        }
        precondition(WebAppService.containing(URL(string: "https://mobile.twitter.com/")!) == .x)
        let clickedURL = URL(string: "https://www.youtube.com/watch?v=123")!
        precondition(WebAppNavigationPolicy.loadsClickedLinkInApp(clickedURL, method: "GET", isLink: true, isMainOrNewWindow: true))
        precondition(!WebAppNavigationPolicy.loadsClickedLinkInApp(clickedURL, method: "POST", isLink: true, isMainOrNewWindow: true))
        precondition(!WebAppNavigationPolicy.loadsClickedLinkInApp(clickedURL, method: "GET", isLink: false, isMainOrNewWindow: true))
        precondition(!WebAppNavigationPolicy.loadsClickedLinkInApp(clickedURL, method: "GET", isLink: true, isMainOrNewWindow: false))
        let instagram = URL(string: "https://www.instagram.com/")!
        let appLink = URL(string: "https://l.instagram.com/?u=example")!
        precondition(WebAppNavigationPolicy.loadsCrossHostNavigationInApp(from: instagram, to: appLink, method: "GET"))
        precondition(!WebAppNavigationPolicy.loadsCrossHostNavigationInApp(from: instagram, to: instagram, method: "GET"))
        precondition(!WebAppNavigationPolicy.loadsCrossHostNavigationInApp(from: instagram, to: appLink, method: "POST"))
        precondition(!WebAppNavigationPolicy.loadsCrossHostNavigationInApp(from: instagram, to: URL(string: "instagram://app")!, method: "GET"))
        for scheme in ["file", "data", "javascript", "slowth", "webkit-extension", "youtube", "instagram", "fb", "tiktok", "twitter", "mailto", "tel", "itms-apps"] {
            precondition(!WebAppNavigationPolicy.loadsClickedLinkInApp(URL(string: scheme + ":test")!, method: "GET", isLink: true, isMainOrNewWindow: true))
        }
        let google = URL(string: "https://accounts.google.com/AccountChooser")!
        let challenge = URL(string: "https://accounts.google.com/signin/challenge")!
        precondition(!WebAppNavigationPolicy.opensTemporaryWindow(from: WebAppService.youtube.url, to: google, service: .youtube))
        precondition(!WebAppNavigationPolicy.opensTemporaryWindow(from: google, to: challenge, service: .youtube))
        precondition(!WebAppNavigationPolicy.opensTemporaryWindow(from: challenge, to: WebAppService.youtube.url, service: .youtube))
        precondition(WebAppNavigationPolicy.opensTemporaryWindow(from: WebAppService.youtube.url, to: URL(string: "https://example.com/article")!, service: .youtube))
        precondition(WebAppNavigationPolicy.opensTemporaryWindow(from: WebAppService.youtube.url, to: URL(string: "https://accounts.google.com.evil.test/")!, service: .youtube))
        func request(_ payload: [String: Any]) -> [String: Any] { NativeExtensionMessageHandler.handle(payload: payload) }
        precondition(request(["action": "getState"])["ok"] as? Bool == true)
        precondition(request(["action": "unknown"])["reason"] as? String == "unknown_action")
        precondition(request(["action": "setToggle", "site": "youtube"])["reason"] as? String == "invalid_args")
        precondition(request(["action": "setToggle", "site": "youtube", "feature": "feed", "enabled": true])["ok"] as? Bool == true)
        precondition(request(["action": "setToggle", "site": "youtube", "feature": "hideHomeFeed", "enabled": true])["ok"] as? Bool == true)
        let state = request(["action": "getState"])["state"] as! [String: Any]
        let toggles = state["toggles"] as! [String: [String: Bool]]
        precondition(toggles["youtube"]?["feed"] == true)
        precondition(toggles["youtube"]?["hideHomeFeed"] == true)
        precondition(request(["action": "setStrictMode", "enabled": true])["ok"] as? Bool == true)
        precondition(request(["action": "setToggle", "site": "youtube", "feature": "feed", "enabled": false])["reason"] as? String == "strict")
        precondition(SharedStore.snapshot().toggles["youtube"]?.feed == true)
        precondition(request(["action": "setToggle", "site": "youtube", "feature": "hideHomeFeed", "enabled": false])["reason"] as? String == "strict")
        precondition(SharedStore.snapshot().toggles["youtube"]?.hideHomeFeed == true)

        let router = WebAppsRouter()
        router.setPresentationReady(false)
        router.open(.youtube)
        precondition(router.service == nil && router.pending == .youtube)
        router.setPresentationReady(true)
        precondition(router.service == .youtube && router.pending == nil)
        router.open(.instagram)
        precondition(router.service == nil && router.pending == .instagram)
        router.open(.facebook) // The latest link wins while the old cover closes.
        router.didDismiss()
        precondition(router.service == .facebook && router.pending == nil)
        router.open(.facebook)
        precondition(router.service == .facebook && router.pending == nil)
        router.service = nil
        router.didDismiss()
        router.setShortcutInstructionsPresented(true)
        router.open(.x)
        precondition(router.service == nil && router.pending == .x)
        router.setPresentationReady(false)
        router.setShortcutInstructionsPresented(false)
        precondition(router.service == nil && router.pending == .x)
        router.setPresentationReady(true)
        precondition(router.service == .x && router.pending == nil)
        precondition(!router.openWebsite(URL(string: "https://evil.test/")!))
        precondition(router.openWebsite(URL(string: "https://www.youtube.com/watch?v=123")!))
        precondition(router.takeWebsiteURL(for: .instagram) == nil)
        precondition(router.takeWebsiteURL(for: .youtube)?.query == "v=123")
        precondition(router.takeWebsiteURL(for: .youtube) == nil)

        let handoff = WebAppsRouter()
        handoff.open(.instagram)
        handoff.dismissForNativePrompt()
        precondition(handoff.service == nil && handoff.isDismissing)
        // Clearing the cover binding is not a completed UIKit dismissal.
        handoff.open(.youtube)
        precondition(handoff.service == nil && handoff.pending == .youtube)
        handoff.dismissForNativePrompt() // A repeated Shield request wins.
        precondition(handoff.pending == nil && handoff.isDismissing)
        handoff.didDismiss()
        precondition(!handoff.isDismissing && handoff.service == nil)
        handoff.setPresentationReady(false) // Native popup now occupies the screen.
        precondition(handoff.openWebsite(URL(string: "https://www.tiktok.com/following")!))
        handoff.dismissForNativePrompt()
        precondition(!handoff.isDismissing && handoff.pending == nil && handoff.websiteURL == nil)
        handoff.setPresentationReady(true)
        precondition(handoff.service == nil, "A superseded website must not reopen after the popup")
        print("Web app routes, modal routing and shared native messaging: passed")
    }
}
