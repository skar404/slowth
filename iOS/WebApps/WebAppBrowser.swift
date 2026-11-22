import SwiftUI
import WebKit
import AuthenticationServices
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
        guard startToken == nil else { return }
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
        // Keep the main page and its history. Temporary login windows are retained too,
        // so dismissing the screen never silently cancels an in-progress sign-in.
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
        observations.removeAll()
        for tab in browserTabs {
            tab.view.stopLoading()
            tab.view.navigationDelegate = nil; tab.view.uiDelegate = nil
            controller.didCloseTab(tab, windowIsClosing: true)
        }
        browserTabs.removeAll(); windows = []; activeView = nil
    }
    func clearRestoration() { UserDefaults.standard.removeObject(forKey: restorationKey) }

    func addTab(configuration: WKWebViewConfiguration) -> WebAppTab {
        configuration.webExtensionController = controller
        let view = WKWebView(frame: .zero, configuration: configuration)
        view.allowsBackForwardNavigationGestures = true
        view.allowsLinkPreview = false
        view.navigationDelegate = self; view.uiDelegate = self
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
        guard let config = extensionPage ? context.webViewConfiguration : WKWebViewConfiguration() else { return }
        config.webExtensionController = controller
        if !extensionPage { config.websiteDataStore = runtime.dataStore; config.allowsInlineMediaPlayback = true; config.allowsPictureInPictureMediaPlayback = true }
        let view = WKWebView(frame: .zero, configuration: config)
        view.allowsBackForwardNavigationGestures = true
        view.allowsLinkPreview = false
        view.navigationDelegate = self; view.uiDelegate = self
        let replacement = WebAppTab(view: view, owner: self, isExtensionPage: extensionPage)
        replacement.opener = tab.opener
        replacement.lastRequestedURL = url
        let active = activeView === tab.view
        tab.view.navigationDelegate = nil; tab.view.uiDelegate = nil
        tab.view.stopLoading()
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
        guard context?.isLoaded == true else { return nil }
        let opener = browserTabs.first { $0.view === webView }
        let tab = addTab(configuration: configuration)
        tab.opener = opener
        return tab.view
    }
    func webViewDidClose(_ webView: WKWebView) {
        guard let index = browserTabs.firstIndex(where: { $0.view === webView }), index > 0 else { return }
        let old = browserTabs.remove(at: index)
        windows = browserTabs
        old.view.navigationDelegate = nil; old.view.uiDelegate = nil
        old.view.stopLoading()
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
        if let main = browserTabs.first, main.view === webView {
            if let url = webView.url.flatMap({ service.restorableURL($0, method: main.requestMethod) }) {
                UserDefaults.standard.set(url, forKey: restorationKey)
            } else { clearRestoration() }
        }
        runtime.requestVerification(force: true)
    }
    func webViewWebContentProcessDidTerminate(_ webView: WKWebView) {
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
        // WebKit's system prompt names the requesting origin. Never silently grant
        // camera/microphone, including cross-origin frames or previously denied sites.
        guard origin.protocol == "https", webView.window != nil else { decisionHandler(.deny); return }
        decisionHandler(.prompt)
    }

    func webView(_ webView: WKWebView, contextMenuConfigurationFor elementInfo: WKContextMenuElementInfo,
                 completionHandler: @escaping (UIContextMenuConfiguration?) -> Void) {
        // The system link menu can offer to open the native app or another
        // browser. The browser bar still provides explicit copy/share actions.
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
    @State private var showBlockingSettings = false
    @State private var showDownloads = false
    @State private var confirmClear = false
    @State private var confirmReset = false
    @State private var passkeyMessage: String?
    @State private var clearing = false
    init(service: WebAppService) {
        let runtime = WebAppProfileRuntime.shared(service.profile)
        _runtime = ObservedObject(wrappedValue: runtime)
        _browser = StateObject(wrappedValue: runtime.session(service))
        #if DEBUG && targetEnvironment(simulator)
        _showBlockingSettings = State(initialValue: ProcessInfo.processInfo.arguments.contains("--preview-web-app-settings"))
        #endif
    }

    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: 0) {
                Button { browser.back() } label: { Image(systemName: "chevron.left").frame(width: 44, height: 44).contentShape(Rectangle()) }
                    .disabled(!browser.canGoBack).accessibilityLabel(String(localized: "Back", table: "WebApps"))
                VStack(spacing: 2) {
                    Text(browser.currentHost.isEmpty ? browser.service.url.host! : browser.currentHost)
                        .font(.subheadline.weight(.semibold)).lineLimit(1).truncationMode(.middle)
                    Text(protectionLabel).font(.caption2).foregroundStyle(.secondary)
                }.frame(maxWidth: .infinity).accessibilityElement(children: .combine)
                Menu {
                    Button(String(localized: "Forward", table: "WebApps"), systemImage: "chevron.right") { browser.forward() }
                        .disabled(!browser.canGoForward)
                    Button(String(localized: "Home", table: "WebApps"), systemImage: "house") { browser.home() }
                    if browser.loading {
                        Button(String(localized: "Stop loading", table: "WebApps"), systemImage: "xmark") { browser.activeView?.stopLoading() }
                    }
                    Menu(String(localized: "Windows", table: "WebApps")) {
                        ForEach(browser.windows, id: \.self) { tab in
                            Button(tab.view.url?.host ?? browser.service.title) { browser.select(tab) }
                        }
                        Button(String(localized: "Close window", table: "WebApps"), systemImage: "xmark") { browser.closeWindow() }
                            .disabled(!browser.canCloseWindow)
                    }
                    Button(String(localized: "Downloads", table: "WebApps"), systemImage: "arrow.down.circle") { showDownloads = true }
                    Button(String(localized: "Passkey access", table: "WebApps"), systemImage: "person.badge.key") { requestPasskeys() }
                    Button(String(localized: "Reset site permissions", table: "WebApps"), systemImage: "hand.raised") {
                        confirmReset = true
                    }
                    Button(String(localized: "Clear profile data", table: "WebApps"), systemImage: "trash", role: .destructive) { confirmClear = true }
                    Button(String(localized: "Blocking settings", table: "WebApps"), systemImage: "slider.horizontal.3") {
                        showBlockingSettings = true
                    }
                    Button(String(localized: "Reload", table: "WebApps"), systemImage: "arrow.clockwise") { browser.reload() }
                    if let url = browser.activeView?.url, ["https", "http"].contains(url.scheme ?? "") {
                        ShareLink(item: url) { Label(String(localized: "Share link", table: "WebApps"), systemImage: "square.and.arrow.up") }
                        Button(String(localized: "Copy link", table: "WebApps"), systemImage: "doc.on.doc") { UIPasteboard.general.url = url }
                    }
                } label: { Image(systemName: "ellipsis.circle").frame(width: 44, height: 44).contentShape(Rectangle()) }
                    .accessibilityLabel(String(localized: "Menu", table: "WebApps"))
                Button { dismiss() } label: { Image(systemName: "xmark").frame(width: 44, height: 44).contentShape(Rectangle()) }
                    .accessibilityLabel(String(localized: "Close"))
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
        .sheet(isPresented: $showBlockingSettings) {
            WebAppBlockingSettings(service: browser.service)
        }
        .sheet(isPresented: $showDownloads) { WebAppDownloadsScreen(downloads: browser.downloads) }
        .confirmationDialog(String(localized: "Reset site permissions", table: "WebApps"), isPresented: $confirmReset, titleVisibility: .visible) {
            Button(String(localized: "Reset site permissions", table: "WebApps")) { runtime.resetPermissions(); attempt += 1 }
        } message: {
            Text(String(localized: "Pages in this profile will close. Sites will ask for camera and microphone access again. System permissions can be changed in Settings.", table: "WebApps"))
        }
        .confirmationDialog(String(localized: "Clear profile data?", table: "WebApps"), isPresented: $confirmClear, titleVisibility: .visible) {
            Button(String(localized: "Clear profile data", table: "WebApps"), role: .destructive) {
                clearing = true
                Task { await runtime.clearData(); clearing = false; attempt += 1 }
            }
        } message: {
            Text(browser.service.profile == .meta
                 ? String(localized: "This signs you out of Instagram and Facebook and closes their pages. Blocking settings stay the same.", table: "WebApps")
                 : String(localized: "This signs you out of this profile and closes its pages. Blocking settings stay the same.", table: "WebApps"))
        }
        .alert(String(localized: "Passkey access", table: "WebApps"), isPresented: Binding(get: { passkeyMessage != nil }, set: { if !$0 { passkeyMessage = nil } })) {
            Button(String(localized: "OK"), role: .cancel) { passkeyMessage = nil }
        } message: { Text(passkeyMessage ?? "") }
        .disabled(clearing)
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
    private func requestPasskeys() {
        guard Bundle.main.object(forInfoDictionaryKey: "SlowthBrowserEntitlementCandidate") as? Bool == true else {
            passkeyMessage = String(localized: "Browser passkey access is awaiting Apple approval. Web apps remain Beta.", table: "WebApps")
            return
        }
        let manager = ASAuthorizationWebBrowserPublicKeyCredentialManager()
        manager.requestAuthorizationForPublicKeyCredentials { state in
            Task { @MainActor in
                passkeyMessage = state == .authorized
                    ? String(localized: "Passkey access is enabled. Continue signing in on the website.", table: "WebApps")
                    : String(localized: "Passkey access was not enabled. You can try again or review permissions in Settings.", table: "WebApps")
            }
        }
    }

}

@available(iOS 18.4, *)
private struct WebAppBlockingSettings: View {
    @StateObject private var state = AppState()
    @State private var expandedService: String?
    @Environment(\.dismiss) private var dismiss

    init(service: WebAppService) {
        _expandedService = State(initialValue: "safari." + service.id)
    }

    var body: some View {
        NavigationStack {
            ScrollViewReader { proxy in
                Form {
                    Group {
                        SafariSiteSettingsSections(state: state, expandedService: $expandedService)
                        SafariRulesUpdateSection(state: state)
                    }
                    .disabled(state.groupSelectionRestSeconds > 0)
                    .listRowBackground(SlowthAppearance.card)
                }
                .scrollContentBackground(.hidden)
                .listSectionSpacing(.custom(10))
                .contentMargins(.top, 8, for: .scrollContent)
                .environment(\.defaultMinListRowHeight, 48)
                .onAppear {
                    state.reload()
                    if let expandedService { proxy.scrollTo(expandedService, anchor: .top) }
                }
            }
            .background(SlowthAppearance.background)
            .navigationTitle(String(localized: "Blocking settings", table: "WebApps"))
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
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
    }
}
