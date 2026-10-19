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

    @Published private(set) var snapshot: SharedState
    @Published private(set) var rulesEtag: String?
    @Published private(set) var rulesLastAttemptAt: Date?
    @Published var lastError: String? = nil
    @Published var refreshing: Bool = false
    @Published var lastRefreshOutcome: ForceRefreshOutcome? = nil

    private var foregroundObserver: NSObjectProtocol?
    private var backgroundObserver: NSObjectProtocol?
    private var tickTimer: Timer?

    #if DEBUG
    /// Display fixtures only: no defaults, observers, timer or system protection.
    init(previewSnapshot: SharedState) {
        snapshot = previewSnapshot
        rulesEtag = nil
        rulesLastAttemptAt = nil
    }
    #endif

    init() {
        snapshot = SharedStore.snapshot()
        rulesEtag = SharedStore.rulesEtag()
        rulesLastAttemptAt = SharedStore.rulesLastAttemptAt()
        #if os(iOS)
        ShieldLocalization.syncAppLanguage()
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
            SharedStore.syncRealtimeShieldAuthorization(AuthorizationCenter.shared.authorizationStatus)
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
        #if os(iOS)
        ShieldLocalization.syncAppLanguage()
        #endif
        snapshot = SharedStore.snapshot()
        rulesEtag = SharedStore.rulesEtag()
        rulesLastAttemptAt = SharedStore.rulesLastAttemptAt()
    }

    func setting(_ feature: SiteFeature, for site: String) -> Bool {
        snapshot.toggles[site]?[feature] ?? false
    }

    var hasEnabledBlockingForReview: Bool {
        let safariEnabled = SharedState.supportedSites.contains { site in
            SiteFeature.available(for: site).contains { snapshot.toggles[site]?[$0] == true }
        }
        if safariEnabled { return true }
        #if os(iOS) && canImport(FamilyControls)
        guard snapshot.realtimeShieldEnabled,
              FamilyControlsAuth.isAuthorized(AuthorizationCenter.shared.authorizationStatus) else { return false }
        return (hasYouTubeSelection && snapshot.realtimeYouTubeBlockingEnabled)
            || (hasInstagramSelection && snapshot.realtimeInstagramBlockingEnabled)
            || (hasFacebookSelection && facebookModelSelected && snapshot.realtimeFacebookBlockingEnabled)
            || (hasXSelection && xModelSelected && snapshot.realtimeXBlockingEnabled)
        #else
        return false
        #endif
    }

    func setSetting(_ feature: SiteFeature, enabled: Bool, for site: String) {
        do {
            _ = try SharedStore.setToggle(site: site, feature: feature, enabled: enabled)
            reload()
        } catch SharedStoreError.strictModeActive {
            lastError = AppLocalization.string("Strict mode is active")
            reload()
        } catch {
            lastError = AppLocalization.string("Could not save")
            reload()
        }
    }

    func setStrictMode(_ enabled: Bool) {
        do {
            _ = try SharedStore.setStrictMode(enabled)
            #if os(iOS)
            _ = try? IOSPauseCoordinator.snapshot()
            #endif
            reload()
        } catch SharedStoreError.strictModeActive {
            lastError = AppLocalization.string("Strict mode cannot be turned off until it expires")
            reload()
        } catch {
            lastError = AppLocalization.string("Could not save")
        }
    }

    func dismissSupportCard() {
        SharedStore.setSupportCardDismissed(true)
        reload()
    }

    #if os(iOS) && canImport(FamilyControls)
    func hasPauseOnlySelection(_ target: String) -> Bool { PauseOnlyApps.selection(target) != nil }

    func savePauseOnlySelection(_ selection: FamilyActivitySelection, target: String) {
        let previousSelection = PauseOnlyApps.data(target)
        let empty = selection.applicationTokens.isEmpty && selection.categoryTokens.isEmpty && selection.webDomainTokens.isEmpty
        guard empty || validatedForSingleApp(selection, appName: target == "tiktok" ? "TikTok" : "Snapchat",
                                              blockedContent: "") else { return }
        do {
            try PauseOnlyApps.save(selection, target: target)
            try IOSPauseCoordinator.selectionDidChange(target: target, previousSelection: previousSelection)
            reload()
            enforcePauseOnlyApps()
            _ = try? IOSPauseCoordinator.snapshot()
        } catch SharedStoreError.strictModeActive {
            lastError = AppLocalization.string("Strict mode is active")
        } catch {
            lastError = AppLocalization.string("Could not save")
        }
    }

    private func enforcePauseOnlyApps() {
        BlockingCoordinator.enforcePauseOnlyApps()
    }

    var hasYouTubeSelection: Bool { SharedStore.hasValidYouTubeSelection() }
    var hasInstagramSelection: Bool { SharedStore.hasValidInstagramSelection() }
    var hasFacebookSelection: Bool { SharedStore.hasValidFacebookSelection() }
    var hasXSelection: Bool { SharedStore.hasValidXSelection() }
    var facebookModelSelected: Bool {
        #if DEBUG
        return DebugModelSettings.resolve(stored: AppGroup.defaults.string(forKey: DebugModelSettings.storageKey),
            debugEnabled: DebugMode.isEnabled, cascadeAvailable: DebugModelSettings.cascadeAvailable).supportsFacebook
        #else
        return ModelSettings.defaultBackend.supportsFacebook
        #endif
    }

    var xModelSelected: Bool {
        #if DEBUG
        return DebugModelSettings.resolve(stored: AppGroup.defaults.string(forKey: DebugModelSettings.storageKey),
            debugEnabled: DebugMode.isEnabled, cascadeAvailable: DebugModelSettings.cascadeAvailable).supportsX
        #else
        return ModelSettings.defaultBackend.supportsX
        #endif
    }

    func refreshFacebookModelSelection() {
        reload()
        // The backend is frozen during a recording. Apply a new selection at rest.
        guard !snapshot.broadcastActive else { return }
        if !facebookModelSelected { ManagedSettingsApplier.clear(surface: .facebook) }
        if !xModelSelected { ManagedSettingsApplier.clear(surface: .x) }
        enforceRealtimeShieldAtRest()
    }

    func requestFamilyControlsAuthorization() async -> Bool {
        let granted = await FamilyControlsAuth.requestAuthorization()
        RTLog.appState.notice("requestFamilyControlsAuthorization: granted=\(granted, privacy: .public)")
        refreshProtectionAuthorization()
        return granted
    }

    func setPausesAllowedInStrictMode(_ allowed: Bool) {
        do {
            try SharedStore.setPausesAllowedInStrictMode(allowed)
            // Reconcile immediately so forbidding pauses also ends an active one.
            _ = try IOSPauseCoordinator.snapshot()
        } catch {
            lastError = AppLocalization.string("Could not save")
        }
        reload()
    }

    func refreshProtectionAuthorization() {
        restoreRealtimeShieldAfterAppActivation()
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
        let target = appName.lowercased()
        if IOSPauseCoordinator.apps.filter({ $0 != target }).contains(where: { other in
            guard let data = IOSPauseCoordinator.selection(other, state: SharedStore.snapshot()),
                  let bound = try? JSONDecoder().decode(FamilyActivitySelection.self, from: data) else { return false }
            return !selection.applicationTokens.isDisjoint(with: bound.applicationTokens)
        }) {
            lastError = String(localized: "This app is already selected for another service.", table: "Interface")
            return false
        }
        guard selection.categoryTokens.isEmpty else {
            lastError = AppLocalization.string("Pick a single app, not a whole category or \"All Apps\" — that would block everything.")
            return false
        }
        guard selection.webDomainTokens.isEmpty else {
            lastError = AppLocalization.string("Pick the \(appName) app icon, not a website.")
            return false
        }
        guard selection.applicationTokens.count == 1 else {
            lastError = selection.applicationTokens.isEmpty
                ? AppLocalization.string("Choose the \(appName) app before enabling \(blockedContent) blocking.")
                : AppLocalization.string("Choose exactly one app.")
            return false
        }
        return true
    }

    func saveYouTubeSelection(_ selection: FamilyActivitySelection) {
        let previousSelection = SharedStore.youtubeSelectionData()
        if selection.applicationTokens.isEmpty,
           selection.categoryTokens.isEmpty,
           selection.webDomainTokens.isEmpty {
            do {
                try SharedStore.clearYouTubeSelection()
                try IOSPauseCoordinator.selectionDidChange(target: "youtube", previousSelection: previousSelection)
                SoftYouTubeActivityMonitoring.stop()
                RTLog.appState.notice("saveYouTubeSelection: selection cleared; disabling YouTube Shorts blocking")
                ManagedSettingsApplier.clear(surface: .youtube)
                reload()
            } catch SharedStoreError.strictModeActive {
                lastError = AppLocalization.string("Strict mode is active")
                reload()
            } catch {
                lastError = AppLocalization.string("Could not clear the YouTube app")
            }
            return
        }

        guard validatedForSingleApp(
            selection,
            appName: "YouTube",
            blockedContent: "Shorts"
        ) else { return }
        guard let data = try? JSONEncoder().encode(selection) else { return }
        let isFirstSelection = !SharedStore.hasValidYouTubeSelection()
        do {
            try SharedStore.setYouTubeSelectionData(data)
            // Initialize blocking only for a new binding; preserve choices on replacement.
            if isFirstSelection {
                _ = try SharedStore.setRealtimeYouTubeBlockingEnabled(true)
                _ = try SharedStore.setSoftYouTubeBlockingEnabled(
                    true,
                    allowInitialStrictActivation: true
                )
                _ = try SharedStore.setRealtimeShieldEnabled(true)
            }
            try IOSPauseCoordinator.selectionDidChange(target: "youtube", previousSelection: previousSelection)
            RTLog.appState.notice("saveYouTubeSelection: \(selection.applicationTokens.count, privacy: .public) app token(s) saved")
            reload()
            restoreRealtimeShieldAfterAppActivation()
        } catch SharedStoreError.strictModeActive {
            lastError = AppLocalization.string("Strict mode is active")
        } catch {
            lastError = AppLocalization.string("Could not save")
        }
    }

    func saveInstagramSelection(_ selection: FamilyActivitySelection) {
        let previousSelection = SharedStore.instagramSelectionData()
        if selection.applicationTokens.isEmpty,
           selection.categoryTokens.isEmpty,
           selection.webDomainTokens.isEmpty {
            do {
                try SharedStore.clearInstagramSelection()
                try IOSPauseCoordinator.selectionDidChange(target: "instagram", previousSelection: previousSelection)
                RTLog.appState.notice(
                    "saveInstagramSelection: selection cleared; disabling Instagram blocking"
                )
                ManagedSettingsApplier.clear(surface: .instagram)
                reload()
            } catch SharedStoreError.strictModeActive {
                lastError = AppLocalization.string("Strict mode is active")
                reload()
            } catch {
                lastError = AppLocalization.string("Could not clear the Instagram app")
            }
            return
        }

        guard validatedForSingleApp(
            selection,
            appName: "Instagram",
            blockedContent: AppLocalization.string("Reels or Stories")
        ) else { return }
        guard let data = try? JSONEncoder().encode(selection) else { return }
        let isFirstSelection = !SharedStore.hasValidInstagramSelection()
        do {
            try SharedStore.setInstagramSelectionData(data)
            // Clearing a binding makes the next valid selection a first selection again.
            if isFirstSelection {
                _ = try SharedStore.setRealtimeInstagramReelsBlockingEnabled(true)
                _ = try SharedStore.setRealtimeInstagramStoriesBlockingEnabled(true)
                _ = try SharedStore.setRealtimeShieldEnabled(true)
            }
            try IOSPauseCoordinator.selectionDidChange(target: "instagram", previousSelection: previousSelection)
            RTLog.appState.notice("saveInstagramSelection: \(selection.applicationTokens.count, privacy: .public) app token(s) saved")
            reload()
            enforceRealtimeShieldAtRest()
        } catch SharedStoreError.strictModeActive {
            lastError = AppLocalization.string("Strict mode is active")
        } catch {
            lastError = AppLocalization.string("Could not save")
        }
    }

    func saveFacebookSelection(_ selection: FamilyActivitySelection) {
        let previousSelection = SharedStore.facebookSelectionData()
        if selection.applicationTokens.isEmpty,
           selection.categoryTokens.isEmpty,
           selection.webDomainTokens.isEmpty {
            do {
                try SharedStore.clearFacebookSelection()
                try IOSPauseCoordinator.selectionDidChange(target: "facebook", previousSelection: previousSelection)
                RTLog.appState.notice(
                    "saveFacebookSelection: selection cleared; disabling Facebook blocking"
                )
                ManagedSettingsApplier.clear(surface: .facebook)
                reload()
            } catch SharedStoreError.strictModeActive {
                lastError = AppLocalization.string("Strict mode is active")
                reload()
            } catch {
                lastError = AppLocalization.string("Could not clear the Facebook app")
            }
            return
        }

        guard validatedForSingleApp(
            selection,
            appName: "Facebook",
            blockedContent: AppLocalization.string("Reels or Stories")
        ) else { return }
        guard let data = try? JSONEncoder().encode(selection) else { return }
        let isFirstSelection = !SharedStore.hasValidFacebookSelection()
        do {
            try SharedStore.setFacebookSelectionData(data)
            // Clearing a binding makes the next valid selection a first selection again.
            if isFirstSelection && facebookModelSelected {
                _ = try SharedStore.setRealtimeFacebookReelsBlockingEnabled(true)
                _ = try SharedStore.setRealtimeFacebookStoriesBlockingEnabled(true)
                _ = try SharedStore.setRealtimeShieldEnabled(true)
            }
            try IOSPauseCoordinator.selectionDidChange(target: "facebook", previousSelection: previousSelection)
            RTLog.appState.notice("saveFacebookSelection: \(selection.applicationTokens.count, privacy: .public) app token(s) saved")
            reload()
            enforceRealtimeShieldAtRest()
        } catch SharedStoreError.strictModeActive {
            lastError = AppLocalization.string("Strict mode is active")
        } catch {
            lastError = AppLocalization.string("Could not save")
        }
    }

    func saveXSelection(_ selection: FamilyActivitySelection) {
        let previousSelection = SharedStore.xSelectionData()
        if selection.applicationTokens.isEmpty,
           selection.categoryTokens.isEmpty,
           selection.webDomainTokens.isEmpty {
            do {
                try SharedStore.clearXSelection()
                try IOSPauseCoordinator.selectionDidChange(target: "x", previousSelection: previousSelection)
                RTLog.appState.notice(
                    "saveXSelection: selection cleared; disabling X blocking"
                )
                ManagedSettingsApplier.clear(surface: .x)
                reload()
            } catch SharedStoreError.strictModeActive {
                lastError = AppLocalization.string("Strict mode is active")
                reload()
            } catch {
                lastError = AppLocalization.string("Could not clear the X app")
            }
            return
        }

        guard validatedForSingleApp(
            selection,
            appName: "X",
            blockedContent: AppLocalization.string("Reels")
        ) else { return }
        guard let data = try? JSONEncoder().encode(selection) else { return }
        let isFirstSelection = !SharedStore.hasValidXSelection()
        do {
            try SharedStore.setXSelectionData(data)
            // Clearing a binding makes the next valid selection a first selection again.
            if isFirstSelection && xModelSelected {
                _ = try SharedStore.setRealtimeXReelsBlockingEnabled(true)
                _ = try SharedStore.setRealtimeShieldEnabled(true)
            }
            try IOSPauseCoordinator.selectionDidChange(target: "x", previousSelection: previousSelection)
            RTLog.appState.notice("saveXSelection: \(selection.applicationTokens.count, privacy: .public) app token(s) saved")
            reload()
            enforceRealtimeShieldAtRest()
        } catch SharedStoreError.strictModeActive {
            lastError = AppLocalization.string("Strict mode is active")
        } catch {
            lastError = AppLocalization.string("Could not save")
        }
    }

    func setRealtimeShieldEnabled(_ enabled: Bool) {
        do {
            _ = try SharedStore.setRealtimeShieldEnabled(enabled)
            RTLog.appState.notice("setRealtimeShieldEnabled(\(enabled, privacy: .public))")
            reload()
            BlockingCoordinator.settingsChanged(.recordingProtection, enabled: enabled,
                facebookSupported: facebookModelSelected, xSupported: xModelSelected)
            reload()
        } catch SharedStoreError.strictModeActive {
            lastError = AppLocalization.string("Strict mode is active")
            reload()
        } catch {
            lastError = AppLocalization.string("Could not save")
        }
    }

    func setRealtimeYouTubeBlockingEnabled(_ enabled: Bool) {
        do {
            _ = try SharedStore.setRealtimeYouTubeBlockingEnabled(enabled)
            RTLog.appState.notice("setRealtimeYouTubeBlockingEnabled(\(enabled, privacy: .public))")
            reload()
            BlockingCoordinator.settingsChanged(.youtube, enabled: enabled,
                facebookSupported: facebookModelSelected, xSupported: xModelSelected)
            reload()
        } catch SharedStoreError.strictModeActive {
            lastError = AppLocalization.string("Strict mode is active")
            reload()
        } catch SharedStoreError.invalidValue {
            lastError = AppLocalization.string("Choose the YouTube app before enabling Shorts blocking.")
            reload()
        } catch {
            lastError = AppLocalization.string("Could not save")
        }
    }

    func setSoftYouTubeBlockingEnabled(_ enabled: Bool) {
        do {
            _ = try SharedStore.setSoftYouTubeBlockingEnabled(enabled)
            RTLog.appState.notice("setSoftYouTubeBlockingEnabled(\(enabled, privacy: .public))")
            reload()
            BlockingCoordinator.settingsChanged(.softYouTube, enabled: enabled,
                facebookSupported: facebookModelSelected, xSupported: xModelSelected)
            reload()
        } catch SharedStoreError.strictModeActive {
            lastError = AppLocalization.string("Strict mode is active")
            reload()
        } catch SharedStoreError.invalidValue {
            lastError = AppLocalization.string("Enable YouTube Shorts blocking before enabling soft blocking.")
            reload()
        } catch {
            lastError = AppLocalization.string("Could not save")
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
            lastError = AppLocalization.string("Strict mode is active")
            reload()
        } catch SharedStoreError.invalidValue {
            lastError = AppLocalization.string("Choose the Instagram app before enabling Reels blocking.")
            reload()
        } catch {
            lastError = AppLocalization.string("Could not save")
        }
    }

    func setRealtimeFacebookReelsBlockingEnabled(_ enabled: Bool) {
        guard !enabled || facebookModelSelected else {
            lastError = AppLocalization.string("Select Cascade V7 before enabling Facebook blocking.")
            return
        }
        do {
            _ = try SharedStore.setRealtimeFacebookReelsBlockingEnabled(enabled)
            RTLog.appState.notice(
                "setRealtimeFacebookReelsBlockingEnabled(\(enabled, privacy: .public))"
            )
            reload()
            if enabled {
                enforceRealtimeShieldAtRest()
            } else {
                clearFacebookShieldIfDisabled()
            }
        } catch SharedStoreError.strictModeActive {
            lastError = AppLocalization.string("Strict mode is active")
            reload()
        } catch SharedStoreError.invalidValue {
            lastError = AppLocalization.string("Choose the Facebook app before enabling Reels blocking.")
            reload()
        } catch {
            lastError = AppLocalization.string("Could not save")
        }
    }

    func setRealtimeXReelsBlockingEnabled(_ enabled: Bool) {
        guard !enabled || xModelSelected else {
            lastError = AppLocalization.string("Select Cascade V8 or V10 before enabling X blocking.")
            return
        }
        do {
            _ = try SharedStore.setRealtimeXReelsBlockingEnabled(enabled)
            RTLog.appState.notice(
                "setRealtimeXReelsBlockingEnabled(\(enabled, privacy: .public))"
            )
            reload()
            if enabled {
                enforceRealtimeShieldAtRest()
            } else {
                clearXShieldIfDisabled()
            }
        } catch SharedStoreError.strictModeActive {
            lastError = AppLocalization.string("Strict mode is active")
            reload()
        } catch SharedStoreError.invalidValue {
            lastError = AppLocalization.string("Choose the X app before enabling Reels blocking.")
            reload()
        } catch {
            lastError = AppLocalization.string("Could not save")
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
            lastError = AppLocalization.string("Strict mode is active")
            reload()
        } catch SharedStoreError.invalidValue {
            lastError = AppLocalization.string("Choose the Instagram app before enabling Stories blocking.")
            reload()
        } catch {
            lastError = AppLocalization.string("Could not save")
        }
    }

    func setRealtimeFacebookStoriesBlockingEnabled(_ enabled: Bool) {
        guard !enabled || facebookModelSelected else {
            lastError = AppLocalization.string("Select Cascade V7 before enabling Facebook blocking.")
            return
        }
        do {
            _ = try SharedStore.setRealtimeFacebookStoriesBlockingEnabled(enabled)
            RTLog.appState.notice(
                "setRealtimeFacebookStoriesBlockingEnabled(\(enabled, privacy: .public))"
            )
            reload()
            if enabled {
                enforceRealtimeShieldAtRest()
            } else {
                clearFacebookShieldIfDisabled()
            }
        } catch SharedStoreError.strictModeActive {
            lastError = AppLocalization.string("Strict mode is active")
            reload()
        } catch SharedStoreError.invalidValue {
            lastError = AppLocalization.string("Choose the Facebook app before enabling Stories blocking.")
            reload()
        } catch {
            lastError = AppLocalization.string("Could not save")
        }
    }

    private func clearInstagramShieldIfDisabled() {
        if !snapshot.realtimeInstagramBlockingEnabled {
            ManagedSettingsApplier.clear(surface: .instagram)
        }
    }

    private func clearFacebookShieldIfDisabled() {
        if !snapshot.realtimeFacebookBlockingEnabled {
            ManagedSettingsApplier.clear(surface: .facebook)
        }
    }

    private func clearXShieldIfDisabled() {
        if !snapshot.realtimeXBlockingEnabled {
            ManagedSettingsApplier.clear(surface: .x)
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
        BlockingCoordinator.enforceAtRest(snapshot, facebookSupported: facebookModelSelected, xSupported: xModelSelected)
    }

    private func restoreRealtimeShieldAfterAppActivation() {
        BlockingCoordinator.hostOpened(facebookSupported: facebookModelSelected, xSupported: xModelSelected)
        reload()
    }

    private func armSoftYouTubeShieldAfterLeavingSlowth() {
        BlockingCoordinator.hostClosed(facebookSupported: facebookModelSelected, xSupported: xModelSelected)
        reload()
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


enum L10n {
    // macOS can override its app language; iOS follows the system preference.
    static var locale: Locale {
        AppLocalization.locale
    }

    static func dateTime(_ date: Date) -> String {
        date.formatted(.dateTime.year().month(.abbreviated).day().hour().minute().locale(locale))
    }

    static func refreshError(_ reason: String) -> String {
        switch reason {
        case "strict": return AppLocalization.string("Strict mode is active")
        case "no_url": return AppLocalization.string("Invalid update address")
        case "no_response": return AppLocalization.string("No server response")
        default:
            if reason.hasPrefix("http_"), let code = Int(reason.dropFirst(5)) {
                return AppLocalization.string("Server error (\(code))")
            }
            return AppLocalization.string("Network error")
        }
    }
}
