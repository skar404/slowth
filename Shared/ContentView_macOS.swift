import SwiftUI
import StoreKit
#if os(iOS)
import UIKit
#endif
#if os(iOS) && canImport(FamilyControls)
import FamilyControls
#endif

private struct SiteSpec: Identifiable {
    let id: String
    let label: String
    let modes: [SiteMode]
}

// ⚠️ Per-site available modes mirror WebExt/config.js SITE_AVAILABLE_MODES (the JS
// popup builds the same dropdown from there). Keep the two lists in sync.
private let sites: [SiteSpec] = [
    .init(id: "youtube",   label: "YouTube",   modes: [.off, .shorts, .all]),
    .init(id: "instagram", label: "Instagram", modes: [.off, .shorts, .feed, .all]),
    .init(id: "tiktok",    label: "TikTok",    modes: [.off, .all]),
    .init(id: "facebook",  label: "Facebook",  modes: [.off, .shorts, .feed, .all]),
    .init(id: "x",         label: "X",         modes: [.off, .shorts, .all])
]


struct MacContentView: View {
    @StateObject private var state = AppState()
    @StateObject private var tipStore = TipStore()
    @State private var showAbout = false
    @State private var showSupportSheet = false
    @AppStorage(DebugMode.storageKey, store: AppGroup.defaults) private var debugModeEnabled = false
    @AppStorage(FeatureFlags.tipsOverrideStorageKey, store: AppGroup.defaults) private var tipsFeatureEnabled = false
    @State private var versionTapCount = 0
    #if os(iOS)
    @AppStorage("uiMode") private var uiMode: String = "ios"
    @State private var showRealtimeBlockingBeta = false
    @State private var showRealtimeRecordingPrompt = false
    #endif
    #if os(iOS) && canImport(FamilyControls)
    @ObservedObject private var familyControlsAuthorization = AuthorizationCenter.shared
    @State private var isAuthorizingFamilyControls = false
    @State private var showYouTubePicker = false
    @State private var showInstagramPicker = false
    @State private var youtubeSelection = FamilyActivitySelection()
    @State private var instagramSelection = FamilyActivitySelection()
    #endif

    var body: some View {
        Form {
            Section {
                HStack(spacing: 10) {
                    #if os(iOS)
                    HeroCard(
                        title: "Real-time blocking",
                        subtitle: "Shorts, Reels & Stories · Beta",
                        icon: "record.circle.fill",
                        gradient: [Color(red: 0.98, green: 0.24, blue: 0.34),
                                   Color(red: 0.79, green: 0.12, blue: 0.45)],
                        action: { showRealtimeBlockingBeta = true }
                    )
                    #endif
                    HeroCard(
                        title: "How it works",
                        subtitle: "What Slowth does",
                        icon: "sparkles",
                        gradient: [Color(red: 0.36, green: 0.46, blue: 0.95),
                                   Color(red: 0.55, green: 0.32, blue: 0.86)],
                        action: { showAbout = true }
                    )
                    HeroCard(
                        title: "Safari",
                        subtitle: "Enable extension",
                        icon: "safari.fill",
                        gradient: [Color(red: 0.21, green: 0.65, blue: 0.97),
                                   Color(red: 0.14, green: 0.45, blue: 0.84)],
                        action: { state.openSafariExtensionSettings() }
                    )
                    if FeatureFlags.tipsEnabled && !state.snapshot.supportCardDismissed {
                        HeroCard(
                            title: "Support",
                            subtitle: "Tip the developer",
                            icon: "heart.fill",
                            gradient: [Color(red: 0.95, green: 0.42, blue: 0.55),
                                       Color(red: 0.85, green: 0.20, blue: 0.45)],
                            action: { showSupportSheet = true },
                            onDismiss: { state.dismissSupportCard() }
                        )
                    }
                }
                .frame(maxWidth: .infinity, alignment: .center)
                .listRowInsets(EdgeInsets(top: 8, leading: 8, bottom: 8, trailing: 8))
            }

            if state.snapshot.isStrictModeActive {
                Section {
                    HStack(spacing: 8) {
                        Image(systemName: "lock.fill")
                            .foregroundStyle(.orange)
                        VStack(alignment: .leading, spacing: 2) {
                            Text("Strict mode active").fontWeight(.semibold)
                            if let until = state.snapshot.strictModeUntil {
                                Text("Locked until \(until.formatted(date: .abbreviated, time: .shortened))")
                                    .font(.callout)
                                    .foregroundStyle(.secondary)
                            }
                        }
                    }
                }
            }

            Section {
                ForEach(sites) { site in
                    Picker(site.label, selection: bindingForSite(site.id)) {
                        ForEach(site.modes, id: \.self) { mode in
                            Text(modeLabel(mode, for: site.id)).tag(mode)
                        }
                    }
                    .disabled(disabledByStrict)
                }
            } header: {
                Text("Sites")
            } footer: {
                Text("Off — the extension does nothing. YouTube blocks Shorts; Instagram and Facebook block Reels; X blocks Explore and trends. Instagram and Facebook also offer a feed mode; Instagram’s includes Explore, Stories, and additional Reels surfaces. Block site redirects the whole site.")
                    .font(.callout)
                    .foregroundStyle(.secondary)
            }

            #if os(iOS) && canImport(FamilyControls)
            realtimeShieldSection
            #endif

            Section {
                Toggle(isOn: Binding(
                    get: { state.snapshot.isStrictModeActive },
                    set: { newValue in state.setStrictMode(newValue) }
                )) {
                    VStack(alignment: .leading, spacing: 2) {
                        Text("Strict mode")
                        Text("Locks every setting for 24 h. Survives restart and force-quit.")
                            .font(.callout)
                            .foregroundStyle(.secondary)
                    }
                }
                .disabled(disabledByStrict)
            } header: {
                Text("Strict mode")
            }

            Section {
                HStack {
                    Button {
                        Task { await state.forceRefresh() }
                    } label: {
                        if state.refreshing {
                            HStack(spacing: 6) {
                                ProgressView().controlSize(.small)
                                Text("Updating…")
                            }
                        } else {
                            Text("Update rules now")
                        }
                    }
                    .disabled(state.refreshing || disabledByStrict)

                    Spacer()

                    Text(rulesStatusText)
                        .foregroundStyle(.secondary)
                        .font(.callout)
                }
            } header: {
                Text("Rules")
            } footer: {
                Text(rulesFooterText)
                    .font(.callout)
                    .foregroundStyle(.secondary)
            }

            if debugModeEnabled {
                debugSection
            }

            Section {
                Link("Send feedback", destination: feedbackURL)
                if FeatureFlags.tipsEnabled {
                    Button {
                        showSupportSheet = true
                    } label: {
                        HStack {
                            Text("Support")
                            Spacer()
                            Image(systemName: "heart.fill")
                                .foregroundStyle(.secondary)
                        }
                    }
                    .buttonStyle(.plain)
                }
            } header: {
                Text("Help")
            } footer: {
                Button(action: appVersionTapped) {
                    Text(appVersion)
                        .font(.callout)
                        .foregroundStyle(.secondary)
                }
                .buttonStyle(.plain)
            }
        }
        .formStyle(.grouped)
        .navigationTitle("Slowth")
        .alert("Heads up",
               isPresented: Binding(
                get: { state.lastError != nil },
                set: { if !$0 { state.lastError = nil } })) {
            Button("OK", role: .cancel) { state.lastError = nil }
        } message: {
            Text(state.lastError ?? "")
        }
        .sheet(isPresented: $showAbout) {
            AboutSheet()
        }
        .sheet(isPresented: $showSupportSheet) {
            SupportSheet(tipStore: tipStore)
        }
        #if os(iOS)
        .sheet(isPresented: $showRealtimeBlockingBeta) {
            RealtimeBlockingBetaSheet(
                feedbackURL: realtimeBlockingFeedbackURL
            )
        }
        #endif
        #if os(iOS) && canImport(FamilyControls)
        .sheet(isPresented: $showRealtimeRecordingPrompt) {
            RealtimeRecordingPromptSheet(
                preferredExtensionBundleID: state.broadcastExtensionBundleID,
                isRecording: state.snapshot.broadcastActive
            )
        }
        .sheet(isPresented: $showYouTubePicker) {
            FamilyActivityPickerWrapper(
                selection: youtubeSelection,
                onDone: { selection in
                    state.saveYouTubeSelection(selection)
                    showYouTubePicker = false
                },
                onCancel: { showYouTubePicker = false }
            )
        }
        .sheet(isPresented: $showInstagramPicker) {
            FamilyActivityPickerWrapper(
                selection: instagramSelection,
                onDone: { selection in
                    state.saveInstagramSelection(selection)
                    showInstagramPicker = false
                },
                onCancel: { showInstagramPicker = false }
            )
        }
        .onAppear(perform: presentRealtimeRecordingPromptIfRequested)
        .onReceive(NotificationCenter.default.publisher(for: UIApplication.didBecomeActiveNotification)) { _ in
            presentRealtimeRecordingPromptIfRequested()
        }
        #endif
    }

    private var disabledByStrict: Bool { state.snapshot.isStrictModeActive }

    #if os(iOS) && canImport(FamilyControls)
    private func presentRealtimeRecordingPromptIfRequested() {
        guard SharedStore.consumeRealtimeRecordingPromptRequest() else { return }
        state.reload()
        showRealtimeRecordingPrompt = true
    }
    #endif

    #if os(iOS) && canImport(FamilyControls)
    private var realtimeShieldSection: some View {
        Section {
            Toggle(isOn: Binding(
                get: { state.snapshot.realtimeShieldEnabled },
                set: { state.setRealtimeShieldEnabled($0) }
            )) {
                Text("Real-time app blocking")
            }
            .disabled(disabledByStrict)

            if state.snapshot.realtimeShieldEnabled {
                RealtimeRecordingCard(
                    preferredExtensionBundleID: state.broadcastExtensionBundleID,
                    isRecording: state.snapshot.broadcastActive,
                    guidance: realtimeRecordingGuidance
                )
            }

            if !FamilyControlsAuth.isAuthorized(familyControlsAuthorization.authorizationStatus) {
                Button {
                    Task {
                        isAuthorizingFamilyControls = true
                        _ = await state.requestFamilyControlsAuthorization()
                        isAuthorizingFamilyControls = false
                    }
                } label: {
                    HStack {
                        Text("Allow Screen Time access")
                        Spacer()
                        if isAuthorizingFamilyControls { ProgressView().controlSize(.small) }
                    }
                }
                .disabled(isAuthorizingFamilyControls)
            } else {
                Button {
                    youtubeSelection = decodedSelection(state.snapshot.youtubeSelectionData)
                    showYouTubePicker = true
                } label: {
                    HStack {
                        Text("Choose YouTube app")
                        Spacer()
                        if state.hasYouTubeSelection {
                            Image(systemName: "checkmark.circle.fill").foregroundStyle(.green)
                        }
                    }
                }
                .buttonStyle(.plain)

                Toggle("Block YouTube Shorts", isOn: Binding(
                    get: { state.snapshot.realtimeYouTubeBlockingEnabled },
                    set: { state.setRealtimeYouTubeBlockingEnabled($0) }
                ))
                .disabled(disabledByStrict || !state.hasYouTubeSelection)

                Toggle("Soft YouTube blocking", isOn: Binding(
                    get: { state.snapshot.softYouTubeBlockingEnabled },
                    set: { state.setSoftYouTubeBlockingEnabled($0) }
                ))
                .disabled(
                    disabledByStrict
                        || !state.hasYouTubeSelection
                        || !state.snapshot.realtimeYouTubeBlockingEnabled
                )

                Text("Soft mode works well for audio podcasts. Picture in Picture may still be blocked when screen recording is off.")
                    .font(.caption)
                    .foregroundStyle(.secondary)

                Button {
                    instagramSelection = decodedSelection(state.snapshot.instagramSelectionData)
                    showInstagramPicker = true
                } label: {
                    HStack {
                        Text("Choose Instagram app")
                        Spacer()
                        if state.hasInstagramSelection {
                            Image(systemName: "checkmark.circle.fill").foregroundStyle(.green)
                        }
                    }
                }
                .buttonStyle(.plain)

                Toggle("Block Instagram Reels", isOn: Binding(
                    get: { state.snapshot.realtimeInstagramReelsBlockingEnabled },
                    set: { state.setRealtimeInstagramReelsBlockingEnabled($0) }
                ))
                .disabled(disabledByStrict || !state.hasInstagramSelection)

                Toggle("Block Instagram Stories", isOn: Binding(
                    get: { state.snapshot.realtimeInstagramStoriesBlockingEnabled },
                    set: { state.setRealtimeInstagramStoriesBlockingEnabled($0) }
                ))
                .disabled(disabledByStrict || !state.hasInstagramSelection)

                if debugModeEnabled {
                    VStack(alignment: .leading, spacing: 3) {
                        Text("Debug status")
                            .font(.caption.weight(.semibold))
                            .foregroundStyle(.secondary)
                        DebugStatusRow(label: "Feature", value: state.snapshot.realtimeShieldEnabled ? "on" : "off")
                        DebugStatusRow(label: "Recording", value: state.snapshot.broadcastActive ? "active" : "inactive")
                        DebugStatusRow(label: "YouTube Shorts", value: state.snapshot.realtimeYouTubeBlockingEnabled ? "blocked" : "allowed")
                        DebugStatusRow(label: "YouTube soft mode", value: state.snapshot.softYouTubeBlockingEnabled ? "on" : "off")
                        DebugStatusRow(label: "YouTube restore", value: state.snapshot.youtubeShieldRestoreDeferred ? "waiting for 1s usage" : "normal")
                        DebugStatusRow(label: "YouTube app", value: state.hasYouTubeSelection ? "picked" : "not picked")
                        DebugStatusRow(label: "Instagram Reels", value: state.snapshot.realtimeInstagramReelsBlockingEnabled ? "blocked" : "allowed")
                        DebugStatusRow(label: "Instagram Stories", value: state.snapshot.realtimeInstagramStoriesBlockingEnabled ? "blocked" : "allowed")
                        DebugStatusRow(label: "Instagram app", value: state.hasInstagramSelection ? "picked" : "not picked")
                        DebugStatusRow(label: "Surface model", value: modelStatusText(state.snapshot.realtimeShieldDiagnostics))
                        DebugStatusRow(label: "Prediction", value: predictionText(state.snapshot.realtimeShieldDiagnostics))
                        DebugStatusRow(label: "YouTube app p", value: probabilityText(state.snapshot.realtimeShieldDiagnostics.appProbabilities, key: "youtube"))
                        DebugStatusRow(label: "Instagram app p", value: probabilityText(state.snapshot.realtimeShieldDiagnostics.appProbabilities, key: "instagram"))
                        DebugStatusRow(label: "Shorts joint p", value: probabilityText(state.snapshot.realtimeShieldDiagnostics.jointProbabilities, key: "youtube_shorts"))
                        DebugStatusRow(label: "Reels joint p", value: probabilityText(state.snapshot.realtimeShieldDiagnostics.jointProbabilities, key: "instagram_reels"))
                        DebugStatusRow(label: "Stories joint p", value: probabilityText(state.snapshot.realtimeShieldDiagnostics.jointProbabilities, key: "instagram_stories"))
                        DebugStatusRow(label: "Video frames", value: "\(state.snapshot.realtimeShieldDiagnostics.receivedVideoFrames)")
                        DebugStatusRow(label: "Inferences", value: "\(state.snapshot.realtimeShieldDiagnostics.inferenceCount)")
                        DebugStatusRow(label: "Inference", value: formatted(state.snapshot.realtimeShieldDiagnostics.lastInferenceDurationMS, digits: 1, suffix: " ms"))
                        DebugStatusRow(label: "Inference p95", value: formatted(state.snapshot.realtimeShieldDiagnostics.inferenceP95MS, digits: 1, suffix: " ms"))
                        DebugStatusRow(label: "Candidates", value: "Shorts \(state.snapshot.realtimeShieldDiagnostics.youtubeCandidateEvents) · Reels \(state.snapshot.realtimeShieldDiagnostics.instagramCandidateEvents) · Stories \(state.snapshot.realtimeShieldDiagnostics.instagramStoriesCandidateEvents)")
                        DebugStatusRow(label: "Memory footprint", value: footprintText(state.snapshot.realtimeShieldDiagnostics))
                        DebugStatusRow(label: "Available memory", value: formatted(state.snapshot.realtimeShieldDiagnostics.availableMemoryMB, digits: 1, suffix: " MB"))
                        if let error = state.snapshot.realtimeShieldDiagnostics.lastClassifierError {
                            DebugStatusRow(label: "Model error", value: error)
                        }
                        DebugStatusRow(label: "Last YouTube Shorts", value: relativeOrNever(state.snapshot.lastYouTubeShortsDetectionAt))
                        DebugStatusRow(label: "Last Instagram Reels", value: relativeOrNever(state.snapshot.lastInstagramReelsDetectionAt))
                        DebugStatusRow(label: "Last Instagram Stories", value: relativeOrNever(state.snapshot.lastInstagramStoriesDetectionAt))
                        DebugStatusRow(label: "Last Instagram shield", value: relativeOrNever(state.snapshot.lastInstagramShieldPresentedAt))
                        DebugStatusRow(label: "Last shield tap", value: relativeOrNever(state.snapshot.lastShieldActionInvokedAt))
                    }
                    .padding(.vertical, 2)
                }
            }
        } header: {
            Text("Real-time blocking (Beta)")
        } footer: {
            Text("Choose YouTube or Instagram, then enable the content you want to block. Enabled apps stay blocked unless you're recording your screen. Optional soft YouTube mode works well for audio podcasts, but Picture in Picture may still be blocked when recording is off. Pick one app icon per service, not a category or \"All Apps\".")
                .font(.callout)
                .foregroundStyle(.secondary)
        }
    }

    private var realtimeRecordingGuidance: String {
        if !FamilyControlsAuth.isAuthorized(familyControlsAuthorization.authorizationStatus) {
            return "Allow Screen Time access below to finish setup."
        }
        let youtubeReady = state.hasYouTubeSelection
            && state.snapshot.realtimeYouTubeBlockingEnabled
        let instagramReady = state.hasInstagramSelection
            && state.snapshot.realtimeInstagramBlockingEnabled
        if !youtubeReady && !instagramReady {
            return "Choose an app and enable at least one blocking option below."
        }
        return "Tap the red button to start screen recording."
    }

    private func relativeOrNever(_ date: Date?) -> String {
        guard let date else { return "never" }
        return Self.relativeFormatter.localizedString(for: date, relativeTo: Date())
    }

    private func modelStatusText(_ diagnostics: RealtimeShieldDiagnostics) -> String {
        guard let version = diagnostics.modelVersion else { return diagnostics.modelStatus }
        return "\(diagnostics.modelStatus) · \(version)"
    }

    private func predictionText(_ diagnostics: RealtimeShieldDiagnostics) -> String {
        guard let app = diagnostics.lastApp else { return "—" }
        return "\(app) / \(diagnostics.lastContent ?? "—")"
    }

    private func probabilityText(_ probabilities: [String: Double]?, key: String) -> String {
        formatted(probabilities?[key], digits: 3)
    }

    private func formatted(_ value: Double?, digits: Int, suffix: String = "") -> String {
        guard let value else { return "—" }
        return String(format: "%.*f%@", digits, value, suffix)
    }

    private func footprintText(_ diagnostics: RealtimeShieldDiagnostics) -> String {
        let current = formatted(diagnostics.currentFootprintMB, digits: 1, suffix: " MB")
        let peak = formatted(diagnostics.peakFootprintMB, digits: 1, suffix: " MB")
        return "\(current) · peak \(peak)"
    }

    private func decodedSelection(_ data: Data?) -> FamilyActivitySelection {
        guard let data, let decoded = try? JSONDecoder().decode(FamilyActivitySelection.self, from: data) else {
            return FamilyActivitySelection()
        }
        return decoded
    }
    #endif

    private func bindingForSite(_ siteID: String) -> Binding<SiteMode> {
        Binding(
            get: { state.mode(for: siteID) },
            set: { state.setMode($0, for: siteID) }
        )
    }

    private var debugSection: some View {
        Section {
            Toggle("Debug mode", isOn: $debugModeEnabled)
            Toggle("Tips", isOn: $tipsFeatureEnabled)
            Button("Reset Strict mode") {
                state.resetStrictModeForDebug()
            }
            .disabled(!state.snapshot.isStrictModeActive)
            Button("Show Tips card again") {
                state.resetTipsDisplayForDebug()
            }
            .disabled(!state.snapshot.supportCardDismissed)
        } header: {
            Text("Debug")
        } footer: {
            Text("Feature overrides and reset actions affect only this device.")
                .font(.callout)
                .foregroundStyle(.secondary)
        }
    }

    private func appVersionTapped() {
        guard !debugModeEnabled else { return }
        versionTapCount += 1
        guard versionTapCount >= DebugMode.requiredVersionTapCount else { return }
        versionTapCount = 0
        debugModeEnabled = true
    }

    // ⚠️ Mode labels mirror SITE_MODE_LABELS in WebExt/config.js.
    private func modeLabel(_ mode: SiteMode, for siteID: String) -> String {
        switch (siteID, mode) {
        case (_, .off): return "Off"
        case ("youtube", .shorts): return "Block Shorts"
        case ("instagram", .shorts), ("facebook", .shorts): return "Block Reels"
        case ("instagram", .feed): return "Block Reels + feeds"
        case ("facebook", .feed): return "Block Reels + feed"
        case ("x", .shorts): return "Block Explore & trends"
        case (_, .all): return "Block site"
        case (_, .shorts): return "Block selected content"
        case (_, .feed): return "Block selected content + feed"
        }
    }

    private var rulesStatusText: String {
        if let date = state.snapshot.rulesFetchedAt {
            return "Updated " + Self.relativeFormatter.localizedString(for: date, relativeTo: Date())
        }
        return "Never updated"
    }

    private var rulesFooterText: String {
        switch state.lastRefreshOutcome {
        case .updated?: return "Rules updated."
        case .notModified?: return "Rules already up to date."
        case .failed(let reason)?: return "Update failed (\(reason))."
        case .none: return "Safari checks for remote rule updates every 6 hours. Strict mode pauses rule changes until the lock expires."
        }
    }

    private var appVersion: String {
        let v = Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "0.0.0"
        let b = Bundle.main.infoDictionary?["CFBundleVersion"] as? String ?? "0"
        return "Slowth v\(v) (\(b))"
    }

    private var deviceInfo: String {
        #if os(iOS)
        let device = UIDevice.current
        return "\(device.systemName) \(device.systemVersion), \(device.model)"
        #elseif os(macOS)
        let v = ProcessInfo.processInfo.operatingSystemVersion
        return "macOS \(v.majorVersion).\(v.minorVersion).\(v.patchVersion)"
        #endif
    }

    private var feedbackURL: URL {
        var components = URLComponents()
        components.scheme = "mailto"
        components.path = "denis@malina.page"
        components.queryItems = [
            URLQueryItem(name: "subject", value: "Slowth feedback"),
            URLQueryItem(name: "body", value: "\n\n(Helps me debug — delete if you'd rather not share.)\n\(appVersion)\n\(deviceInfo)")
        ]
        return components.url!
    }

    #if os(iOS)
    private var realtimeBlockingFeedbackURL: URL {
        Self.mailURL(
            subject: "Slowth — Real-time blocking Beta feedback",
            body: """
            Tell me what happened:


            App and device details (you can delete these if you'd rather not share):
            \(appVersion)
            \(deviceInfo)
            """
        )
    }

    private static func mailURL(subject: String, body: String) -> URL {
        var components = URLComponents()
        components.scheme = "mailto"
        components.path = "denis@malina.page"
        components.queryItems = [
            URLQueryItem(name: "subject", value: subject),
            URLQueryItem(name: "body", value: body)
        ]
        return components.url!
    }
    #endif

    private static let relativeFormatter: RelativeDateTimeFormatter = {
        let f = RelativeDateTimeFormatter()
        f.unitsStyle = .short
        return f
    }()
}

private struct AboutSheet: View {
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            HStack(spacing: 10) {
                Image(systemName: "sparkles")
                    .font(.title2)
                    .foregroundStyle(.tint)
                Text("How Slowth works")
                    .font(.title3.weight(.semibold))
                Spacer()
            }

            VStack(alignment: .leading, spacing: 12) {
                InfoRow(icon: "eye.slash.fill",
                        title: "Hide distracting surfaces",
                        detail: "Slowth blocks YouTube Shorts, Instagram and Facebook Reels, plus Explore and trends on X while leaving the rest of each site available.")
                InfoRow(icon: "shield.lefthalf.filled",
                        title: "Block whole sites",
                        detail: "TikTok is replaced with a friendly blocked page. You can opt any site into full block too.")
                InfoRow(icon: "slider.horizontal.3",
                        title: "Per-site control",
                        detail: "Each site has labels that match what it blocks. Instagram and Facebook add a feed mode; TikTok is Off or Block site.")
                InfoRow(icon: "lock.fill",
                        title: "Strict mode (24 h)",
                        detail: "Locks every toggle for 24 hours. Survives restart and force-quit. The only bypass is reinstalling the app.")
                InfoRow(icon: "arrow.triangle.2.circlepath",
                        title: "Self-updating rules",
                        detail: "Safari checks a remote rules file for selector and redirect fixes. Strict mode pauses rule changes until its lock expires.")
            }

            HStack {
                Spacer()
                Button("Done") { dismiss() }
                    .keyboardShortcut(.defaultAction)
            }
        }
        .padding(20)
        .frame(width: 460)
    }
}

private struct HeroCard: View {
    let title: String
    let subtitle: String
    let icon: String
    let gradient: [Color]
    let action: (() -> Void)?
    var onDismiss: (() -> Void)? = nil

    var body: some View {
        Group {
            if let action {
                Button(action: action) { content }
                    .buttonStyle(.plain)
            } else {
                content
            }
        }
        .overlay(alignment: .topTrailing) {
            if let onDismiss {
                Button(action: onDismiss) {
                    Image(systemName: "xmark.circle.fill")
                        #if os(iOS)
                        .font(.system(size: 22))
                        .symbolRenderingMode(.palette)
                        .foregroundStyle(.white, .black.opacity(0.35))
                        .padding(6)
                        .frame(minWidth: 44, minHeight: 44, alignment: .topTrailing)
                        .contentShape(Rectangle())
                        #else
                        .font(.system(size: 14))
                        .symbolRenderingMode(.palette)
                        .foregroundStyle(.white, .black.opacity(0.35))
                        .padding(4)
                        .contentShape(Circle())
                        #endif
                }
                .buttonStyle(.plain)
            }
        }
    }

    private var content: some View {
        VStack(alignment: .leading, spacing: 0) {
            Image(systemName: icon)
                .font(.system(size: 16, weight: .semibold))
                .foregroundStyle(.white)
                .frame(width: 26, height: 26)
                .background(.white.opacity(0.18), in: Circle())
            Spacer(minLength: 8)
            Text(title)
                .font(.callout.weight(.semibold))
                .foregroundStyle(.white)
                .lineLimit(1)
                .minimumScaleFactor(0.7)
            Text(subtitle)
                .font(.caption2.weight(.medium))
                .foregroundStyle(.white.opacity(0.9))
                .lineLimit(2)
        }
        .padding(10)
        .frame(maxWidth: .infinity, minHeight: 96, alignment: .leading)
        .background(
            LinearGradient(colors: gradient, startPoint: .topLeading, endPoint: .bottomTrailing)
        )
        .clipShape(RoundedRectangle(cornerRadius: 14, style: .continuous))
        .shadow(color: gradient.last?.opacity(0.25) ?? .clear, radius: 4, y: 2)
    }
}

#if os(iOS) && canImport(FamilyControls)
private struct DebugStatusRow: View {
    let label: String
    let value: String

    var body: some View {
        HStack {
            Text(label).foregroundStyle(.secondary)
            Spacer()
            Text(value)
        }
        .font(.caption2)
    }
}
#endif

private struct InfoRow: View {
    let icon: String
    let title: String
    let detail: String

    var body: some View {
        HStack(alignment: .top, spacing: 10) {
            Image(systemName: icon)
                .font(.body)
                .foregroundStyle(.tint)
                .frame(width: 22, alignment: .center)
            VStack(alignment: .leading, spacing: 2) {
                Text(title).fontWeight(.semibold)
                Text(detail)
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
    }
}

private struct SupportSheet: View {
    @ObservedObject var tipStore: TipStore
    @Environment(\.dismiss) private var dismiss
    @State private var showThanks = false
    @State private var failedAttempts = 0
    @State private var isRetrying = false

    private static let maxAttempts = 5
    private static let retryCooldown: Duration = .seconds(2)

    private func loadProducts() async {
        await tipStore.loadProducts()
        if tipStore.products.isEmpty {
            failedAttempts += 1
        }
    }

    private func retryTapped() {
        guard !isRetrying, failedAttempts < Self.maxAttempts else { return }
        isRetrying = true
        Task {
            await loadProducts()
            try? await Task.sleep(for: Self.retryCooldown)
            isRetrying = false
        }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            if !tipStore.products.isEmpty {
                HStack(spacing: 10) {
                    Image(systemName: "heart.fill")
                        .font(.title2)
                        .foregroundStyle(.pink)
                    VStack(alignment: .leading) {
                        Text("Support Slowth")
                            .font(.title3.weight(.semibold))
                        Text("Doesn't unlock anything. Just a way to say thanks.")
                            .font(.callout)
                            .foregroundStyle(.secondary)
                    }
                    Spacer()
                }
            }

            if tipStore.isLoadingProducts && tipStore.products.isEmpty {
                ProgressView()
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 16)
            } else if tipStore.products.isEmpty {
                VStack(spacing: 8) {
                    if failedAttempts >= Self.maxAttempts {
                        Text("Looks like this is broken for now")
                            .font(.subheadline.weight(.semibold))
                        Text("We'll fix it soon — come back later.")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                            .multilineTextAlignment(.center)
                    } else {
                        Text("Oops... try again later")
                            .font(.subheadline.weight(.semibold))
                        Text("Something broke. Even for a sloth, this is slow.")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                            .multilineTextAlignment(.center)
                        Button {
                            retryTapped()
                        } label: {
                            if isRetrying {
                                ProgressView().controlSize(.small)
                            } else {
                                Text("Reload")
                            }
                        }
                        .disabled(isRetrying)
                    }
                }
                .frame(maxWidth: .infinity)
                .padding(.vertical, 16)
            } else {
                VStack(spacing: 10) {
                    ForEach(tipStore.products) { product in
                        TipRow(
                            product: product,
                            isPurchasing: tipStore.purchasingProductID == product.id,
                            action: { Task { await tipStore.purchase(product) } }
                        )
                    }
                }
            }

            if showThanks {
                Label("Thanks! It really helps.", systemImage: "heart.fill")
                    .foregroundStyle(.pink)
                    .font(.callout.weight(.semibold))
            }

            if !tipStore.history.isEmpty {
                VStack(alignment: .leading, spacing: 6) {
                    Text("Your support")
                        .font(.callout.weight(.semibold))
                        .foregroundStyle(.secondary)
                    VStack(spacing: 6) {
                        ForEach(tipStore.history) { entry in
                            TipHistoryRow(
                                productID: entry.productID,
                                displayName: tipStore.displayName(for: entry.productID),
                                date: entry.date
                            )
                        }
                    }
                }
            }

            HStack {
                Spacer()
                Button("Done") { dismiss() }
                    .keyboardShortcut(.defaultAction)
            }
        }
        .padding(20)
        .frame(width: 420)
        .task {
            await loadProducts()
        }
        .onChange(of: tipStore.lastPurchasedProductID) { newValue in
            guard newValue != nil else { return }
            withAnimation { showThanks = true }
            tipStore.lastPurchasedProductID = nil
            Task {
                try? await Task.sleep(for: .seconds(2.5))
                withAnimation { showThanks = false }
            }
        }
        .alert("Heads up",
               isPresented: Binding(
                get: { tipStore.lastError != nil },
                set: { if !$0 { tipStore.lastError = nil } })) {
            Button("OK", role: .cancel) { tipStore.lastError = nil }
        } message: {
            Text(tipStore.lastError ?? "")
        }
    }
}

private func tipEmoji(for productID: String) -> String {
    switch productID {
    case TipStore.TipProductID.coffee.rawValue: return "☕️"
    case TipStore.TipProductID.beans.rawValue: return "🫘"
    default: return "🏔️"
    }
}

private struct TipRow: View {
    let product: Product
    let isPurchasing: Bool
    let action: () -> Void

    var body: some View {
        HStack(spacing: 12) {
            Text(tipEmoji(for: product.id))
                .font(.system(size: 26))
            VStack(alignment: .leading, spacing: 2) {
                Text(product.displayName).fontWeight(.semibold)
                Text(product.description)
                    .font(.callout)
                    .foregroundStyle(.secondary)
            }
            Spacer()
            Button(action: action) {
                if isPurchasing {
                    ProgressView().controlSize(.small)
                } else {
                    Text(product.displayPrice)
                }
            }
            .disabled(isPurchasing)
        }
        .padding(10)
        .background(.quaternary.opacity(0.5), in: RoundedRectangle(cornerRadius: 12, style: .continuous))
    }
}

private struct TipHistoryRow: View {
    let productID: String
    let displayName: String
    let date: Date

    var body: some View {
        HStack(spacing: 10) {
            Text(tipEmoji(for: productID))
                .font(.body)
            Text(displayName)
                .font(.callout)
            Spacer()
            Text(date.formatted(date: .abbreviated, time: .omitted))
                .font(.callout)
                .foregroundStyle(.secondary)
        }
    }
}
