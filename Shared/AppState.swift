import Foundation
import SwiftUI
import SafariServices
#if os(iOS)
import UIKit
#endif
#if os(iOS) && canImport(DeviceActivity)
import DeviceActivity
#endif
#if os(macOS)
import AppKit
#endif
#if os(iOS) && canImport(FamilyControls)
import FamilyControls
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

    private var foregroundObserver: NSObjectProtocol?
    private var backgroundObserver: NSObjectProtocol?
    private var tickTimer: Timer?

    init() {
        #if os(iOS)
        let foregroundName = UIApplication.willEnterForegroundNotification
        #elseif os(macOS)
        let foregroundName = NSApplication.didBecomeActiveNotification
        #endif
        foregroundObserver = NotificationCenter.default.addObserver(
            forName: foregroundName,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            Task { @MainActor in
                #if os(iOS) && canImport(FamilyControls)
                self?.restoreRealtimeShieldAfterAppActivation()
                #else
                self?.reload()
                #endif
            }
        }
        #if os(iOS)
        backgroundObserver = NotificationCenter.default.addObserver(
            forName: UIApplication.didEnterBackgroundNotification,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            Task { @MainActor in
                #if canImport(FamilyControls)
                self?.armSoftYouTubeShieldAfterLeavingSlowth()
                #else
                self?.reload()
                #endif
            }
        }
        #endif
        tickTimer = Timer.scheduledTimer(withTimeInterval: 30, repeats: true) { [weak self] _ in
            Task { @MainActor in self?.objectWillChange.send() }
        }
        #if os(iOS) && canImport(FamilyControls)
        if UIApplication.shared.applicationState == .background {
            SharedStore.setSlowthAppForeground(false)
            armSoftYouTubeShieldAfterLeavingSlowth()
        } else {
            restoreRealtimeShieldAfterAppActivation()
        }
        #endif
    }

    deinit {
        if let foregroundObserver { NotificationCenter.default.removeObserver(foregroundObserver) }
        if let backgroundObserver { NotificationCenter.default.removeObserver(backgroundObserver) }
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

    func dismissSupportCard() {
        SharedStore.setSupportCardDismissed(true)
        reload()
    }

    func resetStrictModeForDebug() {
        SharedStore.resetStrictModeForDebug()
        reload()
    }

    func resetTipsDisplayForDebug() {
        SharedStore.resetTipsDisplayForDebug()
        reload()
    }

    #if os(iOS) && canImport(FamilyControls)
    var hasYouTubeSelection: Bool { SharedStore.hasValidYouTubeSelection() }
    var hasInstagramSelection: Bool { SharedStore.hasValidInstagramSelection() }

    func requestFamilyControlsAuthorization() async -> Bool {
        let granted = await FamilyControlsAuth.requestAuthorization()
        RTLog.appState.notice("requestFamilyControlsAuthorization: granted=\(granted, privacy: .public)")
        return granted
    }

    // Picking a whole category (or the picker's top-level "All Apps &
    // Categories" toggle) instead of one specific app would shield
    // everything on the device, not just the intended app — this feature's
    // whole design assumes one app per slot. Reject category selections
    // outright rather than silently saving something catastrophically
    // broader than intended.
    private func validatedForSingleApp(
        _ selection: FamilyActivitySelection,
        appName: String,
        blockedContent: String
    ) -> Bool {
        guard selection.categoryTokens.isEmpty else {
            lastError = "Pick a single app, not a whole category or \"All Apps\" — that would block everything."
            return false
        }
        guard selection.webDomainTokens.isEmpty else {
            lastError = "Pick the \(appName) app icon, not a website."
            return false
        }
        guard selection.applicationTokens.count == 1 else {
            lastError = selection.applicationTokens.isEmpty
                ? "Choose the \(appName) app before enabling \(blockedContent) blocking."
                : "Choose exactly one app."
            return false
        }
        return true
    }

    func saveYouTubeSelection(_ selection: FamilyActivitySelection) {
        if selection.applicationTokens.isEmpty,
           selection.categoryTokens.isEmpty,
           selection.webDomainTokens.isEmpty {
            do {
                try SharedStore.clearYouTubeSelection()
                SoftYouTubeActivityMonitoring.stop()
                RTLog.appState.notice("saveYouTubeSelection: selection cleared; disabling YouTube Shorts blocking")
                ManagedSettingsApplier.clear(surface: .youtube)
                reload()
            } catch SharedStoreError.strictModeActive {
                lastError = "Strict mode is active"
                reload()
            } catch {
                lastError = "Could not clear the YouTube app"
            }
            return
        }

        guard validatedForSingleApp(
            selection,
            appName: "YouTube",
            blockedContent: "Shorts"
        ) else { return }
        guard let data = try? JSONEncoder().encode(selection) else { return }
        do {
            try SharedStore.setYouTubeSelectionData(data)
            RTLog.appState.notice("saveYouTubeSelection: \(selection.applicationTokens.count, privacy: .public) app token(s) saved")
            reload()
            restoreRealtimeShieldAfterAppActivation()
        } catch SharedStoreError.strictModeActive {
            lastError = "Strict mode is active"
        } catch {
            lastError = "Could not save"
        }
    }

    func saveInstagramSelection(_ selection: FamilyActivitySelection) {
        if selection.applicationTokens.isEmpty,
           selection.categoryTokens.isEmpty,
           selection.webDomainTokens.isEmpty {
            do {
                try SharedStore.clearInstagramSelection()
                RTLog.appState.notice(
                    "saveInstagramSelection: selection cleared; disabling Instagram blocking"
                )
                ManagedSettingsApplier.clear(surface: .instagram)
                reload()
            } catch SharedStoreError.strictModeActive {
                lastError = "Strict mode is active"
                reload()
            } catch {
                lastError = "Could not clear the Instagram app"
            }
            return
        }

        guard validatedForSingleApp(
            selection,
            appName: "Instagram",
            blockedContent: "Reels or Stories"
        ) else { return }
        guard let data = try? JSONEncoder().encode(selection) else { return }
        do {
            try SharedStore.setInstagramSelectionData(data)
            RTLog.appState.notice("saveInstagramSelection: \(selection.applicationTokens.count, privacy: .public) app token(s) saved")
            reload()
            enforceRealtimeShieldAtRest()
        } catch SharedStoreError.strictModeActive {
            lastError = "Strict mode is active"
        } catch {
            lastError = "Could not save"
        }
    }

    func setRealtimeShieldEnabled(_ enabled: Bool) {
        do {
            _ = try SharedStore.setRealtimeShieldEnabled(enabled)
            RTLog.appState.notice("setRealtimeShieldEnabled(\(enabled, privacy: .public))")
            reload()
            if enabled {
                restoreRealtimeShieldAfterAppActivation()
            } else {
                // Turning the feature off must always clear any shield still
                // in place — enforceRealtimeShieldAtRest() only ever APPLIES
                // shields, it has no "definitely clear" path, so disabling
                // wouldn't otherwise unshield an app that's currently blocked.
                RTLog.appState.notice("setRealtimeShieldEnabled(false): clearing both surfaces")
                SoftYouTubeActivityMonitoring.stop()
                ManagedSettingsApplier.clear(surface: .youtube)
                ManagedSettingsApplier.clear(surface: .instagram)
            }
        } catch SharedStoreError.strictModeActive {
            lastError = "Strict mode is active"
            reload()
        } catch {
            lastError = "Could not save"
        }
    }

    func setRealtimeYouTubeBlockingEnabled(_ enabled: Bool) {
        do {
            _ = try SharedStore.setRealtimeYouTubeBlockingEnabled(enabled)
            RTLog.appState.notice("setRealtimeYouTubeBlockingEnabled(\(enabled, privacy: .public))")
            reload()
            if enabled {
                restoreRealtimeShieldAfterAppActivation()
            } else {
                SoftYouTubeActivityMonitoring.stop()
                ManagedSettingsApplier.clear(surface: .youtube)
            }
        } catch SharedStoreError.strictModeActive {
            lastError = "Strict mode is active"
            reload()
        } catch SharedStoreError.invalidValue {
            lastError = "Choose the YouTube app before enabling Shorts blocking."
            reload()
        } catch {
            lastError = "Could not save"
        }
    }

    func setSoftYouTubeBlockingEnabled(_ enabled: Bool) {
        do {
            _ = try SharedStore.setSoftYouTubeBlockingEnabled(enabled)
            RTLog.appState.notice("setSoftYouTubeBlockingEnabled(\(enabled, privacy: .public))")
            reload()
            if enabled {
                restoreRealtimeShieldAfterAppActivation()
            } else {
                // Disabling soft mode ends any pending grace immediately and
                // returns to the normal shield-at-rest behavior.
                SoftYouTubeActivityMonitoring.stop()
                if !snapshot.broadcastActive {
                    enforceRealtimeShieldAtRest()
                }
            }
        } catch SharedStoreError.strictModeActive {
            lastError = "Strict mode is active"
            reload()
        } catch SharedStoreError.invalidValue {
            lastError = "Enable YouTube Shorts blocking before enabling soft blocking."
            reload()
        } catch {
            lastError = "Could not save"
        }
    }

    func setRealtimeInstagramReelsBlockingEnabled(_ enabled: Bool) {
        do {
            _ = try SharedStore.setRealtimeInstagramReelsBlockingEnabled(enabled)
            RTLog.appState.notice(
                "setRealtimeInstagramReelsBlockingEnabled(\(enabled, privacy: .public))"
            )
            reload()
            if enabled {
                enforceRealtimeShieldAtRest()
            } else {
                clearInstagramShieldIfDisabled()
            }
        } catch SharedStoreError.strictModeActive {
            lastError = "Strict mode is active"
            reload()
        } catch SharedStoreError.invalidValue {
            lastError = "Choose the Instagram app before enabling Reels blocking."
            reload()
        } catch {
            lastError = "Could not save"
        }
    }

    func setRealtimeInstagramStoriesBlockingEnabled(_ enabled: Bool) {
        do {
            _ = try SharedStore.setRealtimeInstagramStoriesBlockingEnabled(enabled)
            RTLog.appState.notice(
                "setRealtimeInstagramStoriesBlockingEnabled(\(enabled, privacy: .public))"
            )
            reload()
            if enabled {
                enforceRealtimeShieldAtRest()
            } else {
                clearInstagramShieldIfDisabled()
            }
        } catch SharedStoreError.strictModeActive {
            lastError = "Strict mode is active"
            reload()
        } catch SharedStoreError.invalidValue {
            lastError = "Choose the Instagram app before enabling Stories blocking."
            reload()
        } catch {
            lastError = "Could not save"
        }
    }

    private func clearInstagramShieldIfDisabled() {
        if !snapshot.realtimeInstagramBlockingEnabled {
            ManagedSettingsApplier.clear(surface: .instagram)
        }
    }

    var broadcastExtensionBundleID: String {
        (Bundle.main.bundleIdentifier ?? "com.unscroll.local.ios") + ".Broadcast"
    }

    // Belt-and-suspenders: guarantees "shielded by default" holds even if
    // the Broadcast Upload Extension process never ran this app session
    // (e.g. right after picking an app, or on a fresh launch with recording
    // off) — the extension's own broadcastStarted/Finished lifecycle is the
    // primary enforcement, this just covers the gap before/between sessions.
    func enforceRealtimeShieldAtRest() {
        guard snapshot.realtimeShieldEnabled, !snapshot.broadcastActive else { return }
        RTLog.appState.notice("enforceRealtimeShieldAtRest: re-applying shields (feature on, no active broadcast)")
        let keepYouTubeUnlockedInSlowth = snapshot.softYouTubeBlockingEnabled
            && SharedStore.isSlowthAppForeground()
        if snapshot.realtimeYouTubeBlockingEnabled,
           !snapshot.youtubeShieldRestoreDeferred,
           !keepYouTubeUnlockedInSlowth,
           let data = snapshot.youtubeSelectionData,
           let selection = try? JSONDecoder().decode(FamilyActivitySelection.self, from: data) {
            ManagedSettingsApplier.apply(surface: .youtube, selection: selection)
        } else {
            ManagedSettingsApplier.clear(surface: .youtube)
        }
        if snapshot.realtimeInstagramBlockingEnabled,
           let data = snapshot.instagramSelectionData,
           let selection = try? JSONDecoder().decode(FamilyActivitySelection.self, from: data) {
            ManagedSettingsApplier.apply(surface: .instagram, selection: selection)
        } else {
            ManagedSettingsApplier.clear(surface: .instagram)
        }
    }

    private func restoreRealtimeShieldAfterAppActivation() {
        // Slowth itself is the explicit soft-mode unlock window. Cancel any
        // pending usage event first so an older callback cannot reshield
        // YouTube while this app is in front.
        SharedStore.setSlowthAppForeground(true)
        SoftYouTubeActivityMonitoring.stop()
        reload()
        guard !snapshot.broadcastActive else { return }

        if snapshot.realtimeShieldEnabled,
           snapshot.realtimeYouTubeBlockingEnabled,
           snapshot.softYouTubeBlockingEnabled {
            SharedStore.setYouTubeShieldRestoreDeferred(true)
            reload()
            ManagedSettingsApplier.clear(surface: .youtube)
            RTLog.appState.notice(
                "Slowth active — YouTube unshielded until 1s of use after leaving"
            )
        } else {
            SharedStore.setYouTubeShieldRestoreDeferred(false)
            reload()
        }
        enforceRealtimeShieldAtRest()
    }

    private func armSoftYouTubeShieldAfterLeavingSlowth() {
        SharedStore.setSlowthAppForeground(false)
        reload()
        guard !snapshot.broadcastActive,
              snapshot.realtimeShieldEnabled,
              snapshot.realtimeYouTubeBlockingEnabled,
              snapshot.softYouTubeBlockingEnabled else {
            SoftYouTubeActivityMonitoring.stop()
            return
        }

        SharedStore.setYouTubeShieldRestoreDeferred(true)
        reload()
        guard SoftYouTubeActivityMonitoring.start() else {
            // Fail closed: if iOS refuses the one-second monitor, don't leave
            // YouTube indefinitely available without recording.
            SharedStore.setYouTubeShieldRestoreDeferred(false)
            reload()
            enforceRealtimeShieldAtRest()
            RTLog.appState.error(
                "Soft YouTube monitor failed to arm — applied shield immediately"
            )
            return
        }
        ManagedSettingsApplier.clear(surface: .youtube)
    }
    #endif

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
