import SwiftUI
import WebKit

/// Exactly one controller/context per profile, including both Meta service sessions.
@available(iOS 18.4, *)
@MainActor
final class WebAppProfileRuntime: NSObject, ObservableObject, WKWebExtensionControllerDelegate {
    private static var clearingAllData: Task<Void, Error>?
    private static var profiles: [WebAppProfile: WebAppProfileRuntime] = [:]
    static func shared(_ profile: WebAppProfile) -> WebAppProfileRuntime {
        if let existing = profiles[profile] { return existing }
        let runtime = WebAppProfileRuntime(profile)
        profiles[profile] = runtime
        return runtime
    }

    let profile: WebAppProfile
    let dataStore: WKWebsiteDataStore
    let controller: WKWebExtensionController
    private(set) var trackingRules: WKContentRuleList?
    private(set) var context: WKWebExtensionContext?
    @Published private(set) var protection = WebAppProtectionState.starting
    private var sessions: [WebAppService: WebAppBrowser] = [:]
    weak var focused: WebAppBrowser?
    private var startup: Task<Void, Error>?
    private var startupGeneration = UUID()
    private var port: WKWebExtension.MessagePort?
    private var bridgeReady = false
    private var revision = UUID().uuidString
    private var pendingSince: Date?
    private var observers: [NSObjectProtocol] = []
    private var watchdog: Task<Void, Never>?

    private init(_ profile: WebAppProfile) {
        self.profile = profile
        dataStore = WKWebsiteDataStore(forIdentifier: profile.identifier)
        let configuration = WKWebExtensionController.Configuration(identifier: profile.identifier)
        configuration.defaultWebsiteDataStore = dataStore
        controller = WKWebExtensionController(configuration: configuration)
        super.init()
        controller.delegate = self
        for name in [Notification.Name.slowthWebSettingsChanged, UIApplication.didBecomeActiveNotification] {
            observers.append(NotificationCenter.default.addObserver(forName: name, object: nil, queue: .main) { [weak self] _ in
                Task { @MainActor in self?.requestVerification(force: true) }
            })
        }
    }

    func session(_ service: WebAppService) -> WebAppBrowser {
        if let browser = sessions[service] { return browser }
        let browser = WebAppBrowser(service: service, runtime: self)
        sessions[service] = browser
        if context?.isLoaded == true { controller.didOpenWindow(browser) }
        return browser
    }

    func start() async throws {
        if let clearing = Self.clearingAllData { try await clearing.value }
        if let startup { return try await startup.value }
        if context?.isLoaded == true, bridgeReady, port?.isDisconnected == false { return }
        let generation = UUID()
        startupGeneration = generation
        let task = Task { @MainActor in
            self.protection = .starting
            self.port?.messageHandler = nil
            self.port?.disconnectHandler = nil
            self.port?.disconnect()
            self.port = nil
            if let context = self.context { try? self.controller.unload(context) }
            self.bridgeReady = false
            guard let plugins = Bundle.main.builtInPlugInsURL,
                  let bundle = try FileManager.default.contentsOfDirectory(at: plugins, includingPropertiesForKeys: nil)
                    .compactMap({ Bundle(url: $0) }).first(where: {
                        $0.bundleIdentifier == (Bundle.main.bundleIdentifier ?? "") + ".Extension"
                    }) else { throw RuntimeError.extensionMissing }
            if self.trackingRules == nil {
                self.trackingRules = try await WebAppTrackingProtection.compile()
            }
            let webExtension = try await WKWebExtension(appExtensionBundle: bundle)
            try Task.checkCancellation()
            guard self.startupGeneration == generation else { throw CancellationError() }
            let context = WKWebExtensionContext(for: webExtension)
            context.uniqueIdentifier = "slowth.web-apps.v2." + self.profile.rawValue
            context.baseURL = URL(string: "webkit-extension://slowth-" + self.profile.rawValue + "/")!
            for permission in webExtension.requestedPermissions { context.setPermissionStatus(.grantedExplicitly, for: permission) }
            for pattern in webExtension.requestedPermissionMatchPatterns { context.setPermissionStatus(.grantedExplicitly, for: pattern) }
            self.context = context
            try self.controller.load(context)
            try await self.loadBackgroundContent(context)
            try Task.checkCancellation()
            for _ in 0..<100 {
                if self.bridgeReady && self.port?.isDisconnected == false { break }
                try await Task.sleep(for: .milliseconds(100))
            }
            guard self.bridgeReady, self.port?.isDisconnected == false else { throw RuntimeError.bridgeUnavailable }
            self.requestVerification(force: true)
        }
        startup = task
        defer { if startupGeneration == generation { startup = nil } }
        do { try await task.value }
        catch {
            if startupGeneration == generation { protection = .failed }
            throw error
        }
    }

    private func loadBackgroundContent(_ context: WKWebExtensionContext) async throws {
        // WebKit may never complete the callback after an unload/process exit.
        // Polling a callback result keeps recovery cancellation and timeout bounded
        // without waiting for a cancelled child task to finish inside WebKit.
        var result: Result<Void, Error>?
        context.loadBackgroundContent { error in
            result = error.map { .failure($0) } ?? .success(())
        }
        for _ in 0..<300 {
            try Task.checkCancellation()
            if let result { return try result.get() }
            try await Task.sleep(for: .milliseconds(100))
        }
        throw RuntimeError.bridgeUnavailable
    }

    func setVisible(_ browser: WebAppBrowser, _ isVisible: Bool) {
        if isVisible {
            focused = browser
        } else {
            guard focused === browser else { return }
            focused = nil
        }
        watchdog?.cancel()
        guard isVisible else { return }
        requestVerification(force: true)
        watchdog = Task { @MainActor [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(for: .seconds(3))
                guard !Task.isCancelled, let self else { return }
                self.requestVerification()
            }
        }
    }

    func requestVerification(force: Bool = false) {
        guard context?.isLoaded == true else {
            if context != nil {
                revision = UUID().uuidString
                protection = .failed
            }
            return
        }
        guard let port, !port.isDisconnected else {
            protection = .failed
            return
        }
        if force || pendingSince == nil {
            revision = UUID().uuidString
            pendingSince = Date()
            if force { protection = .recovering }
        } else if Date().timeIntervalSince(pendingSince!) > 12 {
            protection = .failed
        }
        port.sendMessage(["type": "verify", "revision": revision]) { [weak self] error in
            if error != nil { self?.protection = .failed }
        }
    }

    static var websiteDataTypesToClear: Set<String> {
        var types = WKWebsiteDataStore.allWebsiteDataTypes()
        if #available(iOS 26.0, *) {
            // Screen Time is system usage history, not a website login/cache.
            // Asking WebKit to delete it invokes ScreenTimeSettings, which can
            // stall an unregistered browser (including the unsigned CI host).
            types.remove(WKWebsiteDataTypeScreenTime)
        }
        return types
    }

    static func clearAllData() async throws {
        if let clearingAllData { return try await clearingAllData.value }
        let task = Task { @MainActor in
            let runtimes = WebAppProfile.allCases.map { shared($0) }
            // Unload every background extension before deleting its storage.
            for runtime in runtimes { runtime.prepareRecovery() }
            for runtime in runtimes { await runtime.clearData() }
            // Include sign-ins retained from the browser's earlier shared store.
            await WKWebsiteDataStore.default().removeData(
                ofTypes: websiteDataTypesToClear, modifiedSince: .distantPast)
            let downloads = FileManager.default.temporaryDirectory.appendingPathComponent("SlowthDownloads", isDirectory: true)
            if FileManager.default.fileExists(atPath: downloads.path) {
                try FileManager.default.removeItem(at: downloads)
            }
        }
        clearingAllData = task
        defer { clearingAllData = nil }
        try await task.value
    }

    func clearData() async {
        // Stop every page first, including the other Meta session, to prevent cookie recreation.
        for browser in sessions.values {
            browser.stop(); browser.clearRestoration()
            await browser.downloads.clear()
        }
        // Saved destinations also exist for services not opened in this process.
        for service in WebAppService.allCases where service.profile == profile {
            UserDefaults.standard.removeObject(forKey: "webapps.last-url.v2." + service.id)
        }
        await dataStore.removeData(ofTypes: Self.websiteDataTypesToClear, modifiedSince: .distantPast)
        let types = WKWebExtensionController.allExtensionDataTypes
        let records = await controller.dataRecords(ofTypes: types)
        await controller.removeData(ofTypes: types, from: records)
        resetPermissions()
    }

    func resetPermissions() {
        // Permission decisions are deliberately never persisted by Slowth. Recreate views
        // to discard WebKit's per-page decisions; OS-level grants remain in Settings.
        for browser in sessions.values { browser.stop() }
    }

    func prepareRecovery() {
        startup?.cancel()
        startup = nil
        startupGeneration = UUID()
        for browser in sessions.values { browser.stop() }
        port?.messageHandler = nil
        port?.disconnectHandler = nil
        port?.disconnect()
        port = nil
        if let context { try? controller.unload(context) }
        context = nil
        bridgeReady = false
        pendingSince = nil
        protection = .recovering
    }

    func webExtensionController(_ controller: WKWebExtensionController, openWindowsFor context: WKWebExtensionContext) -> [any WKWebExtensionWindow] {
        Array(sessions.values)
    }
    func webExtensionController(_ controller: WKWebExtensionController, focusedWindowFor context: WKWebExtensionContext) -> (any WKWebExtensionWindow)? { focused }
    func webExtensionController(_ controller: WKWebExtensionController, sendMessage message: Any,
                                toApplicationWithIdentifier applicationIdentifier: String?, for extensionContext: WKWebExtensionContext,
                                replyHandler: @escaping (Any?, Error?) -> Void) {
        guard extensionContext === context, let payload = message as? [String: Any] else {
            replyHandler(nil, RuntimeError.bridgeUnavailable); return
        }
        var reply = NativeExtensionMessageHandler.handle(payload: payload)
        if payload["action"] as? String == "getState", reply["ok"] as? Bool == true {
            bridgeReady = true
            reply["webAppHost"] = true
        }
        replyHandler(reply, nil)
    }
    func webExtensionController(_ controller: WKWebExtensionController, connectUsing port: WKWebExtension.MessagePort,
                                for extensionContext: WKWebExtensionContext, completionHandler: @escaping (Error?) -> Void) {
        guard extensionContext === context, port.applicationIdentifier == "slowth.web-apps" else {
            completionHandler(RuntimeError.bridgeUnavailable); return
        }
        self.port?.disconnectHandler = nil
        self.port?.disconnect()
        self.port = port
        port.messageHandler = { [weak self] message, error in
            guard let self else { return }
            guard self.context?.isLoaded == true, error == nil, let message = message as? [String: Any],
                  message["type"] as? String == "verified", message["revision"] as? String == self.revision else { return }
            if message["ok"] as? Bool == true {
                self.pendingSince = nil
                self.protection = .working
            } else {
                self.protection = self.pendingSince.map { Date().timeIntervalSince($0) > 12 } == true ? .failed : .recovering
            }
        }
        port.disconnectHandler = { [weak self] _ in self?.protection = .failed }
        completionHandler(nil)
    }
    func webExtensionController(_ controller: WKWebExtensionController, openNewTabUsing configuration: WKWebExtension.TabConfiguration,
                                for context: WKWebExtensionContext, completionHandler: @escaping ((any WKWebExtensionTab)?, Error?) -> Void) {
        guard let focused else { completionHandler(nil, RuntimeError.bridgeUnavailable); return }
        let tab = focused.addTab(configuration: focused.websiteConfiguration())
        if let url = configuration.url { focused.navigate(url, in: tab) }
        completionHandler(tab, nil)
    }
    enum RuntimeError: Error { case extensionMissing, bridgeUnavailable }
}
