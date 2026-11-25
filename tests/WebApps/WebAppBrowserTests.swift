import XCTest
import WebKit
import Network
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

    func testYouTubeDismissalPreservesPresentedVideoAndSuspendsInlineMedia() async throws {
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
        for profile in [WebAppProfile.youtube, .tiktok, .x] {
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
