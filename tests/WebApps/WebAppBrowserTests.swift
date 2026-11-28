import XCTest
import WebKit
import Network
import SwiftUI
@testable import Unscroll

@MainActor
final class WebAppBrowserTests: XCTestCase {
    override func setUpWithError() throws {
        try super.setUpWithError()
        XCTAssertTrue(ProcessInfo.processInfo.arguments.contains("--web-app-tests"),
                      "Use the isolated Web apps tests host, without production UI startup")
    }

    override func tearDown() async throws {
        // Each test owns its extension processes and pages. Retained profiles
        // otherwise accumulate WebKit processes across unrelated test cases.
        for profile in WebAppProfile.allCases {
            WebAppProfileRuntime.shared(profile).prepareRecovery()
        }
        try await super.tearDown()
    }

    func testShieldRequestReplacesBrowserCoverWithNativePromptAndCanReturnToBrowser() async throws {
        let router = WebAppsRouter.shared
        let window = try XCTUnwrap(UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }
            .flatMap(\.windows).first { $0.isKeyWindow })
        let previousRoot = window.rootViewController
        let welcome = UserDefaults.standard.object(forKey: "iosWelcomeV1Handled")
        UserDefaults.standard.set(true, forKey: "iosWelcomeV1Handled")
        router.dismissForNativePrompt()
        router.didDismiss()
        router.setPresentationReady(true)
        let host = UIHostingController(rootView: ShieldHandoffTestRoot())
        window.rootViewController = host
        defer {
            host.dismiss(animated: false)
            window.rootViewController = previousRoot
            UserDefaults.standard.set(welcome, forKey: "iosWelcomeV1Handled")
            _ = SharedStore.consumeRealtimeRecordingPromptRequest()
            router.dismissForNativePrompt()
            router.didDismiss()
            router.setPresentationReady(true)
        }
        func waitUntil(_ condition: () -> Bool) async throws {
            for _ in 0..<100 {
                if condition() { return }
                try await Task.sleep(for: .milliseconds(100))
            }
            XCTFail("Native/browser presentation did not complete")
            throw URLError(.timedOut)
        }
        router.open(.instagram)
        try await waitUntil { host.presentedViewController != nil }
        let browserCover = try XCTUnwrap(host.presentedViewController)
        SharedStore.requestRealtimeRecordingPrompt(target: "apps")
        // Exercise ContentView's actual polling/consumption and SwiftUI dismissal.
        try await waitUntil {
            router.service == nil && !router.isDismissing && host.presentedViewController != nil &&
                host.presentedViewController !== browserCover
        }
        XCTAssertNil(router.pending)
        let prompt = try XCTUnwrap(host.presentedViewController)
        router.open(.youtube)
        try await waitUntil {
            router.service == .youtube && host.presentedViewController != nil &&
                host.presentedViewController !== prompt
        }
    }

    func testShieldDestinationsStayQueuedUntilBrowserDismissalCompletes() {
        for target in ["youtube", "tiktok", "instagram"] {
            let router = WebAppsRouter()
            var prompt = IOSShieldPromptPresentation()
            router.open(.instagram)
            XCTAssertTrue(prompt.receive(isActive: true) { $0 = target; return true })
            router.dismissForNativePrompt()
            let rest = IOSDetectionRest(target: "instagram", started: IOSPauseClock(wall: 1000, continuous: 500, boot: "test"))
            func take() -> IOSShieldPromptPresentation.Destination? {
                prompt.take(isActive: true, isIdle: !router.isDismissing, rests: [rest], isPauseOnly: { $0 == "tiktok" })
            }
            XCTAssertNil(take())
            XCTAssertTrue(prompt.isPending)
            router.didDismiss()
            switch (target, take()) {
            case ("youtube", .recording("youtube")), ("tiktok", .pause("tiktok")): break
            case ("instagram", .rest(let shown)):
                XCTAssertEqual(shown.id, rest.id)
                XCTAssertEqual(shown.started?.continuous, 500, "The handoff must not restart the rest")
            default: XCTFail("Lost Shield destination: \(target)")
            }
            XCTAssertNil(take())
        }
    }

    func testInstagramBottomNavigationHasEqualSpacingAfterHidingReels() async throws {
        let extensionURL = try XCTUnwrap(Bundle.main.builtInPlugInsURL)
            .appendingPathComponent("UnscrollExtension.appex")
        let configuration = WKWebViewConfiguration()
        var scripts = ["""
        window.testFlags = {shorts:true, feed:false, all:false, stories:false};
        window.browser = {runtime:{
          sendMessage: (_, callback) => callback({toggles:{instagram:window.testFlags}}),
          onMessage:{addListener: callback => window.updateTestSettings = callback},
          getURL: file => 'https://example.com/' + file
        }};
        """]
        for file in ["config.js", "pause-policy.js", "i18n.js", "content/common.js", "content/instagram.js"] {
            scripts.append(file == "i18n.js" ? "Unscroll.i18n = {t:key=>key, setLocale:()=>{}}" :
                try String(contentsOf: extensionURL.appendingPathComponent(file), encoding: .utf8))
        }
        scripts.append("""
        window.equallySpaced = count => {
          const icons = [...document.querySelectorAll('#nav svg')].map(n => n.getBoundingClientRect()).filter(r => r.width);
          if (icons.length !== count) return false;
          const centers = icons.map(r => r.x + r.width / 2).sort((a,b) => a-b);
          const step = document.getElementById('nav').clientWidth / count;
          return centers.every((x,i) => Math.abs(x - step * (i + 0.5)) < 1);
        };
        """)
        configuration.userContentController.addUserScript(WKUserScript(
            source: scripts.joined(separator: ";\n"), injectionTime: .atDocumentEnd, forMainFrameOnly: true))
        let view = WKWebView(frame: CGRect(x: 0, y: 0, width: 400, height: 800), configuration: configuration)
        let window = try XCTUnwrap(UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }
            .flatMap(\.windows).first { $0.isKeyWindow })
        window.addSubview(view)
        defer { view.removeFromSuperview(); view.stopLoading() }
        let items = ["/", "/explore/", "/reels/", "/direct/inbox/", "/person/"]
            .enumerated().map { index, href in
                "<div style='width:\(45 + index * 13)px;margin-left:\(index * 3)px'><a href='\(href)'><svg width='24' height='24'><circle cx='12' cy='12' r='10'/></svg></a></div>"
            }.joined()
        let markup = """
        <html><head><meta name="viewport" content="width=device-width,initial-scale=1">
        <style>body{margin:0}#nav{position:fixed;bottom:0;width:100%;height:60px;display:flex;justify-content:space-between}a{display:inline-block}</style>
        </head><body><header><a href="/">Home</a></header><section id="post">Post actions</section>
        <div id="nav">\(items)</div></body></html>
        """
        let server = try DownloadFixture(stalled: false, html: true, document: markup)
        defer { server.stop() }
        let origin = try await server.url()
        view.load(URLRequest(url: try XCTUnwrap(URL(string: "/", relativeTo: origin)?.absoluteURL)))
        func expect(_ expression: String, file: StaticString = #filePath, line: UInt = #line) async throws {
            for _ in 0..<50 {
                if (try? await view.evaluateJavaScript(expression)) as? Bool == true { return }
                try await Task.sleep(for: .milliseconds(100))
            }
            XCTFail(expression, file: file, line: line)
            throw URLError(.cannotParseResponse)
        }
        try await expect("equallySpaced(4)")
        try await expect("!document.querySelector('header [data-unscroll-instagram-nav-slot]') && !document.getElementById('post').hasAttribute('data-unscroll-instagram-nav-row')")
        _ = try await view.evaluateJavaScript("testFlags.shorts = false; updateTestSettings({type:'unscroll-state-updated'}); true")
        try await expect("equallySpaced(5)")
        _ = try await view.evaluateJavaScript("document.documentElement.dir = 'rtl'; true")
        try await expect("equallySpaced(5)")
        _ = try await view.evaluateJavaScript("document.getElementById('nav').innerHTML = [...document.querySelectorAll('#nav a')].map(a => a.outerHTML).join(''); true")
        try await expect("equallySpaced(5)")
        _ = try await view.evaluateJavaScript("document.getElementById('nav').style.cssText = 'width:64px;height:100%;top:0;left:0'; true")
        try await expect("!document.getElementById('nav').hasAttribute('data-unscroll-instagram-nav-row') && !document.querySelector('[data-unscroll-instagram-nav-slot]')")
    }

    func testAddressCopiesFullCurrentURLAfterSPANavigationAndTabSwitches() async throws {
        let browser = WebAppProfileRuntime.shared(.tiktok).session(.tiktok)
        browser.stop()
        defer { browser.stop() }
        let pasteboard = UIPasteboard.withUniqueName()
        defer { UIPasteboard.remove(withName: pasteboard.name) }
        let server = try DownloadFixture(stalled: false, html: true)
        defer { server.stop() }
        let url = try await server.url()
        let main = browser.addTab(configuration: browser.websiteConfiguration())
        XCTAssertNil(browser.copyableURL)
        main.view.load(URLRequest(url: url))
        try await waitForBrowserPage(main.view, url: url)
        browser.copyCurrentLink(to: pasteboard)
        XCTAssertEqual(pasteboard.url, url)

        _ = try await main.view.evaluateJavaScript("history.pushState({}, '', '/post?id=123#reply'); true")
        let post = try XCTUnwrap(URL(string: "/post?id=123#reply", relativeTo: url)?.absoluteURL)
        try await waitForBrowserPage(main.view, url: post)
        browser.copyCurrentLink(to: pasteboard)
        XCTAssertEqual(pasteboard.url, post, "Copy the current path, query and fragment, not just the host")

        let popup = browser.addTab(configuration: browser.websiteConfiguration())
        browser.copyCurrentLink(to: pasteboard)
        XCTAssertEqual(pasteboard.url, post, "An empty tab must not replace the clipboard with a made-up URL")
        popup.view.load(URLRequest(url: url))
        try await waitForBrowserPage(popup.view, url: url)
        browser.copyCurrentLink(to: pasteboard)
        XCTAssertEqual(pasteboard.url, url)
        browser.select(main)
        browser.copyCurrentLink(to: pasteboard)
        XCTAssertEqual(pasteboard.url, post)
    }

    func testPullToRefreshReloadsTheActivePageAndEndsOnFailureOrTabSwitch() async throws {
        let browser = WebAppProfileRuntime.shared(.tiktok).session(.tiktok)
        browser.stop()
        defer { browser.stop() }
        let server = try DownloadFixture(stalled: false, html: true,
            document: "<html><script>window.pageInstance = Math.random().toString()</script><body>Short page</body></html>")
        defer { server.stop() }
        let url = try await server.url()
        let main = browser.addTab(configuration: browser.websiteConfiguration())
        main.view.load(URLRequest(url: url))
        try await waitForBrowserPage(main.view, url: url)
        let instance = try await main.view.evaluateJavaScript("window.pageInstance")
        let initial = try XCTUnwrap(instance as? String)
        let refresh = try XCTUnwrap(main.view.scrollView.refreshControl)
        XCTAssertTrue(main.view.scrollView.alwaysBounceVertical, "Short pages also support pulling down")
        refresh.beginRefreshing()
        refresh.sendActions(for: .valueChanged)
        var reloaded = false
        for _ in 0..<50 {
            if !main.view.isLoading,
               let current = (try? await main.view.evaluateJavaScript("window.pageInstance")) as? String,
               current != initial { reloaded = true; break }
            try await Task.sleep(for: .milliseconds(100))
        }
        XCTAssertTrue(reloaded, "The refresh control must perform a real page reload")
        XCTAssertFalse(refresh.isRefreshing)
        XCTAssertEqual(main.view.url, url)
        for error in [URLError(.notConnectedToInternet), URLError(.cancelled)] {
            refresh.beginRefreshing()
            browser.webView(main.view, didFailProvisionalNavigation: nil, withError: error)
            XCTAssertFalse(refresh.isRefreshing)
        }
        refresh.beginRefreshing()
        let popup = browser.addTab(configuration: browser.websiteConfiguration())
        XCTAssertFalse(refresh.isRefreshing, "Switching tabs must not leave the old spinner running")
        XCTAssertNotNil(popup.view.scrollView.refreshControl)
        refresh.beginRefreshing()
        refresh.sendActions(for: .valueChanged)
        XCTAssertFalse(refresh.isRefreshing, "A stale control must not reload the newly selected tab")
        XCTAssertNil(popup.view.url)
    }

    private func waitForBrowserPage(_ view: WKWebView, url: URL) async throws {
        for _ in 0..<50 {
            if view.url == url && !view.isLoading,
               (try? await view.evaluateJavaScript("document.readyState")) as? String == "complete" { return }
            try await Task.sleep(for: .milliseconds(100))
        }
        XCTFail("Page did not finish loading: \(url)")
        throw URLError(.timedOut)
    }

    func testFeedFiltersInWebKit() async throws {
        let bundle = try XCTUnwrap(Bundle.main.builtInPlugInsURL).appendingPathComponent("UnscrollExtension.appex")
        let script = try String(contentsOf: bundle.appendingPathComponent("content/feed-filters.js"), encoding: .utf8)
        let config = WKWebViewConfiguration()
        config.userContentController.addUserScript(WKUserScript(source: """
        window.Unscroll = {};
        window.browser = {runtime: {sendMessage: (_, cb) => cb(false)}};
        \(script)
        """, injectionTime: .atDocumentStart, forMainFrameOnly: true))
        let view = WKWebView(frame: CGRect(x: 0, y: 0, width: 400, height: 800), configuration: config)
        let window = try XCTUnwrap(UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }
            .flatMap(\.windows).first { $0.isKeyWindow })
        window.addSubview(view)
        defer { view.removeFromSuperview(); view.stopLoading() }
        let server = try DownloadFixture(stalled: false, html: true, document: "<html><body></body></html>")
        defer { server.stop() }
        let url = try await server.url()
        view.load(URLRequest(url: url))
        try await waitForBrowserPage(view, url: url)

        func verify(_ site: String, route: String, markup: String, flags: [String: Bool],
                    enabled: String, disabled: String) async throws {
            // Run checks in the rendered document, including hide/restore on the same page.
            let result = try await view.callAsyncJavaScript("""
            history.replaceState(null, '', route);
            document.body.innerHTML = markup;
            const search = document.querySelector('reddit-search-large');
            if (search) search.attachShadow({mode:'open'}).innerHTML =
              '<p id="recent">Recent</p><p id="section_2_trending_query">Trending</p><div id="trend1">A</div><div id="trend2">B</div><p id="section_results">Results</p>';
            const searchVisible = id => getComputedStyle(search.shadowRoot.getElementById(id)).display !== 'none';
            const apply = Unscroll.feedFilters.install(site);
            const visible = id => getComputedStyle(document.getElementById(id)).display !== 'none';
            const paint = () => new Promise(resolve => requestAnimationFrame(() => requestAnimationFrame(resolve)));
            apply(flags);
            await paint();
            const active = eval(enabled);
            apply({});
            await paint();
            return [active, eval(disabled)];
            """, arguments: ["site": site, "route": route, "markup": markup, "flags": flags,
                             "enabled": enabled, "disabled": disabled], in: nil, contentWorld: .page)
            XCTAssertEqual(result as? [Bool], [true, true], site)
        }
        try await verify("youtube", route: "/watch?v=example", markup: """
            <button onclick="this.firstChild.setAttribute('aria-checked','false')"><span id="auto" class="ytp-autonav-toggle-button" aria-checked="true"></span></button>
            <ytd-watch-next-secondary-results-renderer id="related">Videos</ytd-watch-next-secondary-results-renderer>
            <div id="end" class="ytp-endscreen-content"></div><div id="queue">Playlist</div><div id="chat">Chat</div>
            """, flags: ["autoplayOff": true, "hideRelated": true],
            enabled: "!visible('related') && !visible('end') && visible('queue') && visible('chat') && document.getElementById('auto').getAttribute('aria-checked') === 'false'",
            disabled: "visible('related') && visible('end')")
        try await verify("instagram", route: "/", markup: """
            <main><aside id="suggest"><a href="/explore/people">People</a></aside><article id="post">Post</article></main>
            """, flags: ["hideSuggestions": true], enabled: "!visible('suggest') && visible('post')", disabled: "visible('suggest')")
        try await verify("tiktok", route: "/following", markup: """
            <div id="top-right-action-bar"><a id="buy" href="/coin">Coins</a><button id="me">Account</button></div>
            """, flags: ["hideUpsells": true], enabled: "!visible('buy') && visible('me')", disabled: "visible('buy')")
        try await verify("x", route: "/home", markup: """
            <main><div role="tablist"><button role="tab" aria-selected="true">Для вас</button><button id="follow" role="tab" onclick="this.setAttribute('aria-selected','true');this.previousSibling.setAttribute('aria-selected','false')">Подписки</button><button role="tab" id="list">List</button></div></main>
            <div data-testid="sidebarColumn"><span id="account" data-testid="UserCell">Suggested</span><input id="search"></div>
            """, flags: ["following": true, "hideSuggestions": true],
            enabled: "document.getElementById('follow').getAttribute('aria-selected') === 'true' && !visible('account') && visible('search') && visible('list')",
            disabled: "visible('account')")
        try await verify("reddit", route: "/", markup: """
            <shreddit-feed-tabs><button data-feed-token="for-you" faceplate-tab-selected></button><button data-feed-token="following" id="follow" onclick="this.setAttribute('faceplate-tab-selected','');this.previousSibling.removeAttribute('faceplate-tab-selected')"></button></shreddit-feed-tabs>
            <reddit-search-large></reddit-search-large><shreddit-ad-post id="ad"></shreddit-ad-post><games-section-badge-wrapper id="games"></games-section-badge-wrapper><shreddit-post id="post"></shreddit-post>
            """, flags: ["following": true, "hidePromoted": true, "hideRecommendations": true],
            enabled: "document.getElementById('follow').hasAttribute('faceplate-tab-selected') && !visible('ad') && !visible('games') && visible('post') && searchVisible('recent') && !searchVisible('trend1') && !searchVisible('trend2') && searchVisible('section_results')",
            disabled: "visible('ad') && visible('games') && searchVisible('trend2')")
        try await verify("linkedin", route: "/feed/network/", markup: """
            <main><div data-testid="NetworkFeedListCollection"><article id="ad"><span>Реклама</span></article><article id="post"><p>Мы обсуждали рекламу</p></article></div><aside id="news"><a href="/news/story/example">News</a></aside></main>
            """, flags: ["hideNews": true, "hidePromoted": true],
            enabled: "!visible('news') && !visible('ad') && visible('post')",
            disabled: "visible('news') && visible('ad')")
    }

    func testTikTokFeedLimitLocksNestedScrollingAndRestoresLiveSettings() async throws {
        let extensionURL = try XCTUnwrap(Bundle.main.builtInPlugInsURL)
            .appendingPathComponent("UnscrollExtension.appex")
        let configuration = WKWebViewConfiguration()
        var scripts = ["""
        window.testFlags = {feed:true, all:false};
        window.browser = {runtime:{
          sendMessage: (_, callback) => callback({toggles:{tiktok:window.testFlags}}),
          onMessage:{addListener: callback => window.updateTestSettings = callback},
          getURL: file => 'https://example.com/' + file
        }};
        """]
        for file in ["config.js", "pause-policy.js", "i18n.js", "content/common.js", "content/tiktok.js"] {
            scripts.append(file == "i18n.js" ? "Unscroll.i18n = {t:key=>key, setLocale:()=>{}}" :
                try String(contentsOf: extensionURL.appendingPathComponent(file), encoding: .utf8))
        }
        configuration.userContentController.addUserScript(WKUserScript(
            source: scripts.joined(separator: ";\n"), injectionTime: .atDocumentEnd, forMainFrameOnly: true))
        let view = WKWebView(frame: CGRect(x: 0, y: 0, width: 400, height: 800), configuration: configuration)
        let window = try XCTUnwrap(UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }
            .flatMap(\.windows).first { $0.isKeyWindow })
        window.addSubview(view)
        defer { view.removeFromSuperview(); view.stopLoading() }
        let markup = """
        <html><head><meta name="viewport" content="width=device-width,initial-scale=1">
        <style>html,body{margin:0;height:100%;overflow:hidden}#feed{height:100%;width:100%;overflow-y:scroll}
        video{display:block;width:100%;height:100%}#comments{position:fixed;right:0;top:0;width:100px;height:200px;overflow:auto}
        </style></head><body><div id="feed" style="overflow-y:scroll">
        <video></video><video></video><video></video><video></video><video></video><video></video>
        </div><div id="comments"><div style="height:10000px">Comments</div></div></body></html>
        """
        let server = try DownloadFixture(stalled: false, html: true, document: markup)
        defer { server.stop() }
        let origin = try await server.url()
        view.load(URLRequest(url: try XCTUnwrap(URL(string: "/", relativeTo: origin)?.absoluteURL)))
        func expect(_ expression: String, file: StaticString = #filePath, line: UInt = #line) async throws {
            for _ in 0..<50 {
                if (try? await view.evaluateJavaScript(expression)) as? Bool == true { return }
                try await Task.sleep(for: .milliseconds(100))
            }
            let diagnostic = try? await view.evaluateJavaScript("JSON.stringify({url:location.href, flags:window.testFlags, feed:document.documentElement.getAttribute('data-unscroll-tiktok-feed')})")
            XCTFail("\(expression): \(diagnostic ?? "unavailable")", file: file, line: line)
            throw URLError(.cannotParseResponse)
        }
        try await expect("document.documentElement.getAttribute('data-unscroll-tiktok-feed') === 'true'")
        _ = try await view.evaluateJavaScript("document.getElementById('comments').scrollTop = 5000; true")
        try await expect("!document.getElementById('unscroll-block-overlay') && window.scrollY === 0")
        _ = try await view.evaluateJavaScript("document.getElementById('feed').scrollTop = document.getElementById('feed').clientHeight * 4; true")
        try await expect("!!document.getElementById('unscroll-block-overlay') && getComputedStyle(document.getElementById('feed')).overflowY === 'hidden' && window.scrollY === 0")
        _ = try await view.evaluateJavaScript("window.testFlags.feed = false; window.updateTestSettings({type:'unscroll-state-updated'}); true")
        try await expect("!document.getElementById('unscroll-block-overlay') && getComputedStyle(document.getElementById('feed')).overflowY === 'scroll' && !document.getElementById('feed').hasAttribute('data-unscroll-tiktok-scroll-lock')")
        _ = try await view.evaluateJavaScript("window.testFlags.feed = true; window.updateTestSettings({type:'unscroll-state-updated'}); true")
        try await expect("!!document.getElementById('unscroll-block-overlay')")
        _ = try await view.evaluateJavaScript("history.pushState({}, '', '/search?q=test'); true")
        try await expect("!document.getElementById('unscroll-block-overlay') && getComputedStyle(document.getElementById('feed')).overflowY === 'scroll'")
    }

    func testYouTubeTemporaryDisappearancePreservesPresentedVideoAndSuspendsInlineMedia() async throws {
        let browser = WebAppProfileRuntime.shared(.youtube).session(.youtube)
        browser.stop()
        let configuration = browser.websiteConfiguration()
        configuration.mediaTypesRequiringUserActionForPlayback = []
        let tab = browser.addTab(configuration: configuration)
        let window = try XCTUnwrap(UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }
            .flatMap(\.windows).first { $0.isKeyWindow })
        tab.view.frame = CGRect(x: 0, y: 0, width: 200, height: 200)
        window.addSubview(tab.view)
        defer { tab.view.removeFromSuperview(); browser.stop() }

        // A locally generated silent WAV exercises real WebKit playback/suspension.
        // Only the system presentation mode is simulated; this is not a PiP UI test.
        var wave = Data("RIFF".utf8)
        func integer(_ value: UInt32, bytes: Int) {
            for shift in 0..<bytes { wave.append(UInt8(truncatingIfNeeded: value >> (shift * 8))) }
        }
        integer(8036, bytes: 4); wave.append(Data("WAVEfmt ".utf8))
        integer(16, bytes: 4); integer(1, bytes: 2); integer(1, bytes: 2)
        integer(8000, bytes: 4); integer(8000, bytes: 4)
        integer(1, bytes: 2); integer(8, bytes: 2)
        wave.append(Data("data".utf8)); integer(8000, bytes: 4)
        wave.append(Data(repeating: 128, count: 8000))
        tab.view.loadHTMLString("<html><body><video></video><audio loop src='data:audio/wav;base64,\(wave.base64EncodedString())'></audio></body></html>", baseURL: nil)
        for _ in 0..<50 {
            if !tab.view.isLoading,
               (try? await tab.view.evaluateJavaScript("Boolean(document.querySelector('audio'))")) as? Bool == true { break }
            try await Task.sleep(for: .milliseconds(100))
        }
        func expectState(_ expected: WKMediaPlaybackState) async throws {
            for _ in 0..<50 {
                if await tab.view.requestMediaPlaybackState() == expected { return }
                try await Task.sleep(for: .milliseconds(100))
            }
            let actual = await tab.view.requestMediaPlaybackState()
            XCTAssertEqual(actual, expected)
        }
        _ = try await tab.view.evaluateJavaScript("document.querySelector('audio').play(); true")
        try await expectState(.playing)
        for mode in ["picture-in-picture", "fullscreen", "inline"] {
            _ = try await tab.view.evaluateJavaScript("Object.defineProperty(document.querySelector('video'), 'webkitPresentationMode', { configurable: true, value: '\(mode)' }); true", in: nil, in: .defaultClient)
            browser.suspend()
            // Round-trip the WebContent process after the asynchronous mode query.
            _ = try await tab.view.evaluateJavaScript("true")
            try await expectState(mode == "inline" ? .suspended : .playing)
        }
        browser.select(tab)
        _ = try await tab.view.evaluateJavaScript("document.querySelector('audio').play(); true")
        try await expectState(.playing)
        // A stale mode-query callback must not suspend a newly reopened screen.
        browser.suspend()
        browser.select(tab)
        _ = try await tab.view.evaluateJavaScript("true")
        try await expectState(.playing)
    }

    func testXUserAgentKeepsWebKitIdentityAndAdvertisesSafariCompatibility() async throws {
        let browser = WebAppProfileRuntime.shared(.x).session(.x)
        browser.stop()
        defer { browser.stop() }
        let view = browser.addTab(configuration: browser.websiteConfiguration()).view
        let result = try await view.evaluateJavaScript("navigator.userAgent")
        let agent = try XCTUnwrap(result as? String)
        XCTAssertTrue(agent.contains("AppleWebKit/"))
        XCTAssertTrue(agent.contains("Safari/604.1 Slowth"), "X otherwise redirects to x-safari-https and never serves the page")
        let youtube = WebAppProfileRuntime.shared(.youtube).session(.youtube)
        XCTAssertFalse(youtube.websiteConfiguration().applicationNameForUserAgent?.contains("Safari/") == true)
    }

    func testPolicyInterruptionDoesNotHidePageButNetworkErrorsDo() {
        let browser = WebAppProfileRuntime.shared(.x).session(.x)
        browser.stop()
        defer { browser.stop() }
        let view = browser.addTab(configuration: browser.websiteConfiguration()).view
        let interrupted = NSError(domain: "WebKitErrorDomain", code: 102)
        browser.webView(view, didFailProvisionalNavigation: nil, withError: interrupted)
        XCTAssertNil(browser.failure)
        browser.webView(view, didFail: nil, withError: interrupted)
        XCTAssertNil(browser.failure)
        browser.webView(view, didFail: nil, withError: URLError(.cancelled))
        XCTAssertNil(browser.failure)
        browser.webView(view, didFail: nil, withError: URLError(.notConnectedToInternet))
        XCTAssertNotNil(browser.failure)
        browser.webView(view, didStartProvisionalNavigation: nil)
        XCTAssertNil(browser.failure)
        browser.webView(view, didFail: nil, withError: NSError(domain: NSURLErrorDomain, code: 102))
        XCTAssertNotNil(browser.failure, "Only the WebKit policy domain is ignored")
    }

    func testYouTubeHomeRedirectAndNavigationRestoreAcrossLiveSettings() async throws {
        let extensionURL = try XCTUnwrap(Bundle.main.builtInPlugInsURL)
            .appendingPathComponent("UnscrollExtension.appex")
        let configuration = WKWebViewConfiguration()
        let bridge = """
        window.testFlags = { shorts:false, feed:true, all:false, hideHomeFeed:true };
        window.fixtureDocumentID = Math.random().toString(36).slice(2);
        window.browser = { runtime: {
          sendMessage: (_, callback) => callback({toggles:{youtube:window.testFlags}}),
          onMessage: {addListener: callback => window.updateTestSettings = callback},
          getURL: file => 'https://example.com/' + file
        }};
        """
        var scripts = [bridge]
        for file in ["config.js", "pause-policy.js", "i18n.js", "content/common.js", "content/youtube.js"] {
            scripts.append(file == "i18n.js" ? "Unscroll.i18n = {t:key=>key, setLocale:()=>{}}" :
                try String(contentsOf: extensionURL.appendingPathComponent(file), encoding: .utf8))
        }
        scripts.append("""
        window.visible = id => document.getElementById(id).getBoundingClientRect().height > 0;
        window.navHidden = () => ['desktopHome','miniHome','mobileHome','mobileHomeLink'].every(id => !visible(id));
        window.othersVisible = () => ['header','subscriptions','mobileGrid','results','player','you','desktopSubscriptions'].every(visible);
        """)
        configuration.userContentController.addUserScript(WKUserScript(
            source: scripts.joined(separator: ";\n"), injectionTime: .atDocumentEnd, forMainFrameOnly: true))
        let view = WKWebView(frame: .zero, configuration: configuration)
        let markup = """
        <html><head><style>body * { display:block; min-height:20px; }</style></head><body>
        <header id="header"><input id="search"><a id="logo" href="/">YouTube</a></header>
        <ytd-guide-entry-renderer id="desktopHome"><a href="/">Home</a></ytd-guide-entry-renderer>
        <ytd-mini-guide-entry-renderer id="miniHome"><a href="/">Home</a></ytd-mini-guide-entry-renderer>
        <ytd-guide-entry-renderer id="desktopSubscriptions"><a href="/feed/subscriptions">Subscriptions</a></ytd-guide-entry-renderer>
        <ytm-pivot-bar-item-renderer id="mobileHome"><div class="pivot-bar-item-tab pivot-w2w">Home</div></ytm-pivot-bar-item-renderer>
        <ytm-pivot-bar-item-renderer id="mobileHomeLink"><a href="/">Home</a></ytm-pivot-bar-item-renderer>
        <ytm-pivot-bar-item-renderer id="you">You</ytm-pivot-bar-item-renderer>
        <ytd-browse page-subtype="subscriptions" id="subscriptions">Subscriptions</ytd-browse>
        <ytm-browse tab-identifier="FEsubscriptions"><ytm-rich-grid-renderer id="mobileGrid">Subscriptions</ytm-rich-grid-renderer></ytm-browse>
        <ytd-search id="results">Search results</ytd-search>
        <ytd-watch-flexy id="player"><video></video><ytd-watch-next-secondary-results-renderer>Related videos</ytd-watch-next-secondary-results-renderer></ytd-watch-flexy>
        </body></html>
        """
        let server = try DownloadFixture(stalled: false, html: true, document: markup)
        defer { server.stop() }
        let origin = try await server.url()
        // Read the route and DOM from the same committed WebKit document.
        // The outgoing page may still have the same subscriptions URL.
        func waitForPage(_ expression: String, file: StaticString = #filePath, line: UInt = #line) async throws -> String {
            let deadline = ContinuousClock.now + .seconds(5)
            while ContinuousClock.now < deadline {
                if !view.isLoading,
                   let id = (try? await view.evaluateJavaScript(
                       "(\(expression)) ? window.fixtureDocumentID : null"
                   )) as? String,
                   !view.isLoading { return id }
                try await Task.sleep(for: .milliseconds(50))
            }
            let actual = try? await view.evaluateJavaScript("""
            JSON.stringify({ path: location.pathname, document: window.fixtureDocumentID,
              hideHome: document.documentElement.getAttribute('data-unscroll-youtube-hideHomeFeed'),
              hasStyle: !!document.getElementById('unscroll-youtube-home-style') })
            """)
            return try XCTUnwrap(nil as String?,
                                 "Expected \(expression); last page: \(actual as? String ?? "unavailable")",
                                 file: file, line: line)
        }
        let subscriptions = "location.pathname === '/feed/subscriptions' && navHidden() && othersVisible()"
        let homeRestored = """
        document.documentElement.getAttribute('data-unscroll-youtube-hideHomeFeed') === 'false' &&
        !document.getElementById('unscroll-youtube-home-style') &&
        ['desktopHome','miniHome','mobileHome','mobileHomeLink'].every(visible) && othersVisible()
        """
        func check(_ expression: String, file: StaticString = #filePath, line: UInt = #line) async throws {
            let value = try await view.evaluateJavaScript(expression)
            XCTAssertEqual(value as? Bool, true, expression, file: file, line: line)
        }
        view.load(URLRequest(url: URL(string: "/?app=desktop", relativeTo: origin)!.absoluteURL))
        _ = try await waitForPage(subscriptions)
        XCTAssertFalse(view.canGoBack, "Home redirect replaces the initial entry")
        try await check("""
        (() => {
          const late = document.getElementById('mobileHome').cloneNode(true);
          late.id = 'lateHome'; document.body.appendChild(late);
          return !visible('lateHome') && othersVisible();
        })()
        """)
        for route in ["/results?search_query=test", "/watch?v=test", "/feed/library", "/@creator"] {
            _ = try await view.evaluateJavaScript("history.pushState({}, '', '\(route)'); window.dispatchEvent(new Event('yt-navigate-finish'));")
            try await check("navHidden() && othersVisible()")
            view.goBack()
            _ = try await waitForPage(subscriptions)
        }
        // Do not send the settings update to the outgoing document.
        let previousDocument = try await waitForPage(subscriptions)
        _ = try await view.evaluateJavaScript("document.getElementById('logo').click(); true")
        let currentDocument = try await waitForPage("\(subscriptions) && window.fixtureDocumentID !== '\(previousDocument)'")
        _ = try await view.evaluateJavaScript("testFlags.hideHomeFeed=false; updateTestSettings({type:'unscroll-state-updated'}); true")
        _ = try await waitForPage("location.pathname === '/feed/subscriptions' && window.fixtureDocumentID === '\(currentDocument)' && (\(homeRestored))")
        _ = try await view.evaluateJavaScript("history.pushState({}, '', '/'); window.dispatchEvent(new Event('popstate')); true")
        _ = try await waitForPage("location.pathname === '/' && window.fixtureDocumentID === '\(currentDocument)' && (\(homeRestored))")
        _ = try await view.evaluateJavaScript("testFlags.hideHomeFeed=true; updateTestSettings({type:'unscroll-state-updated'}); true")
        _ = try await waitForPage("\(subscriptions) && window.fixtureDocumentID !== '\(currentDocument)'")
    }

    func testStoriesTraySelectorsHideButtonsAndReservedSpaceWithoutHidingPosts() async throws {
        let extensionURL = try XCTUnwrap(Bundle.main.builtInPlugInsURL)
            .appendingPathComponent("UnscrollExtension.appex/config.js")
        let config = try String(contentsOf: extensionURL, encoding: .utf8)
        let view = WKWebView()
        // Sanitized structure observed on physical mobile Instagram: canvas
        // rings in buttons, a horizontal scroller, and single-child wrappers.
        let tray = """
        <div style="overflow-x:auto;overflow-y:hidden"><div style="display:flex">
        <div role="button"><div><canvas width="89" height="89"></canvas><span role="link"><img></span></div></div>
        <div role="button"><div><canvas width="89" height="89"></canvas><span role="link"><img></span></div></div>
        </div></div>
        """
        let trays = (0...4).map { depth in
            let wrapped = String(repeating: "<div>", count: depth) + tray + String(repeating: "</div>", count: depth)
            return "<section id='fixture\(depth)'>\(wrapped)<article style='height:80px'>Post</article></section>"
        }.joined()
        view.loadHTMLString("""
        <html><body><main>\(trays)
        <article id="post"><div role="button"><canvas width="30" height="30"></canvas><img></div>Post</article>
        <div id="messages" style="overflow-x:auto"><div><div role="button"><img height="30">Message</div></div></div>
        <div id="chart" style="overflow-x:auto"><div><canvas width="30" height="30"></canvas></div></div>
        </main></body></html>
        """, baseURL: URL(string: "https://example.com/"))
        for _ in 0..<50 {
            if !view.isLoading && view.url != nil { break }
            try await Task.sleep(for: .milliseconds(100))
        }
        _ = try await view.evaluateJavaScript(config)
        let result = try await view.evaluateJavaScript("""
        (() => {
          const visible = e => e.getBoundingClientRect().height > 0;
          const trays = [...document.querySelectorAll('section > div')];
          // Reproduce the reserved height on the outer wrapper.
          trays.forEach(e => e.style.height = '124px');
          const before = trays.every(visible);
          const style = document.createElement('style');
          style.textContent = Unscroll.INSTAGRAM_STORIES_RULES.hideSelectors
            .map(s => s + ' { display:none !important; }').join('\\n');
          document.head.appendChild(style);
          const hidden = trays.every(e => !visible(e));
          const unaffected = [...document.querySelectorAll('article,#messages,#chart')].every(visible);
          const dynamic = document.querySelector('#fixture4').cloneNode(true);
          document.querySelector('main').appendChild(dynamic);
          const dynamicHidden = !visible(dynamic.firstElementChild) && visible(dynamic.lastElementChild);
          style.remove();
          return [before, hidden, unaffected, dynamicHidden, trays.every(visible)];
        })()
        """)
        XCTAssertEqual(result as? [Bool], [true, true, true, true, true])
    }

    func testProfileIdentityAndRetainedSessions() {
        let meta = WebAppProfileRuntime.shared(.meta)
        XCTAssertTrue(meta === WebAppProfileRuntime.shared(WebAppService.facebook.profile))
        let instagram = meta.session(.instagram)
        XCTAssertTrue(instagram === meta.session(.instagram))
        XCTAssertFalse(instagram === meta.session(.facebook))
        XCTAssertEqual(instagram.websiteConfiguration().websiteDataStore.identifier, WebAppProfile.meta.identifier)
        for profile in WebAppProfile.allCases {
            let runtime = WebAppProfileRuntime.shared(profile)
            XCTAssertEqual(runtime.controller.configuration.identifier, profile.identifier)
            XCTAssertEqual(runtime.controller.configuration.defaultWebsiteDataStore.identifier, profile.identifier)
        }
    }

    func testActualCookieIsolationAndMetaSharing() async {
        let name = "slowth-test-" + UUID().uuidString
        let cookie = HTTPCookie(properties: [.domain: ".example.com", .path: "/", .name: name, .value: "meta"])!
        let meta = WebAppProfileRuntime.shared(.meta).dataStore.httpCookieStore
        await meta.setCookie(cookie)
        let facebook = WebAppProfileRuntime.shared(WebAppService.facebook.profile).dataStore.httpCookieStore
        let shared = await facebook.allCookies()
        XCTAssertTrue(shared.contains { $0.name == name })
        for profile in WebAppProfile.allCases where profile != .meta {
            let cookies = await WebAppProfileRuntime.shared(profile).dataStore.httpCookieStore.allCookies()
            XCTAssertFalse(cookies.contains { $0.name == name })
        }
        let legacy = await WKWebsiteDataStore.default().httpCookieStore.allCookies()
        XCTAssertFalse(legacy.contains { $0.name == name })
        await meta.deleteCookie(cookie)
    }

    func testClearAllWebsiteDataIncludesUnopenedProfilesAndLegacyStore() async throws {
        let types = WebAppProfileRuntime.websiteDataTypesToClear
        XCTAssertTrue(types.contains(WKWebsiteDataTypeCookies))
        XCTAssertTrue(types.contains(WKWebsiteDataTypeDiskCache))
        XCTAssertTrue(types.contains(WKWebsiteDataTypeLocalStorage))
        if #available(iOS 26.0, *) {
            XCTAssertFalse(types.contains(WKWebsiteDataTypeScreenTime),
                           "Website cleanup must not delete system Screen Time history")
        }
        let name = "slowth-clear-test-" + UUID().uuidString
        let cookie = try XCTUnwrap(HTTPCookie(properties: [
            .domain: ".example.com", .path: "/", .name: name, .value: "temporary"
        ]))
        let stores = WebAppProfile.allCases.map { WebAppProfileRuntime.shared($0).dataStore }
            + [WKWebsiteDataStore.default()]
        for (index, store) in stores.enumerated() {
            NSLog("[clear-data-test] Seed cookie store %d", index)
            await store.httpCookieStore.setCookie(cookie)
        }
        for service in WebAppService.allCases {
            UserDefaults.standard.set(service.url, forKey: "webapps.last-url.v2." + service.id)
        }
        let downloads = FileManager.default.temporaryDirectory.appendingPathComponent("SlowthDownloads", isDirectory: true)
        try FileManager.default.createDirectory(at: downloads, withIntermediateDirectories: true)
        try Data("temporary download".utf8).write(to: downloads.appendingPathComponent(name))

        NSLog("[clear-data-test] Clear all website data")
        try await WebAppProfileRuntime.clearAllData()
        NSLog("[clear-data-test] Verify all stores")

        for store in stores {
            let cookies = await store.httpCookieStore.allCookies()
            XCTAssertFalse(cookies.contains { $0.name == name })
        }
        for service in WebAppService.allCases {
            XCTAssertNil(UserDefaults.standard.url(forKey: "webapps.last-url.v2." + service.id))
        }
        XCTAssertFalse(FileManager.default.fileExists(atPath: downloads.path))
    }

    func testBrowserDismissalDiscardsMainDocumentAndPopup() async throws {
        let router = WebAppsRouter.shared
        let runtime = WebAppProfileRuntime.shared(.youtube)
        let browser = runtime.session(.youtube)
        browser.stop()
        let window = try XCTUnwrap(UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }
            .flatMap(\.windows).first { $0.isKeyWindow })
        let previousRoot = window.rootViewController
        let host = UIHostingController(rootView: Color.clear.modifier(WebAppsPresentation()))
        window.rootViewController = host
        defer {
            router.dismissForNativePrompt()
            router.didDismiss()
            browser.stop()
            window.rootViewController = previousRoot
        }
        let server = try DownloadFixture(stalled: false, html: true, document:
            "<script>window.pageTicks = 1; setInterval(() => ++window.pageTicks, 10)</script>")
        defer { server.stop() }
        let url = try await server.url()
        // Keep references through dismissal, as a system media presentation can do.
        let main = browser.addTab(configuration: browser.websiteConfiguration()).view
        main.load(URLRequest(url: url))
        try await waitForBrowserPage(main, url: url)
        let popup = browser.addTab(configuration: browser.websiteConfiguration()).view
        popup.load(URLRequest(url: url))
        try await waitForBrowserPage(popup, url: url)

        router.open(.youtube)
        for _ in 0..<100 {
            if host.presentedViewController != nil, runtime.focused === browser { break }
            try await Task.sleep(for: .milliseconds(50))
        }
        XCTAssertTrue(runtime.focused === browser)
        let ticking = try await popup.evaluateJavaScript("window.pageTicks > 0")
        XCTAssertEqual(ticking as? Bool, true)
        router.dismissForNativePrompt()
        for _ in 0..<100 {
            if browser.activeView == nil, !router.isDismissing { break }
            try await Task.sleep(for: .milliseconds(50))
        }
        XCTAssertNil(browser.activeView)
        XCTAssertTrue(browser.windows.isEmpty)
        XCTAssertNil(runtime.focused)
        for view in [main, popup] {
            try await waitForBrowserPage(view, url: try XCTUnwrap(URL(string: "about:blank")))
            let discarded = try await view.evaluateJavaScript("typeof window.pageTicks === 'undefined'")
            XCTAssertEqual(discarded as? Bool, true)
        }
    }

    func testPageCannotReadDeviceLocation() async throws {
        XCTAssertNil(Bundle.main.object(forInfoDictionaryKey: "NSLocationWhenInUseUsageDescription"))
        let server = try DownloadFixture(stalled: false, html: true)
        defer { server.stop() }
        let site = try await server.url()
        let browser = WebAppProfileRuntime.shared(.x).session(.x)
        defer { browser.stop() }
        let view = browser.addTab(configuration: browser.websiteConfiguration()).view
        let window = try XCTUnwrap(UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }
            .flatMap(\.windows).first { $0.isKeyWindow })
        window.addSubview(view)
        defer { view.removeFromSuperview() }
        view.load(URLRequest(url: site))
        try await waitForBrowserPage(view, url: site)
        let denied = try await view.callAsyncJavaScript("""
            const denied = method => new Promise(resolve => {
                const timeout = setTimeout(() => resolve(false), 4000);
                navigator.geolocation[method](() => resolve(false), error => {
                    clearTimeout(timeout);
                    resolve(error.code === error.PERMISSION_DENIED);
                });
            });
            return await denied('getCurrentPosition') && await denied('watchPosition');
            """, arguments: [:], in: nil, contentWorld: .page)
        XCTAssertEqual(denied as? Bool, true)
    }

    func testWindowCloseReturnsToOpenerAndCannotCloseMain() {
        let browser = WebAppProfileRuntime.shared(.youtube).session(.youtube)
        browser.stop()
        let main = browser.addTab(configuration: browser.websiteConfiguration())
        let popup = browser.addTab(configuration: browser.websiteConfiguration())
        let nested = browser.addTab(configuration: browser.websiteConfiguration())
        XCTAssertTrue(nested.opener === popup)
        browser.webViewDidClose(nested.view)
        XCTAssertTrue(browser.activeView === popup.view)
        browser.webViewDidClose(popup.view)
        XCTAssertTrue(browser.activeView === main.view)
        browser.webViewDidClose(main.view)
        XCTAssertEqual(browser.windows.count, 1)
        browser.suspend()
        XCTAssertTrue(browser.activeView === main.view)
        XCTAssertTrue(WebAppProfileRuntime.shared(.youtube).session(.youtube).activeView === main.view)
        browser.stop()
    }

    func testThirdPartyTrackingRequestsAreFilteredBeforeReachingTheHandler() async throws {
        let runtime = WebAppProfileRuntime.shared(.youtube)
        try await runtime.start()
        let browser = runtime.session(.youtube)
        defer { browser.stop() }
        let configuration = browser.websiteConfiguration()
        let fixture = TrackingResourceFixture()
        configuration.setURLSchemeHandler(fixture, forURLScheme: "fixture")
        let view = browser.addTab(configuration: configuration).view
        let scripts = [
            "fixture://www.google-analytics.com/analytics.js",
            "fixture://www.clarity.ms/tag/project",
            "fixture://static.hotjar.com/widget.js",
            "fixture://ad.doubleclick.net/player.js",
        ]
        let blocked = [
            "fixture://region1.google-analytics.com/g/collect?v=2",
            "fixture://www.google-analytics.com/mp/collect",
            "fixture://analytics.google.com/g/collect",
            "fixture://p.clarity.ms/collect",
            "fixture://www.facebook.com/tr/?id=1",
            "fixture://ad.doubleclick.net/ddm/activity/src=123;type=example",
            "fixture://in.hotjar.com/api/v2/client/sites/42/visit-data",
        ]
        let allowed = [
            "fixture://www.google-analytics.com/g/collection",
            "fixture://google-analytics.com.example.org/g/collect",
            "fixture://news.example/google-analytics.com/g/collect",
            "fixture://www.facebook.com/tr/login",
            "fixture://www.clarity.ms/collect/config",
            "fixture://in.hotjar.com/api/v2/client/sites/42/survey",
            "fixture://ad.doubleclick.net/activity/player",
        ]
        let markup = scripts.map { "<script src='\($0)'></script>" }.joined()
            + (blocked + allowed).map { "<img src='\($0)'>" }.joined()
            + """
              <script>
              window.fixtureFinished = Promise.all([
                'fixture://www.clarity.ms/collect?upload=1',
                'fixture://www.clarity.ms/settings'
              ].map(url => fetch(url, {method:'POST', mode:'no-cors', body:'event'}).catch(() => {})));
              </script>
              """
        let server = try DownloadFixture(stalled: false, html: true, document: markup)
        defer { server.stop() }
        let site = try await server.url()
        view.load(URLRequest(url: site))
        try await waitForBrowserPage(view, url: site)
        _ = try await view.callAsyncJavaScript("await window.fixtureFinished; return true",
                                               arguments: [:], in: nil, contentWorld: .page)
        XCTAssertEqual(fixture.requests.sorted(),
                       (scripts + allowed + ["fixture://www.clarity.ms/settings"]).sorted())
    }

    func testRealPopupPreservesWindowOpener() async throws {
        let runtime = WebAppProfileRuntime.shared(.x)
        try await runtime.start()
        let browser = runtime.session(.x)
        browser.stop()
        let configuration = browser.websiteConfiguration()
        configuration.preferences.javaScriptCanOpenWindowsAutomatically = true
        let main = browser.addTab(configuration: configuration)
        main.view.loadHTMLString("<html><body>Popup fixture</body></html>", baseURL: URL(string: "https://example.com/"))
        for _ in 0..<50 {
            if main.view.url != nil && !main.view.isLoading { break }
            try await Task.sleep(for: .milliseconds(100))
        }
        _ = try await main.view.evaluateJavaScript("window.open('about:blank', 'slowthTestPopup'); true")
        XCTAssertEqual(browser.windows.count, 2)
        let popup = try XCTUnwrap(browser.windows.last)
        let hasOpener = try await popup.view.evaluateJavaScript("window.opener !== null")
        XCTAssertEqual(hasOpener as? Bool, true)
        XCTAssertEqual(popup.view.configuration.websiteDataStore.identifier, runtime.dataStore.identifier)
        browser.webViewDidClose(popup.view)
        XCTAssertTrue(browser.activeView === main.view)
        browser.stop()
    }

    func testClickedLinksStayInProfileAndCustomSchemesAreCancelled() async throws {
        let server = try DownloadFixture(stalled: false, html: true)
        defer { server.stop() }
        let base = try await server.url()
        let browser = WebAppProfileRuntime.shared(.youtube).session(.youtube)
        browser.stop()
        defer { browser.stop() }
        let main = browser.addTab(configuration: browser.websiteConfiguration())
        main.view.load(URLRequest(url: base))
        func waitForPage(_ view: WKWebView, path: String) async throws {
            for _ in 0..<300 {
                if view.url?.path == path && !view.isLoading { return }
                try await Task.sleep(for: .milliseconds(100))
            }
            XCTFail("Web link did not finish inside its WKWebView: \(path)")
        }
        try await waitForPage(main.view, path: base.path)
        XCTAssertFalse(main.view.allowsLinkPreview)
        _ = try await main.view.evaluateJavaScript("document.getElementById('same').click(); true")
        try await waitForPage(main.view, path: "/next")
        XCTAssertEqual(browser.windows.count, 1)
        var scriptDestination = URLComponents(url: base, resolvingAgainstBaseURL: false)!
        scriptDestination.host = "localhost"
        scriptDestination.path = "/redirect"
        let scriptURL = String(data: try JSONEncoder().encode(scriptDestination.url!.absoluteString), encoding: .utf8)!
        _ = try await main.view.evaluateJavaScript("sessionStorage.setItem('slowth-login-context', 'retained'); location.assign(\(scriptURL)); true")
        try await waitForPage(main.view, path: "/returned")
        XCTAssertEqual(main.view.url?.host, "127.0.0.1")
        let retained = try await main.view.evaluateJavaScript("sessionStorage.getItem('slowth-login-context')")
        XCTAssertEqual(retained as? String, "retained")
        XCTAssertEqual(browser.windows.count, 1)
        _ = try await main.view.evaluateJavaScript("document.getElementById('popup').click(); true")
        for _ in 0..<300 {
            if browser.windows.count == 2 { break }
            try await Task.sleep(for: .milliseconds(100))
        }
        XCTAssertEqual(browser.windows.count, 2)
        let popup = try XCTUnwrap(browser.windows.last)
        try await waitForPage(popup.view, path: "/popup")
        XCTAssertFalse(popup.view.allowsLinkPreview)
        XCTAssertEqual(popup.view.configuration.websiteDataStore.identifier, WebAppProfile.youtube.identifier)
        _ = try await popup.view.evaluateJavaScript("document.getElementById('native').click(); true")
        // A subsequent JS evaluation is a WebKit round-trip after the click.
        _ = try await popup.view.evaluateJavaScript("document.title")
        XCTAssertEqual(popup.view.url?.path, "/popup")
        XCTAssertNil(browser.failure)
        browser.webViewDidClose(popup.view)
        XCTAssertTrue(browser.activeView === main.view)
    }

    func testExtensionDisconnectAndRecovery() async throws {
        let runtime = WebAppProfileRuntime.shared(.tiktok)
        try await runtime.start()
        try runtime.controller.unload(XCTUnwrap(runtime.context))
        runtime.requestVerification(force: true)
        // Disconnect is asynchronous; it must become visible instead of silently
        // continuing with the last successful protection indicator.
        for _ in 0..<50 {
            if runtime.protection == .failed { break }
            try await Task.sleep(for: .milliseconds(100))
        }
        XCTAssertEqual(runtime.protection, .failed)
        runtime.prepareRecovery()
        try await runtime.start()
        XCTAssertTrue(runtime.context?.isLoaded == true)
        XCTAssertNotEqual(runtime.protection, .failed)
    }

    func testRecoveryDuringStartupCannotReplaceNewContext() async throws {
        let runtime = WebAppProfileRuntime.shared(.tiktok)
        runtime.prepareRecovery()
        let previous = Task { try await runtime.start() }
        await Task.yield()
        runtime.prepareRecovery()
        try await runtime.start()
        let context = runtime.context
        _ = try? await previous.value
        XCTAssertTrue(runtime.context === context)
        XCTAssertTrue(runtime.context?.isLoaded == true)
        XCTAssertNotEqual(runtime.protection, .failed)
    }

    func testDownloadCompletesInPrivateDirectoryAndCanBeRemoved() async throws {
        let server = try DownloadFixture(stalled: false)
        defer { server.stop() }
        let url = try await server.url()
        let view = WKWebView()
        let downloads = WebAppDownloads()
        view.startDownload(using: URLRequest(url: url)) { downloads.add($0) }
        for _ in 0..<300 {
            if downloads.items.first?.complete == true || downloads.items.first?.error != nil { break }
            try await Task.sleep(for: .milliseconds(100))
        }
        let item = try XCTUnwrap(downloads.items.first)
        XCTAssertNil(item.error)
        XCTAssertTrue(item.complete)
        let destination = try XCTUnwrap(item.url)
        // WebKit may sanitize the server filename before handing it to the host.
        XCTAssertEqual(destination.pathExtension, "pdf")
        XCTAssertTrue(destination.lastPathComponent.hasSuffix("proof.pdf"))
        XCTAssertEqual(try Data(contentsOf: destination), DownloadFixture.body)
        XCTAssertEqual(destination.deletingLastPathComponent().deletingLastPathComponent().lastPathComponent, "SlowthDownloads")
        downloads.remove(item.id)
        XCTAssertFalse(FileManager.default.fileExists(atPath: destination.path))
        XCTAssertTrue(downloads.items.isEmpty)
    }

    func testDownloadCancellationRemovesPartialFile() async throws {
        let server = try DownloadFixture(stalled: true)
        defer { server.stop() }
        let view = WKWebView()
        let downloads = WebAppDownloads()
        let url = try await server.url()
        view.startDownload(using: URLRequest(url: url)) { downloads.add($0) }
        for _ in 0..<300 {
            if downloads.items.first?.url != nil { break }
            try await Task.sleep(for: .milliseconds(100))
        }
        let item = try XCTUnwrap(downloads.items.first)
        let destination = try XCTUnwrap(item.url)
        downloads.cancel(item.id)
        for _ in 0..<300 {
            if downloads.items.isEmpty { break }
            try await Task.sleep(for: .milliseconds(100))
        }
        XCTAssertTrue(downloads.items.isEmpty)
        XCTAssertFalse(FileManager.default.fileExists(atPath: destination.path))
    }

    func testBundledExtensionStartsWithLiveNativePort() async throws {
        let runtime = WebAppProfileRuntime.shared(.tiktok)
        try await runtime.start()
        XCTAssertTrue(runtime.context?.isLoaded == true)
        XCTAssertNotEqual(runtime.protection, .failed)
    }
}

// Use a real SwiftUI cover without starting network/extension sessions: this
// fixture isolates ContentView's native popup arbitration from website loading.
private struct ShieldHandoffTestRoot: View {
    @ObservedObject private var router = WebAppsRouter.shared
    var body: some View {
        // Unsigned simulator hosts have no App Group container. Supply a fresh
        // empty rest snapshot while exercising the production request and UI path.
        ContentView(openRests: { [] })
            .fullScreenCover(item: $router.service, onDismiss: router.didDismiss) { _ in
                Color.clear
            }
    }
}

@MainActor
private final class TrackingResourceFixture: NSObject, WKURLSchemeHandler {
    var requests: [String] = []
    func webView(_ webView: WKWebView, start urlSchemeTask: WKURLSchemeTask) {
        let url = urlSchemeTask.request.url!
        requests.append(url.absoluteString)
        urlSchemeTask.didReceive(URLResponse(url: url, mimeType: "application/javascript",
                                             expectedContentLength: 0, textEncodingName: "utf-8"))
        urlSchemeTask.didFinish()
    }
    func webView(_ webView: WKWebView, stop urlSchemeTask: WKURLSchemeTask) {}
}

private final class DownloadFixture {
    static let body = Data("%PDF-1.4\nSlowth download fixture\n%%EOF".utf8)
    private let listener: NWListener
    private let queue = DispatchQueue(label: "slowth.download-test")
    private var connections: [NWConnection] = []
    private var ready = false // Accessed only on queue.
    init(stalled: Bool, html: Bool = false, document: String? = nil) throws {
        listener = try NWListener(using: .tcp, on: .any)
        listener.newConnectionHandler = { [weak self] connection in
            guard let self else { return }
            self.connections.append(connection)
            connection.start(queue: self.queue)
            connection.receive(minimumIncompleteLength: 1, maximumLength: 8192) { data, _, _, _ in
                if html, let data, String(decoding: data, as: UTF8.self).hasPrefix("GET /redirect "),
                   let port = self.listener.port {
                    let redirect = "HTTP/1.1 302 Found\r\nLocation: http://127.0.0.1:\(port.rawValue)/returned\r\nContent-Length: 0\r\nConnection: close\r\n\r\n"
                    connection.send(content: Data(redirect.utf8), contentContext: .finalMessage,
                                    isComplete: true, completion: .contentProcessed { _ in })
                    return
                }
                let body = html ? Data((document ?? "<html><title>Links</title><a id='same' href='/next'>Next</a><a id='popup' href='/popup' target='_blank'>Popup</a><a id='native' href='youtube://watch?v=123'>Native</a></html>").utf8) : Self.body
                let length = stalled ? 10000000 : body.count
                let contentHeaders = html ? "Content-Type: text/html\r\n" : "Content-Type: application/pdf\r\nContent-Disposition: attachment; filename=\"../../proof.pdf\"\r\n"
                let headers = "HTTP/1.1 200 OK\r\n\(contentHeaders)Content-Length: \(length)\r\nConnection: close\r\n\r\n"
                connection.send(content: Data(headers.utf8) + body, contentContext: stalled ? .defaultMessage : .finalMessage,
                                isComplete: !stalled, completion: .contentProcessed { _ in })
            }
        }
        listener.stateUpdateHandler = { [weak self] state in
            if case .ready = state { self?.ready = true }
        }
        listener.start(queue: queue)
    }
    @MainActor func url() async throws -> URL {
        for _ in 0..<300 {
            // The port may be assigned before the listener can accept requests.
            let port = queue.sync { ready ? listener.port : nil }
            if let port, port.rawValue > 0 { return URL(string: "http://127.0.0.1:\(port.rawValue)/proof.pdf")! }
            try await Task.sleep(for: .milliseconds(100))
        }
        throw URLError(.cannotConnectToHost)
    }
    func stop() {
        listener.cancel()
        queue.async { for connection in self.connections { connection.cancel() } }
    }
}
