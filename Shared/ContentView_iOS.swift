#if os(iOS)
import SwiftUI
import StoreKit
import UIKit
#if canImport(FamilyControls)
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
    .init(id: "youtube",   label: "YouTube Shorts",   modes: [.off, .shorts, .all]),
    .init(id: "instagram", label: "Instagram Reels",  modes: [.off, .shorts, .feed, .all]),
    .init(id: "tiktok",    label: "TikTok",           modes: [.off, .all]),
    .init(id: "facebook",  label: "Facebook Reels",   modes: [.off, .shorts, .feed, .all]),
    .init(id: "x",         label: "X (Twitter)",      modes: [.off, .shorts, .all])
]

private extension View {
    // iPhone-style bottom-sheet detents only make sense in a compact-width
    // context. On full-screen iPad (regular width) they force an
    // undersized, bottom-anchored sheet instead of the platform's normal
    // centered form-sheet — so only apply them when the size class is compact.
    @ViewBuilder
    func compactSheetDetents(isCompact: Bool) -> some View {
        if isCompact {
            self.presentationDetents([.medium, .large])
                .presentationDragIndicator(.visible)
        } else {
            self
        }
    }
}


struct ContentView: View {
    @StateObject private var state = AppState()
    @StateObject private var tipStore = TipStore()
    @StateObject private var debugCaptureLibrary = DebugCapturePhotoLibrary()
    @AppStorage("uiMode") private var uiMode: String = "ios"
    @Environment(\.horizontalSizeClass) private var horizontalSizeClass
    @State private var showSafariHelp = false
    @State private var showAbout = false
    @State private var showSupportSheet = false
    @State private var showRealtimeBlockingBeta = false
    @State private var showRealtimeRecordingPrompt = false
    @AppStorage(DebugMode.storageKey, store: AppGroup.defaults) private var debugModeEnabled = false
    @AppStorage(DebugCaptureSettings.storageKey, store: AppGroup.defaults) private var debugCaptureEnabled = false
    @AppStorage(FeatureFlags.tipsOverrideStorageKey, store: AppGroup.defaults) private var tipsFeatureEnabled = false
    @State private var versionTapCount = 0
    #if canImport(FamilyControls)
    @ObservedObject private var familyControlsAuthorization = AuthorizationCenter.shared
    @State private var isAuthorizingFamilyControls = false
    @State private var showYouTubePicker = false
    @State private var showInstagramPicker = false
    @State private var youtubeSelection = FamilyActivitySelection()
    @State private var instagramSelection = FamilyActivitySelection()
    #endif

    var body: some View {
        NavigationStack {
            Form {
                heroSection
                if state.snapshot.isStrictModeActive {
                    strictBannerSection
                }
                sitesSection
                #if canImport(FamilyControls)
                realtimeShieldSection
                #endif
                strictModeSection
                updatesSection
                if debugModeEnabled {
                    debugSection
                }
                helpSection
            }
            .navigationTitle("Slowth")
            .navigationBarTitleDisplayMode(.large)
        }
        .alert("Heads up",
               isPresented: Binding(
                get: { state.lastError != nil },
                set: { if !$0 { state.lastError = nil } })) {
            Button("OK", role: .cancel) { state.lastError = nil }
        } message: {
            Text(state.lastError ?? "")
        }
        .sheet(isPresented: $showSafariHelp) {
            SafariHelpSheet(openSettings: { state.openSafariExtensionSettings() })
                .compactSheetDetents(isCompact: horizontalSizeClass == .compact)
        }
        .sheet(isPresented: $showAbout) {
            AboutSheet()
                .compactSheetDetents(isCompact: horizontalSizeClass == .compact)
        }
        .sheet(isPresented: $showSupportSheet) {
            SupportSheet(tipStore: tipStore)
                .compactSheetDetents(isCompact: horizontalSizeClass == .compact)
        }
        .sheet(isPresented: $showRealtimeBlockingBeta) {
            RealtimeBlockingBetaSheet(
                feedbackURL: realtimeBlockingFeedbackURL
            )
            .compactSheetDetents(isCompact: horizontalSizeClass == .compact)
        }
        #if canImport(FamilyControls)
        .sheet(isPresented: $showRealtimeRecordingPrompt) {
            RealtimeRecordingPromptSheet(
                preferredExtensionBundleID: state.broadcastExtensionBundleID,
                isRecording: state.snapshot.broadcastActive
            )
            .compactSheetDetents(isCompact: horizontalSizeClass == .compact)
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
        .onAppear {
            if !debugModeEnabled {
                debugCaptureEnabled = false
            }
            debugCaptureLibrary.refresh(importIfPossible: debugCaptureEnabled)
        }
        .onReceive(NotificationCenter.default.publisher(for: UIApplication.didBecomeActiveNotification)) { _ in
            debugCaptureLibrary.refresh(importIfPossible: debugCaptureEnabled)
        }
        .onChange(of: debugModeEnabled) { enabled in
            if !enabled {
                debugCaptureEnabled = false
            }
        }
        .onChange(of: debugCaptureEnabled) { enabled in
            guard enabled else { return }
            debugCaptureLibrary.requestAccessAndImport()
        }
    }

    private var disabledByStrict: Bool { state.snapshot.isStrictModeActive }

    #if canImport(FamilyControls)
    private func presentRealtimeRecordingPromptIfRequested() {
        guard SharedStore.consumeRealtimeRecordingPromptRequest() else { return }
        state.reload()
        showRealtimeRecordingPrompt = true
    }
    #endif

    private var heroSection: some View {
        Section {
            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 12) {
                    HeroCard(
                        title: "Real-time blocking",
                        subtitle: "Shorts, Reels & Stories · Beta",
                        icon: "record.circle.fill",
                        gradient: [Color(red: 0.98, green: 0.24, blue: 0.34),
                                   Color(red: 0.79, green: 0.12, blue: 0.45)],
                        action: { showRealtimeBlockingBeta = true }
                    )
                    HeroCard(
                        title: "How it works",
                        subtitle: "What Slowth does for you",
                        icon: "sparkles",
                        gradient: [Color(red: 0.36, green: 0.46, blue: 0.95),
                                   Color(red: 0.55, green: 0.32, blue: 0.86)],
                        action: { showAbout = true }
                    )
                    HeroCard(
                        title: "Safari",
                        subtitle: "Enable in extensions",
                        icon: "safari.fill",
                        gradient: [Color(red: 0.21, green: 0.65, blue: 0.97),
                                   Color(red: 0.14, green: 0.45, blue: 0.84)],
                        action: { showSafariHelp = true }
                    )
                    HeroCard(
                        title: state.snapshot.isStrictModeActive ? "Locked" : "Strict",
                        subtitle: state.snapshot.isStrictModeActive
                            ? "24 h lock active"
                            : "Lock for 24 hours",
                        icon: state.snapshot.isStrictModeActive ? "lock.fill" : "lock.open.fill",
                        gradient: state.snapshot.isStrictModeActive
                            ? [Color(red: 0.95, green: 0.31, blue: 0.27),
                               Color(red: 0.78, green: 0.18, blue: 0.34)]
                            : [Color(red: 0.97, green: 0.61, blue: 0.20),
                               Color(red: 0.93, green: 0.39, blue: 0.18)],
                        action: state.snapshot.isStrictModeActive
                            ? nil
                            : { state.setStrictMode(true) }
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
                .padding(.horizontal, 16)
                .padding(.vertical, 12)
            }
            .listRowInsets(EdgeInsets())
            .listRowBackground(Color.clear)
            .listRowSeparator(.hidden)
        }
    }

    private var strictBannerSection: some View {
        Section {
            HStack(alignment: .firstTextBaseline, spacing: 8) {
                Image(systemName: "lock.fill")
                    .foregroundStyle(.orange)
                VStack(alignment: .leading, spacing: 2) {
                    Text("Strict mode active")
                        .font(.subheadline.weight(.semibold))
                    if let until = state.snapshot.strictModeUntil {
                        Text("Locked until \(until.formatted(date: .abbreviated, time: .shortened))")
                            .font(.footnote)
                            .foregroundStyle(.secondary)
                    }
                }
            }
        }
    }

    private var sitesSection: some View {
        Section {
            ForEach(sites) { site in
                Picker(site.label, selection: bindingForSite(site.id)) {
                    ForEach(site.modes, id: \.self) { mode in
                        Text(modeLabel(mode)).tag(mode)
                    }
                }
                .disabled(disabledByStrict)
            }
        } header: {
            Text("Sites")
        } footer: {
            Text("Off — extension does nothing. Block shorts — hide reels & shorts. Block shorts + feed — also blocks the infinite feed (Facebook & Instagram). Block site — redirect the whole site.")
        }
    }

    #if canImport(FamilyControls)
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
                        if isAuthorizingFamilyControls { ProgressView() }
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
        return "Tap anywhere here to start."
    }

    private func decodedSelection(_ data: Data?) -> FamilyActivitySelection {
        guard let data, let decoded = try? JSONDecoder().decode(FamilyActivitySelection.self, from: data) else {
            return FamilyActivitySelection()
        }
        return decoded
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
    #endif

    private var strictModeSection: some View {
        Section {
            Toggle(isOn: Binding(
                get: { state.snapshot.isStrictModeActive },
                set: { newValue in state.setStrictMode(newValue) }
            )) {
                Text("Strict mode (24 h lock)")
            }
            .disabled(disabledByStrict)
        } footer: {
            Text("Locks all settings for 24 hours. Cannot be disabled early.")
        }
    }

    private var updatesSection: some View {
        Section {
            Button {
                Task { await state.forceRefresh() }
            } label: {
                HStack {
                    Text("Update rules now")
                    Spacer()
                    if state.refreshing {
                        ProgressView()
                    }
                }
            }
            .disabled(state.refreshing || disabledByStrict)

            HStack {
                Text("Last update")
                    .foregroundStyle(.secondary)
                Spacer()
                Text(rulesStatusText)
                    .foregroundStyle(.secondary)
                    .font(.footnote)
            }
        } header: {
            Text("Rules")
        } footer: {
            Text(rulesFooterText)
        }
    }

    private var helpSection: some View {
        Section {
            Link(destination: feedbackURL) {
                HStack {
                    Text("Send feedback")
                    Spacer()
                    Image(systemName: "envelope")
                        .foregroundStyle(.secondary)
                }
            }
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
            }
        } header: {
            Text("Help")
        } footer: {
            Button(action: appVersionTapped) {
                Text(appVersion)
            }
            .buttonStyle(.plain)
        }
    }

    private var debugSection: some View {
        Section {
            Toggle("Debug mode", isOn: $debugModeEnabled)
            Toggle("Save detection frames", isOn: $debugCaptureEnabled)
            if debugCaptureEnabled {
                DebugStatusRow(
                    label: "Photos access",
                    value: debugCaptureLibrary.authorizationText
                )
                DebugStatusRow(
                    label: "Pending captures",
                    value: "\(debugCaptureLibrary.pendingEvents) · \(debugCapturePendingSize)"
                )
                DebugStatusRow(
                    label: "Saved events",
                    value: "\(debugCaptureLibrary.savedEvents)"
                )
                if let error = debugCaptureLibrary.lastError {
                    DebugStatusRow(label: "Capture error", value: error)
                }
                if debugCaptureLibrary.authorizationStatus == .authorized
                    || debugCaptureLibrary.authorizationStatus == .limited {
                    Button {
                        debugCaptureLibrary.importPending()
                    } label: {
                        HStack {
                            Text("Save pending frames to Photos")
                            Spacer()
                            if debugCaptureLibrary.isImporting { ProgressView() }
                        }
                    }
                    .disabled(
                        debugCaptureLibrary.isImporting
                            || debugCaptureLibrary.pendingEvents == 0
                    )
                } else {
                    Button("Allow Photos access") {
                        debugCaptureLibrary.requestAccessAndImport()
                    }
                }
                Button("Clear pending capture queue", role: .destructive) {
                    debugCaptureLibrary.clearPending()
                }
                .disabled(debugCaptureLibrary.pendingEvents == 0)
            }
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
            Text("Detection capture is off by default and local only. When enabled, three model-input frames from each confirmed 3-of-5 trigger are saved to Photos. Frames may contain private screen content. Albums are grouped in “Slowth — Triggers”.")
        }
    }

    private var debugCapturePendingSize: String {
        ByteCountFormatter.string(
            fromByteCount: debugCaptureLibrary.pendingBytes,
            countStyle: .file
        )
    }

    private func appVersionTapped() {
        guard !debugModeEnabled else { return }
        versionTapCount += 1
        guard versionTapCount >= DebugMode.requiredVersionTapCount else { return }
        versionTapCount = 0
        debugModeEnabled = true
    }

    private func bindingForSite(_ siteID: String) -> Binding<SiteMode> {
        Binding(
            get: { state.mode(for: siteID) },
            set: { state.setMode($0, for: siteID) }
        )
    }

    // ⚠️ Mode labels mirror the JS popup map in WebExt/app.js — keep in sync.
    private func modeLabel(_ mode: SiteMode) -> String {
        switch mode {
        case .off: return "Off"
        case .shorts: return "Block shorts"
        case .feed: return "Block shorts + feed"
        case .all: return "Block site"
        }
    }

    private var rulesStatusText: String {
        if let date = state.snapshot.rulesFetchedAt {
            return Self.relativeFormatter.localizedString(for: date, relativeTo: Date())
        }
        return "Never"
    }

    private var rulesFooterText: String {
        switch state.lastRefreshOutcome {
        case .updated?: return "Rules updated."
        case .notModified?: return "Rules already up to date."
        case .failed(let reason)?: return "Update failed (\(reason))."
        case .none: return "Rules are pulled from a remote GitHub Gist every 6 hours."
        }
    }

    private var appVersion: String {
        let v = Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "0.0.0"
        let b = Bundle.main.infoDictionary?["CFBundleVersion"] as? String ?? "0"
        return "v\(v) (\(b))"
    }

    private var deviceInfo: String {
        let device = UIDevice.current
        return "\(device.systemName) \(device.systemVersion), \(device.model)"
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

    private static let relativeFormatter: RelativeDateTimeFormatter = {
        let f = RelativeDateTimeFormatter()
        f.unitsStyle = .short
        return f
    }()
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
            if let action = action {
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
                        .font(.system(size: 24))
                        .symbolRenderingMode(.palette)
                        .foregroundStyle(.white, .black.opacity(0.35))
                        .padding(8)
                        .frame(minWidth: 44, minHeight: 44, alignment: .topTrailing)
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
            }
        }
    }

    private var content: some View {
        VStack(alignment: .leading, spacing: 0) {
            Image(systemName: icon)
                .font(.system(size: 24, weight: .semibold))
                .foregroundStyle(.white)
                .frame(width: 36, height: 36)
                .background(.white.opacity(0.18), in: Circle())
            Spacer(minLength: 12)
            Text(title)
                .font(.title2.bold())
                .foregroundStyle(.white)
                .lineLimit(1)
                .minimumScaleFactor(0.7)
            Text(subtitle)
                .font(.caption.weight(.medium))
                .foregroundStyle(.white.opacity(0.9))
                .lineLimit(2)
        }
        .padding(16)
        .frame(width: 180, height: 140, alignment: .leading)
        .background(
            LinearGradient(colors: gradient, startPoint: .topLeading, endPoint: .bottomTrailing)
        )
        .clipShape(RoundedRectangle(cornerRadius: 22, style: .continuous))
        .shadow(color: gradient.last?.opacity(0.25) ?? .clear, radius: 8, y: 4)
    }
}

private struct SafariHelpSheet: View {
    let openSettings: () -> Void
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: 20) {
                    HStack(spacing: 12) {
                        Image(systemName: "safari.fill")
                            .font(.title)
                            .foregroundStyle(.white)
                            .frame(width: 44, height: 44)
                            .background(
                                LinearGradient(
                                    colors: [Color(red: 0.21, green: 0.65, blue: 0.97),
                                             Color(red: 0.14, green: 0.45, blue: 0.84)],
                                    startPoint: .topLeading, endPoint: .bottomTrailing
                                ),
                                in: RoundedRectangle(cornerRadius: 12, style: .continuous)
                            )
                        VStack(alignment: .leading) {
                            Text("Enable Slowth in Safari")
                                .font(.title3.weight(.semibold))
                            Text("Apple doesn't allow apps to deep-link directly into the Safari extensions list. Follow the steps below.")
                                .font(.footnote)
                                .foregroundStyle(.secondary)
                        }
                    }

                    VStack(alignment: .leading, spacing: 14) {
                        StepRow(number: 1, title: "Open Settings",
                                detail: "Tap the button below — it opens iOS Settings.")
                        StepRow(number: 2, title: "Go to Apps → Safari → Extensions",
                                detail: "Scroll the apps list, tap Safari, then Extensions.")
                        StepRow(number: 3, title: "Turn on Slowth",
                                detail: "Toggle Slowth on. iOS may ask for permissions.")
                        StepRow(number: 4, title: "Allow on every website",
                                detail: "Tap Slowth → Permissions → All Websites → Allow. Without this, the extension can't hide Shorts.")
                    }

                    Button {
                        openSettings()
                    } label: {
                        Text("Open Settings")
                            .frame(maxWidth: .infinity)
                    }
                    .buttonStyle(.borderedProminent)
                    .controlSize(.large)
                }
                .padding(20)
            }
            .navigationTitle("Enable in Safari")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Done") { dismiss() }
                }
            }
        }
    }
}

private struct AboutSheet: View {
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: 20) {
                    HStack(spacing: 12) {
                        Image(systemName: "sparkles")
                            .font(.title)
                            .foregroundStyle(.white)
                            .frame(width: 44, height: 44)
                            .background(
                                LinearGradient(
                                    colors: [Color(red: 0.36, green: 0.46, blue: 0.95),
                                             Color(red: 0.55, green: 0.32, blue: 0.86)],
                                    startPoint: .topLeading, endPoint: .bottomTrailing
                                ),
                                in: RoundedRectangle(cornerRadius: 12, style: .continuous)
                            )
                        VStack(alignment: .leading) {
                            Text("How Slowth works")
                                .font(.title3.weight(.semibold))
                            Text("A Safari extension that quietly hides infinite‑scroll feeds.")
                                .font(.footnote)
                                .foregroundStyle(.secondary)
                        }
                    }

                    VStack(alignment: .leading, spacing: 14) {
                        InfoRow(icon: "eye.slash.fill", tint: .blue,
                                title: "Hide Shorts & Reels",
                                detail: "On YouTube, Instagram, Facebook and X, Slowth hides the Shorts/Reels tab, ribbon and feed entries.")
                        InfoRow(icon: "shield.lefthalf.filled", tint: .indigo,
                                title: "Block whole sites",
                                detail: "TikTok is replaced with a friendly blocked page. You can opt any site into full block too.")
                        InfoRow(icon: "slider.horizontal.3", tint: .purple,
                                title: "Per‑site control",
                                detail: "For each site choose Off, Block shorts, Block shorts + feed, or Block site. Facebook & Instagram add the feed option; TikTok is Off or Block.")
                        InfoRow(icon: "lock.fill", tint: .orange,
                                title: "Strict mode (24 h)",
                                detail: "Locks every toggle for 24 hours. Survives restart and force‑quit. The only bypass is reinstalling the app.")
                        InfoRow(icon: "arrow.triangle.2.circlepath", tint: .green,
                                title: "Self‑updating rules",
                                detail: "Selectors and redirects are pulled from a remote rules file, so the extension keeps working when sites change their layout.")
                    }
                }
                .padding(20)
            }
            .navigationTitle("How it works")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Done") { dismiss() }
                }
            }
        }
    }
}

#if canImport(FamilyControls)
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

private struct StepRow: View {
    let number: Int
    let title: String
    let detail: String

    var body: some View {
        HStack(alignment: .top, spacing: 12) {
            Text("\(number)")
                .font(.subheadline.weight(.bold))
                .foregroundStyle(.white)
                .frame(width: 28, height: 28)
                .background(Color.accentColor, in: Circle())
            VStack(alignment: .leading, spacing: 4) {
                Text(title).font(.subheadline.weight(.semibold))
                Text(detail).font(.footnote).foregroundStyle(.secondary)
            }
        }
    }
}

private struct InfoRow: View {
    let icon: String
    let tint: Color
    let title: String
    let detail: String

    var body: some View {
        HStack(alignment: .top, spacing: 12) {
            Image(systemName: icon)
                .font(.callout)
                .foregroundStyle(.white)
                .frame(width: 28, height: 28)
                .background(tint, in: RoundedRectangle(cornerRadius: 8, style: .continuous))
            VStack(alignment: .leading, spacing: 4) {
                Text(title).font(.subheadline.weight(.semibold))
                Text(detail).font(.footnote).foregroundStyle(.secondary)
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
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: 20) {
                    if !tipStore.products.isEmpty {
                        HStack(spacing: 12) {
                            Image(systemName: "heart.fill")
                                .font(.title)
                                .foregroundStyle(.white)
                                .frame(width: 44, height: 44)
                                .background(
                                    LinearGradient(
                                        colors: [Color(red: 0.95, green: 0.42, blue: 0.55),
                                                 Color(red: 0.85, green: 0.20, blue: 0.45)],
                                        startPoint: .topLeading, endPoint: .bottomTrailing
                                    ),
                                    in: RoundedRectangle(cornerRadius: 12, style: .continuous)
                                )
                            VStack(alignment: .leading) {
                                Text("Support Slowth")
                                    .font(.title3.weight(.semibold))
                                Text("Doesn't unlock anything. Just a way to say thanks.")
                                    .font(.footnote)
                                    .foregroundStyle(.secondary)
                            }
                        }
                    }

                    if tipStore.isLoadingProducts && tipStore.products.isEmpty {
                        ProgressView()
                            .frame(maxWidth: .infinity)
                            .padding(.vertical, 24)
                    } else if tipStore.products.isEmpty {
                        VStack(spacing: 10) {
                            if failedAttempts >= Self.maxAttempts {
                                Text("Looks like this is broken for now")
                                    .font(.subheadline.weight(.semibold))
                                Text("We'll fix it soon — come back later.")
                                    .font(.footnote)
                                    .foregroundStyle(.secondary)
                                    .multilineTextAlignment(.center)
                            } else {
                                Text("Oops... try again later")
                                    .font(.subheadline.weight(.semibold))
                                Text("Something broke. Even for a sloth, this is slow.")
                                    .font(.footnote)
                                    .foregroundStyle(.secondary)
                                    .multilineTextAlignment(.center)
                                Button {
                                    retryTapped()
                                } label: {
                                    if isRetrying {
                                        ProgressView()
                                    } else {
                                        Text("Reload")
                                    }
                                }
                                .buttonStyle(.bordered)
                                .disabled(isRetrying)
                            }
                        }
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, 24)
                    } else {
                        VStack(spacing: 12) {
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
                            .font(.subheadline.weight(.semibold))
                            .frame(maxWidth: .infinity)
                    }

                    if !tipStore.history.isEmpty {
                        VStack(alignment: .leading, spacing: 8) {
                            Text("Your support")
                                .font(.footnote.weight(.semibold))
                                .foregroundStyle(.secondary)
                            VStack(spacing: 8) {
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
                }
                .padding(20)
            }
            .navigationTitle("Support")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Done") { dismiss() }
                }
            }
        }
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
        HStack(spacing: 14) {
            Text(tipEmoji(for: product.id))
                .font(.system(size: 32))
            VStack(alignment: .leading, spacing: 2) {
                Text(product.displayName)
                    .font(.subheadline.weight(.semibold))
                Text(product.description)
                    .font(.footnote)
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
            .buttonStyle(.borderedProminent)
            .disabled(isPurchasing)
        }
        .padding(14)
        .background(.quaternary.opacity(0.5), in: RoundedRectangle(cornerRadius: 14, style: .continuous))
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
                .font(.footnote)
            Spacer()
            Text(date.formatted(date: .abbreviated, time: .omitted))
                .font(.footnote)
                .foregroundStyle(.secondary)
        }
    }
}

#Preview {
    ContentView()
}
#endif
