import Foundation
import SwiftUI
import SafariServices
#if os(iOS)
import UIKit
#elseif os(macOS)
import AppKit
#endif

enum ForceRefreshOutcome {
    case updated
    case notModified
    case failed(String)
}

@MainActor
final class AppState: ObservableObject {

    @Published private(set) var snapshot: SharedState = SharedStore.snapshot()
    @Published private(set) var rulesEtag: String? = SharedStore.rulesEtag()
    @Published private(set) var rulesLastAttemptAt: Date? = SharedStore.rulesLastAttemptAt()

    @Published var lastError: String? = nil
    @Published var refreshing: Bool = false
    @Published var lastRefreshOutcome: ForceRefreshOutcome? = nil

    private var observer: NSObjectProtocol?
    private var tickTimer: Timer?

    init() {
        #if os(iOS)
        let foregroundName = UIApplication.willEnterForegroundNotification
        #elseif os(macOS)
        let foregroundName = NSApplication.didBecomeActiveNotification
        #endif
        observer = NotificationCenter.default.addObserver(
            forName: foregroundName,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            Task { @MainActor in self?.reload() }
        }
        tickTimer = Timer.scheduledTimer(withTimeInterval: 30, repeats: true) { [weak self] _ in
            Task { @MainActor in self?.objectWillChange.send() }
        }
    }

    deinit {
        if let o = observer { NotificationCenter.default.removeObserver(o) }
        tickTimer?.invalidate()
    }

    func reload() {
        snapshot = SharedStore.snapshot()
        rulesEtag = SharedStore.rulesEtag()
        rulesLastAttemptAt = SharedStore.rulesLastAttemptAt()
    }

    func mode(for site: String) -> SiteMode {
        snapshot.toggles[site] ?? .off
    }

    func setMode(_ mode: SiteMode, for site: String) {
        do {
            _ = try SharedStore.setToggle(site: site, mode: mode)
            reload()
        } catch SharedStoreError.strictModeActive {
            lastError = "Strict mode is active"
            reload()
        } catch {
            lastError = "Could not save"
        }
    }

    func setStrictMode(_ enabled: Bool) {
        do {
            _ = try SharedStore.setStrictMode(enabled)
            reload()
        } catch SharedStoreError.strictModeActive {
            lastError = "Strict mode cannot be turned off until it expires"
            reload()
        } catch {
            lastError = "Could not save"
        }
    }

    func dismissOnboarding() {
        SharedStore.setOnboardingDone(true)
        reload()
    }

    func showOnboardingAgain() {
        SharedStore.setOnboardingDone(false)
        reload()
    }

    #if os(iOS)
    func openSystemSettings() {
        if let url = URL(string: UIApplication.openSettingsURLString) {
            UIApplication.shared.open(url)
        }
    }

    func openSafariExtensionSettings() {
        if #available(iOS 18.3, *),
           let url = URL(string: UIApplication.openDefaultApplicationsSettingsURLString) {
            UIApplication.shared.open(url)
            return
        }
        if let url = URL(string: UIApplication.openSettingsURLString) {
            UIApplication.shared.open(url)
        }
    }
    #elseif os(macOS)
    func openSystemSettings() {
        openSafariExtensionSettings()
    }

    func openSafariExtensionSettings() {
        let bundleID = (Bundle.main.bundleIdentifier ?? "com.unscroll.local.mac") + ".Extension"
        SFSafariApplication.showPreferencesForExtension(withIdentifier: bundleID, completionHandler: nil)
    }
    #endif

    func forceRefresh() async {
        guard !refreshing else { return }
        refreshing = true
        defer { refreshing = false }

        guard let url = URL(string: AppState.rulesURL) else {
            lastRefreshOutcome = .failed("no_url")
            return
        }
        SharedStore.setRulesLastAttemptAt(Date())
        rulesLastAttemptAt = SharedStore.rulesLastAttemptAt()

        var req = URLRequest(url: url, cachePolicy: .reloadIgnoringLocalCacheData, timeoutInterval: 5)
        if let etag = SharedStore.rulesEtag(), !etag.isEmpty {
            req.setValue(etag, forHTTPHeaderField: "If-None-Match")
        }

        do {
            let (data, response) = try await URLSession.shared.data(for: req)
            guard let http = response as? HTTPURLResponse else {
                lastRefreshOutcome = .failed("no_response")
                return
            }
            if http.statusCode == 304 {
                lastRefreshOutcome = .notModified
                reload()
                return
            }
            guard (200..<300).contains(http.statusCode) else {
                lastRefreshOutcome = .failed("http_\(http.statusCode)")
                return
            }
            try SharedStore.saveRules(json: data, etag: http.value(forHTTPHeaderField: "Etag"))
            lastRefreshOutcome = .updated
            reload()
        } catch SharedStoreError.strictModeActive {
            lastRefreshOutcome = .failed("strict")
        } catch {
            lastRefreshOutcome = .failed("network_error")
        }
    }

    private static let rulesURL =
        "https://gist.githubusercontent.com/skar404/485fdd43d2d94b068a6869fa0670fce9/raw/unscroll_v0.json"
}
