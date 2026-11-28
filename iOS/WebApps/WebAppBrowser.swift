import SwiftUI
import WebKit
import QuickLook
import AVFAudio

@available(iOS 18.4, *)
@MainActor
final class WebAppTab: NSObject, WKWebExtensionTab {
    let view: WKWebView
    weak var owner: WebAppBrowser?
    weak var opener: WebAppTab?
    var lastRequestedURL: URL?
    var pendingInAppURL: URL?
    var requestMethod = "GET"
    let isExtensionPage: Bool
    init(view: WKWebView, owner: WebAppBrowser, isExtensionPage: Bool = false) {
        self.view = view; self.owner = owner; self.isExtensionPage = isExtensionPage
    }
    func webView(for context: WKWebExtensionContext) -> WKWebView? { view }
    func window(for context: WKWebExtensionContext) -> (any WKWebExtensionWindow)? { owner }
    func url(for context: WKWebExtensionContext) -> URL? { view.url }
    func isLoadingComplete(for context: WKWebExtensionContext) -> Bool { !view.isLoading }
    func loadURL(_ url: URL, for context: WKWebExtensionContext, completionHandler: @escaping (Error?) -> Void) {
        #if DEBUG
        if ProcessInfo.processInfo.arguments.contains("--web-apps-diagnostics") {
            print("[WebApps] extension navigation: \(url.scheme ?? "") \(url.host ?? "")")
        }
        #endif
        owner?.navigate(url, in: self); completionHandler(nil)
    }
}

/// Only the bundled Slowth extension receives native messaging and site permissions.
@available(iOS 18.4, *)
@MainActor
final class WebAppBrowser: NSObject, ObservableObject, WKWebExtensionWindow, WKNavigationDelegate, WKUIDelegate {
    @Published private(set) var activeView: WKWebView?
    @Published private(set) var canGoBack = false
    @Published private(set) var canGoForward = false
    @Published private(set) var windows: [WebAppTab] = []
    @Published private(set) var loading = true
    @Published private(set) var failure: String?
    @Published private(set) var currentHost = ""
    let service: WebAppService
    let runtime: WebAppProfileRuntime
    let downloads = WebAppDownloads()
    private var controller: WKWebExtensionController { runtime.controller }
    private var context: WKWebExtensionContext? { runtime.context }
    private var browserTabs: [WebAppTab] = []
    private var observations: [NSKeyValueObservation] = []
    private var startToken: UUID?
    private var mediaVisibilityRevision = UUID()
    private var restorationKey: String { "webapps.last-url.v2." + service.id }

    init(service: WebAppService, runtime: WebAppProfileRuntime) {
        self.service = service; self.runtime = runtime; super.init()
    }

    func start() async {
        mediaVisibilityRevision = UUID()
        if service == .youtube {
            // Configure without activating: opening YouTube must not interrupt
            // another app's audio. WebKit activates playback when the user plays.
            try? AVAudioSession.sharedInstance().setCategory(.playback, mode: .moviePlayback)
        }
        guard startToken == nil, !Task.isCancelled else { return }
        let token = UUID()
        startToken = token
        defer { if startToken == token { startToken = nil } }
        failure = nil
        runtime.setVisible(self, true)
        do {
            try await runtime.start()
            guard startToken == token else { return }
            if activeView == nil {
                let tab = addTab(configuration: websiteConfiguration())
                let saved = UserDefaults.standard.url(forKey: restorationKey).flatMap { service.restorableURL($0) }
                navigate(saved ?? service.url, in: tab)
            }
            controller.didFocusWindow(self)
            activeView?.setAllMediaPlaybackSuspended(false, completionHandler: nil)
            openRequestedWebsite()
            runtime.requestVerification(force: true)
        } catch {
            guard startToken == token else { return }
            failure = String(localized: "Slowth could not start its extension. Please try again.", table: "WebApps")
            loading = false
        }
    }

    func websiteConfiguration() -> WKWebViewConfiguration {
        let config = WKWebViewConfiguration()
        config.webExtensionController = controller
        config.websiteDataStore = runtime.dataStore
        // X sends bare WKWebView user agents to x-safari-https:// instead of
        // serving HTML. Keep WebKit's device/OS identity, adding its Safari
        // compatibility token only in the X browser (including login popups).
        if service == .x { config.applicationNameForUserAgent = "Safari/604.1 Slowth" }
        config.allowsInlineMediaPlayback = true
        config.allowsPictureInPictureMediaPlayback = true
        return config
    }

    func suspend() {
        runtime.setVisible(self, false)
        // A full-screen player can temporarily cover the browser. The presentation
        // owner calls stop() when the browser cover itself is dismissed.
        let revision = UUID()
        mediaVisibilityRevision = revision
        guard let view = activeView else { return }
        guard service == .youtube else {
            view.setAllMediaPlaybackSuspended(true, completionHandler: nil)
            return
        }
        // Full-screen presentation can also make SwiftUI disappear, including
        // during its transition to PiP. Never suspend either presentation.
        // Use an isolated world so page scripts cannot replace the DOM getters.
        view.evaluateJavaScript(Self.detachedVideoPresentation, in: nil, in: .defaultClient) { [weak self, weak view] result in
            guard let self, let view, self.mediaVisibilityRevision == revision,
                  self.activeView === view else { return }
            guard case .success(let presented) = result, presented as? Bool == false else { return }
            view.setAllMediaPlaybackSuspended(true, completionHandler: nil)
        }
    }

    static let detachedVideoPresentation = """
    Boolean(document.pictureInPictureElement) || Array.from(document.querySelectorAll('video')).some(video =>
        video.webkitPresentationMode === 'picture-in-picture' ||
        video.webkitPresentationMode === 'fullscreen' || video.webkitDisplayingFullscreen === true)
    """

    func stop() {
        mediaVisibilityRevision = UUID()
        startToken = nil
        runtime.setVisible(self, false)
        observations.removeAll()
        downloads.cancelActive()
        for tab in browserTabs {
            discardPage(tab)
            controller.didCloseTab(tab, windowIsClosing: true)
        }
        browserTabs.removeAll(); windows = []; activeView = nil
        updateState()
    }

    private func discardPage(_ tab: WebAppTab) {
        tab.owner = nil
        let view = tab.view
        view.scrollView.refreshControl?.endRefreshing()
        view.navigationDelegate = nil
        view.uiDelegate = nil
        view.stopLoading()
        view.setCameraCaptureState(.none, completionHandler: nil)
        view.setMicrophoneCaptureState(.none, completionHandler: nil)
        view.setAllMediaPlaybackSuspended(true, completionHandler: nil)
        view.closeAllMediaPresentations(completionHandler: nil)
        // SwiftUI or a system presentation may still hold the view during dismissal.
        // Replace the document so its scripts stop even while that reference exists.
        view.loadHTMLString("", baseURL: nil)
    }

    func clearRestoration() { UserDefaults.standard.removeObject(forKey: restorationKey) }

    func addTab(configuration: WKWebViewConfiguration) -> WebAppTab {
        configuration.webExtensionController = controller
        let view = makeWebsiteView(configuration)
        configure(view)
        let previous = browserTabs.last
        let tab = WebAppTab(view: view, owner: self)
        tab.opener = browserTabs.first { $0.view === activeView }
        browserTabs.append(tab)
        windows = browserTabs
        controller.didOpenTab(tab)
        controller.didActivateTab(tab, previousActiveTab: previous)
        show(tab)
        return tab
    }

    private func makeWebsiteView(_ configuration: WKWebViewConfiguration) -> WKWebView {
        // Runtime startup prepares the list before loading the extension or opening
        // the first tab. Popups keep WebKit's supplied configuration and opener.
        let content = configuration.userContentController
        if let rules = runtime.trackingRules { content.add(rules) }
        if #unavailable(iOS 27.0), !content.userScripts.contains(Self.legacyLocationDenial) {
            content.addUserScript(Self.legacyLocationDenial)
        }
        return WKWebView(frame: .zero, configuration: configuration)
    }

    // Older WebKit lacks the native location delegate. The host has no system
    // location permission; complete site callbacks even when Core Location cannot.
    private static let legacyLocationDenial = WKUserScript(source: """
        (() => {
            if (!navigator.geolocation) return;
            const api = Object.getPrototypeOf(navigator.geolocation);
            if (!Object.getOwnPropertyDescriptor(api, 'getCurrentPosition')?.configurable) return;
            const error = Object.freeze({ code: 1, message: 'Geolocation permission denied.',
                PERMISSION_DENIED: 1, POSITION_UNAVAILABLE: 2, TIMEOUT: 3 });
            function deny(success, failure) {
                if (typeof failure === 'function') queueMicrotask(() => failure(error));
            }
            Object.defineProperties(api, {
                getCurrentPosition: { value: deny, configurable: false, writable: false },
                watchPosition: { value(success, failure) { deny(success, failure); return 0; },
                    configurable: false, writable: false }
            });
        })();
        """, injectionTime: .atDocumentStart, forMainFrameOnly: false, in: .page)

    private func configure(_ view: WKWebView) {
        view.allowsBackForwardNavigationGestures = true
        view.allowsLinkPreview = false
        view.navigationDelegate = self; view.uiDelegate = self
        view.scrollView.alwaysBounceVertical = true
        let refresh = UIRefreshControl()
        refresh.addTarget(self, action: #selector(refreshPage(_:)), for: .valueChanged)
        view.scrollView.refreshControl = refresh
    }

    @objc private func refreshPage(_ refresh: UIRefreshControl) {
        guard activeView?.scrollView.refreshControl === refresh else {
            refresh.endRefreshing()
            return
        }
        reload()
    }

    var copyableURL: URL? {
        guard let url = activeView?.url, ["https", "http"].contains(url.scheme?.lowercased() ?? "") else { return nil }
        return url
    }

    func copyCurrentLink(to pasteboard: UIPasteboard = .general) {
        guard let url = copyableURL else { return }
        pasteboard.url = url
    }

    private func isExtensionURL(_ url: URL) -> Bool {
        url.scheme == context?.baseURL.scheme && url.host == context?.baseURL.host
    }

    func navigate(_ url: URL, in tab: WebAppTab) {
        let extensionPage = isExtensionURL(url)
        guard extensionPage != tab.isExtensionPage else {
            tab.lastRequestedURL = url
            tab.view.load(URLRequest(url: url))
            return
        }
        guard let index = browserTabs.firstIndex(where: { $0 === tab }), let context else { return }
        // WebKit forbids extension URLs in ordinary WKWebViews (and vice versa).
        // Replace the tab's view using the extension's privileged configuration.
        guard let config = extensionPage ? context.webViewConfiguration : websiteConfiguration() else { return }
        config.webExtensionController = controller
        let view = extensionPage ? WKWebView(frame: .zero, configuration: config) : makeWebsiteView(config)
        configure(view)
        let replacement = WebAppTab(view: view, owner: self, isExtensionPage: extensionPage)
        replacement.opener = tab.opener
        replacement.lastRequestedURL = url
        let active = activeView === tab.view
        discardPage(tab)
        browserTabs[index] = replacement
        windows = browserTabs
        controller.didReplaceTab(tab, with: replacement)
        if active {
            controller.didActivateTab(replacement, previousActiveTab: tab)
            failure = nil
            show(replacement)
        }
        view.load(URLRequest(url: url))
    }

    private func show(_ tab: WebAppTab) {
        mediaVisibilityRevision = UUID()
        if activeView !== tab.view { activeView?.scrollView.refreshControl?.endRefreshing() }
        observations.removeAll()
        activeView = tab.view
        tab.view.setAllMediaPlaybackSuspended(false, completionHandler: nil)
        observations = [
            tab.view.observe(\.canGoBack, options: [.initial, .new]) { [weak self] _, _ in
                Task { @MainActor in self?.updateState() }
            },
            tab.view.observe(\.canGoForward, options: [.initial, .new]) { [weak self] _, _ in
                Task { @MainActor in self?.updateState() }
            },
            tab.view.observe(\.isLoading, options: [.initial, .new]) { [weak self] _, _ in
                Task { @MainActor in self?.updateState() }
            },
            tab.view.observe(\.url, options: [.initial, .new]) { [weak self] _, _ in
                Task { @MainActor in self?.updateState() }
            }
        ]
        updateState()
    }

    private func updateState() {
        canGoBack = activeView?.canGoBack == true || canCloseWindow
        canGoForward = activeView?.canGoForward == true
        loading = activeView?.isLoading ?? false
        if !loading { activeView?.scrollView.refreshControl?.endRefreshing() }
        if let url = activeView?.url, isExtensionURL(url) { currentHost = "Slowth" }
        else { currentHost = activeView?.url?.host ?? service.url.host ?? service.title }
    }

    func back() {
        if activeView?.canGoBack == true { activeView?.goBack() }
        else if browserTabs.count > 1, let view = activeView { webViewDidClose(view) }
    }
    func reload() {
        guard let tab = browserTabs.first(where: { $0.view === activeView }) else { return }
        let failed = failure != nil
        failure = nil
        if failed || tab.view.url == nil {
            tab.view.load(URLRequest(url: tab.lastRequestedURL ?? service.url))
        } else { tab.view.reload() }
    }

    func forward() { activeView?.goForward() }
    func openRequestedWebsite() {
        guard let main = browserTabs.first, let url = WebAppsRouter.shared.takeWebsiteURL(for: service) else { return }
        select(main)
        navigate(url, in: main)
    }
    func home() {
        while browserTabs.count > 1 { webViewDidClose(browserTabs.last!.view) }
        if let main = browserTabs.first { navigate(service.url, in: main) }
    }
    func select(_ tab: WebAppTab) {
        let previous = browserTabs.first { $0.view === activeView }
        controller.didActivateTab(tab, previousActiveTab: previous)
        show(tab)
    }
    var canCloseWindow: Bool { browserTabs.first?.view !== activeView }
    func closeWindow() { if let view = activeView { webViewDidClose(view) } }

    func tabs(for context: WKWebExtensionContext) -> [any WKWebExtensionTab] { browserTabs }
    func activeTab(for context: WKWebExtensionContext) -> (any WKWebExtensionTab)? { browserTabs.first { $0.view === activeView } }
    func webView(_ webView: WKWebView, createWebViewWith configuration: WKWebViewConfiguration,
                 for navigationAction: WKNavigationAction, windowFeatures: WKWindowFeatures) -> WKWebView? {
        // Keep the supplied configuration so window.opener and login popups work.
        guard context?.isLoaded == true, let opener = browserTabs.first(where: { $0.view === webView }) else { return nil }
        let tab = addTab(configuration: configuration)
        tab.opener = opener
        return tab.view
    }
    func webViewDidClose(_ webView: WKWebView) {
        guard let index = browserTabs.firstIndex(where: { $0.view === webView }), index > 0 else { return }
        let old = browserTabs.remove(at: index)
        windows = browserTabs
        discardPage(old)
        controller.didCloseTab(old)
        if let tab = old.opener ?? browserTabs.first {
            controller.didActivateTab(tab, previousActiveTab: old)
            show(tab)
        }
    }
    func webView(_ webView: WKWebView, decidePolicyFor navigationAction: WKNavigationAction,
                 decisionHandler: @escaping (WKNavigationActionPolicy) -> Void) {
        guard let url = navigationAction.request.url else { decisionHandler(.cancel); return }
        let allowed = ["https", "http", "about", "blob", context?.baseURL.scheme].compactMap { $0 }
        if navigationAction.targetFrame?.isMainFrame == true,
           let tab = browserTabs.first(where: { $0.view === webView }), allowed.contains(url.scheme ?? "") {
            if isExtensionURL(url) != tab.isExtensionPage {
                decisionHandler(.cancel)
                navigate(url, in: tab)
                return
            }
            tab.lastRequestedURL = url
        }
        if !allowed.contains(url.scheme ?? "") {
            // Custom schemes (including tel/mailto and native social apps) must
            // never escape the protected browser, even after a user confirmation.
            decisionHandler(.cancel)
            return
        }
        if navigationAction.shouldPerformDownload { decisionHandler(.download); return }
        if navigationAction.targetFrame?.isMainFrame == true,
           let tab = browserTabs.first(where: { $0.view === webView }) {
            tab.requestMethod = navigationAction.request.httpMethod ?? "GET"
            // A load issued below arrives as .other. Consume its one-shot marker
            // rather than recursively cancelling the same native load.
            let isInAppLoad = navigationAction.navigationType == .other && tab.pendingInAppURL == url
            tab.pendingInAppURL = nil
            if isInAppLoad { decisionHandler(.allow); return }
            if navigationAction.navigationType == .other,
               WebAppNavigationPolicy.loadsCrossHostNavigationInApp(
                    from: navigationAction.sourceFrame.request.url, to: url, method: tab.requestMethod) {
                decisionHandler(.cancel)
                tab.pendingInAppURL = url
                webView.load(navigationAction.request)
                return
            }
            // Only ordinary clicked links leave the primary page. Redirects and form
            // submissions stay in their original browsing context for authentication.
            if tab === browserTabs.first, navigationAction.navigationType == .linkActivated,
               WebAppNavigationPolicy.opensTemporaryWindow(from: navigationAction.sourceFrame.request.url,
                                                           to: url, service: service) {
                decisionHandler(.cancel)
                let temporary = addTab(configuration: websiteConfiguration())
                temporary.view.load(navigationAction.request)
                return
            }
        }
        if WebAppNavigationPolicy.loadsClickedLinkInApp(url,
                method: navigationAction.request.httpMethod ?? "GET",
                isLink: navigationAction.navigationType == .linkActivated,
                isMainOrNewWindow: navigationAction.targetFrame == nil || navigationAction.targetFrame?.isMainFrame == true) {
            decisionHandler(.cancel)
            let destination = navigationAction.targetFrame == nil
                ? addTab(configuration: websiteConfiguration()).view : webView
            destination.load(navigationAction.request)
            return
        }
        decisionHandler(.allow)
    }
    func webView(_ webView: WKWebView, didStartProvisionalNavigation navigation: WKNavigation!) {
        if webView === activeView { failure = nil }
        runtime.requestVerification(force: true)
    }
    func webView(_ webView: WKWebView, didFailProvisionalNavigation navigation: WKNavigation!, withError error: Error) { navigationFailed(webView, error) }
    func webView(_ webView: WKWebView, didFail navigation: WKNavigation!, withError error: Error) { navigationFailed(webView, error) }
    private func navigationFailed(_ webView: WKWebView, _ error: Error) {
        webView.scrollView.refreshControl?.endRefreshing()
        guard webView === activeView else { return }
        let navigationError = error as NSError
        // WebKit reports a policy interruption when we intentionally keep an
        // app link/redirect inside this browser or cancel a native-app launch.
        // The current page is still usable; do not cover it with a network error.
        if (navigationError.domain == NSURLErrorDomain && navigationError.code == NSURLErrorCancelled)
            || (navigationError.domain == "WebKitErrorDomain" && navigationError.code == 102) { return }
        #if DEBUG
        if ProcessInfo.processInfo.arguments.contains("--web-apps-diagnostics") {
            print("[WebApps] navigation error: \((error as NSError).domain) \((error as NSError).code)")
        }
        #endif
        failure = String(localized: "The page could not load. Check your connection and try again.", table: "WebApps")
        loading = false
    }
    func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) {
        webView.scrollView.refreshControl?.endRefreshing()
        if let main = browserTabs.first, main.view === webView {
            if let url = webView.url.flatMap({ service.restorableURL($0, method: main.requestMethod) }) {
                UserDefaults.standard.set(url, forKey: restorationKey)
            } else { clearRestoration() }
        }
        runtime.requestVerification(force: true)
    }
    func webViewWebContentProcessDidTerminate(_ webView: WKWebView) {
        webView.scrollView.refreshControl?.endRefreshing()
        // Do not replay POST or authentication on crash recovery.
        guard let tab = browserTabs.first(where: { $0.view === webView }) else { return }
        let destination = webView.url.flatMap { service.restorableURL($0, method: tab.requestMethod) } ?? service.url
        runtime.requestVerification(force: true)
        navigate(destination, in: tab)
    }

    func webView(_ webView: WKWebView, decidePolicyFor navigationResponse: WKNavigationResponse,
                 decisionHandler: @escaping (WKNavigationResponsePolicy) -> Void) {
        decisionHandler(navigationResponse.canShowMIMEType ? .allow : .download)
    }
    func webView(_ webView: WKWebView, navigationAction: WKNavigationAction, didBecome download: WKDownload) { downloads.add(download) }
    func webView(_ webView: WKWebView, navigationResponse: WKNavigationResponse, didBecome download: WKDownload) { downloads.add(download) }

    func webView(_ webView: WKWebView, requestMediaCapturePermissionFor origin: WKSecurityOrigin,
                 initiatedByFrame frame: WKFrameInfo, type: WKMediaCaptureType,
                 decisionHandler: @escaping (WKPermissionDecision) -> Void) {
        guard frame.isMainFrame, origin.protocol == "https", webView === activeView,
              runtime.focused === self, webView.window?.windowScene?.activationState == .foregroundActive else {
            decisionHandler(.deny); return
        }
        decisionHandler(.prompt)
    }

    @available(iOS 27.0, *)
    func webView(_ webView: WKWebView, requestGeolocationPermissionFor origin: WKSecurityOrigin,
                 initiatedByFrame frame: WKFrameInfo, decisionHandler: @escaping (WKPermissionDecision) -> Void) {
        decisionHandler(.deny)
    }

    func webView(_ webView: WKWebView, requestDeviceOrientationAndMotionPermissionFor origin: WKSecurityOrigin,
                 initiatedByFrame frame: WKFrameInfo, decisionHandler: @escaping (WKPermissionDecision) -> Void) {
        decisionHandler(.deny)
    }

    func webView(_ webView: WKWebView, contextMenuConfigurationFor elementInfo: WKContextMenuElementInfo,
                 completionHandler: @escaping (UIContextMenuConfiguration?) -> Void) {
        // The system link menu can offer to open the native app or another
        // browser. The address menu provides an explicit copy action.
        completionHandler(nil)
    }

    private func presentDialog(_ alert: UIAlertController, in view: WKWebView, fallback: () -> Void) {
        guard var presenter = view.window?.rootViewController else { fallback(); return }
        while let next = presenter.presentedViewController { presenter = next }
        presenter.present(alert, animated: true)
    }
    func webView(_ webView: WKWebView, runJavaScriptAlertPanelWithMessage message: String,
                 initiatedByFrame frame: WKFrameInfo, completionHandler: @escaping () -> Void) {
        let alert = UIAlertController(title: frame.securityOrigin.host, message: message, preferredStyle: .alert)
        alert.addAction(UIAlertAction(title: String(localized: "OK"), style: .default) { _ in completionHandler() })
        presentDialog(alert, in: webView, fallback: completionHandler)
    }
    func webView(_ webView: WKWebView, runJavaScriptConfirmPanelWithMessage message: String,
                 initiatedByFrame frame: WKFrameInfo, completionHandler: @escaping (Bool) -> Void) {
        let alert = UIAlertController(title: frame.securityOrigin.host, message: message, preferredStyle: .alert)
        alert.addAction(UIAlertAction(title: String(localized: "Cancel"), style: .cancel) { _ in completionHandler(false) })
        alert.addAction(UIAlertAction(title: String(localized: "OK"), style: .default) { _ in completionHandler(true) })
        presentDialog(alert, in: webView) { completionHandler(false) }
    }
    func webView(_ webView: WKWebView, runJavaScriptTextInputPanelWithPrompt prompt: String, defaultText: String?,
                 initiatedByFrame frame: WKFrameInfo, completionHandler: @escaping (String?) -> Void) {
        let alert = UIAlertController(title: frame.securityOrigin.host, message: prompt, preferredStyle: .alert)
        alert.addTextField { $0.text = defaultText }
        alert.addAction(UIAlertAction(title: String(localized: "Cancel"), style: .cancel) { _ in completionHandler(nil) })
        alert.addAction(UIAlertAction(title: String(localized: "OK"), style: .default) { [weak alert] _ in completionHandler(alert?.textFields?.first?.text) })
        presentDialog(alert, in: webView) { completionHandler(nil) }
    }
    private enum BrowserError: Error { case extensionMissing, bridgeUnavailable }
}

@available(iOS 18.4, *)
private struct BrowserWebView: UIViewRepresentable {
    let webView: WKWebView
    func makeUIView(context: Context) -> WKWebView { webView }
    func updateUIView(_ uiView: WKWebView, context: Context) {}
}

@available(iOS 18.4, *)
struct WebAppBrowserScreen: View {
    @StateObject private var browser: WebAppBrowser
    @ObservedObject private var runtime: WebAppProfileRuntime
    @Environment(\.dismiss) private var dismiss
    @State private var attempt = 0
    @State private var blockingSettingsService: WebAppService?
    init(service: WebAppService) {
        let runtime = WebAppProfileRuntime.shared(service.profile)
        _runtime = ObservedObject(wrappedValue: runtime)
        _browser = StateObject(wrappedValue: runtime.session(service))
        #if DEBUG && targetEnvironment(simulator)
        _blockingSettingsService = State(initialValue: ProcessInfo.processInfo.arguments.contains("--preview-web-app-settings") ? service : nil)
        #endif
    }

    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: 0) {
                Button { dismiss() } label: { Image(systemName: "xmark").frame(width: 44, height: 44).contentShape(Rectangle()) }
                    .accessibilityLabel(String(localized: "Close"))
                Menu {
                    Button {
                        browser.copyCurrentLink()
                    } label: {
                        Label(String(localized: "Copy link", table: "WebApps"), systemImage: "doc.on.doc")
                    }
                } label: {
                    VStack(spacing: 2) {
                        HStack(spacing: 4) {
                            Text(browser.currentHost.isEmpty ? browser.service.url.host! : browser.currentHost)
                                .font(.subheadline.weight(.semibold)).lineLimit(1).truncationMode(.middle)
                            Image(systemName: "chevron.down").font(.caption2).accessibilityHidden(true)
                        }
                        Text(protectionLabel).font(.caption2).foregroundStyle(.secondary)
                    }.frame(maxWidth: .infinity, minHeight: 44).contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .disabled(browser.copyableURL == nil)
                .accessibilityIdentifier("webapps.address")
                Button { blockingSettingsService = currentService } label: {
                    Image(systemName: "slider.horizontal.3").frame(width: 44, height: 44).contentShape(Rectangle())
                }
                .disabled(currentService == nil)
                .accessibilityLabel(String(localized: "Blocking settings", table: "WebApps"))
            }.font(.system(size: 17)).padding(.horizontal, 4).background(.regularMaterial)
            ZStack {
                if let view = browser.activeView {
                    BrowserWebView(webView: view).id(ObjectIdentifier(view))
                        .opacity(browser.failure == nil && runtime.protection != .failed ? 1 : 0)
                        .accessibilityHidden(browser.failure != nil || runtime.protection == .failed)
                }
                if let failure = browser.failure ?? (runtime.protection == .failed ? String(localized: "Blocking could not be verified. Restore protection to continue.", table: "WebApps") : nil) {
                    VStack(spacing: 20) {
                        Image(systemName: "exclamationmark.shield").font(.largeTitle)
                        Text(failure).multilineTextAlignment(.center)
                        Button(String(localized: "Try again", table: "WebApps")) {
                            runtime.prepareRecovery()
                            attempt += 1
                        }.buttonStyle(.borderedProminent)
                    }.padding(32).frame(maxWidth: .infinity, maxHeight: .infinity).background(SlowthAppearance.background)
                } else if browser.loading {
                    ProgressView().padding(12).background(.regularMaterial, in: Capsule()).frame(maxHeight: .infinity, alignment: .top)
                }
            }.frame(maxWidth: .infinity, maxHeight: .infinity)
        }
        .ignoresSafeArea(.container, edges: .bottom)
        .background(SlowthAppearance.background).tint(SlowthAppearance.sage)
        .sheet(item: $blockingSettingsService) { service in
            WebAppBlockingSettings(service: service)
                .presentationDragIndicator(.visible)
        }
        .task(id: attempt) { await browser.start() }
        .onReceive(WebAppsRouter.shared.$websiteURL) { url in
            if url != nil { Task { @MainActor in browser.openRequestedWebsite() } }
        }
        .onDisappear { browser.suspend() }
    }
    private var protectionLabel: String {
        switch runtime.protection {
        case .starting: return String(localized: "Starting protection…", table: "WebApps")
        case .working: return String(localized: "Settings applied", table: "WebApps")
        case .recovering: return String(localized: "Verifying protection…", table: "WebApps")
        case .failed: return String(localized: "Protection unavailable", table: "WebApps")
        }
    }
    private var currentService: WebAppService? {
        guard let url = browser.activeView?.url else { return browser.service }
        return WebAppService.containing(url)
    }

}

@available(iOS 18.4, *)
struct WebAppBlockingSettings: View {
    @StateObject private var state = AppState()
    @Environment(\.dismiss) private var dismiss
    @Environment(\.dynamicTypeSize) private var dynamicTypeSize
    @ScaledMetric(relativeTo: .body) private var rowHeight = 54.0
    @ScaledMetric(relativeTo: .caption) private var noteHeight = 56.0
    let service: WebAppService

    private var compactHeight: CGFloat {
        84 + rowHeight * Double(SiteBlockingControl.controls(for: service.id).count + 1) + 10
            + (service == .instagram ? noteHeight : 24)
    }

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    Link(destination: service.shortcutURL) {
                        Label(String(localized: "Add to Home Screen", table: "WebApps"), systemImage: "square.and.arrow.up")
                    }
                    .accessibilityIdentifier("webapps.shortcut." + service.id)
                }
                .listRowBackground(SlowthAppearance.card)
                SafariSiteSettingsSections(state: state, expandedService: .constant(nil), onlySite: service.id)
                    .disabled(state.groupSelectionRestSeconds > 0)
                    .listRowBackground(SlowthAppearance.card)
            }
            .scrollContentBackground(.hidden)
            .listSectionSpacing(.custom(10))
            .contentMargins(.top, 8, for: .scrollContent)
            .environment(\.defaultMinListRowHeight, 48)
            .onAppear { state.reload() }
            .background(SlowthAppearance.background)
            .navigationTitle(service.title)
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .principal) {
                    HStack(spacing: 8) {
                        Image(service.icon)
                            .resizable().renderingMode(.original).scaledToFit()
                            .frame(width: 24, height: 24)
                            .clipShape(RoundedRectangle(cornerRadius: 5, style: .continuous))
                            .accessibilityHidden(true)
                        Text(service.title).font(.headline)
                    }
                    .accessibilityAddTraits(.isHeader)
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button(String(localized: "Close")) { dismiss() }
                }
            }
            .alert(String(localized: "Heads up"), isPresented: Binding(
                get: { state.lastError != nil },
                set: { if !$0 { state.lastError = nil } }
            )) {
                Button(String(localized: "OK"), role: .cancel) { state.lastError = nil }
            } message: { Text(state.lastError ?? "") }
        }
        .tint(SlowthAppearance.sage)
        .presentationDetents(dynamicTypeSize.isAccessibilitySize ? [.large] : [.height(compactHeight), .large])
    }
}
