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
}

private let sites: [SiteSpec] = [
    .init(id: "youtube", label: "YouTube"),
    .init(id: "instagram", label: "Instagram"),
    .init(id: "tiktok", label: "TikTok"),
    .init(id: "facebook", label: "Facebook"),
    .init(id: "x", label: "X")
]


struct MacContentView: View {
    @StateObject private var state = AppState()
    @StateObject private var tipStore = TipStore()
    #if os(macOS)
    @AppStorage(AppLocalization.languageKey) private var appLanguage = ""
    #endif
    @State private var showAbout = false
    @State private var showSupportSheet = false
    @State private var showRealtimeBlockingBeta = false
    @State private var showStrictModeConfirmation = false
    #if DEBUG
    @AppStorage(DebugMode.storageKey, store: AppGroup.defaults) private var debugModeEnabled = false
    @AppStorage(DebugModelSettings.storageKey, store: AppGroup.defaults) private var debugModelBackend = DebugModelSettings.defaultBackend.rawValue
    @AppStorage(FeatureFlags.tipsOverrideStorageKey, store: AppGroup.defaults) private var tipsFeatureEnabled = false
    @State private var versionTapCount = 0
    #endif
    #if os(iOS)
    @AppStorage("uiMode") private var uiMode: String = "ios"
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
                ScrollView(.horizontal, showsIndicators: false) {
                    HStack(spacing: 10) {
                        #if os(iOS)
                        HeroCard(
                            title: AppLocalization.string("Real-time blocking"),
                            subtitle: AppLocalization.string("Shorts, Reels & Stories"),
                            icon: "record.circle.fill",
                            gradient: [Color(red: 0.98, green: 0.24, blue: 0.34),
                                       Color(red: 0.79, green: 0.12, blue: 0.45)],
                            action: { showRealtimeBlockingBeta = true }
                        )
                        #else
                        HeroCard(
                            title: AppLocalization.string("New on iOS"),
                            subtitle: AppLocalization.string("Real-time blocking"),
                            icon: "iphone.gen3.radiowaves.left.and.right",
                            gradient: [Color(red: 0.98, green: 0.24, blue: 0.34),
                                       Color(red: 0.79, green: 0.12, blue: 0.45)],
                            action: { showRealtimeBlockingBeta = true }
                        )
                        #endif
                        HeroCard(
                            title: AppLocalization.string("How it works"),
                            subtitle: AppLocalization.string("What Slowth does"),
                            icon: "sparkles",
                            gradient: [Color(red: 0.36, green: 0.46, blue: 0.95),
                                       Color(red: 0.55, green: 0.32, blue: 0.86)],
                            action: { showAbout = true }
                        )
                        HeroCard(
                            title: "Safari",
                            subtitle: AppLocalization.string("Enable extension"),
                            icon: "safari.fill",
                            gradient: [Color(red: 0.21, green: 0.65, blue: 0.97),
                                       Color(red: 0.14, green: 0.45, blue: 0.84)],
                            action: { state.openSafariExtensionSettings() }
                        )
                        HeroCard(
                            title: state.snapshot.isStrictModeActive ? AppLocalization.string("Locked") : AppLocalization.string("Strict"),
                            subtitle: state.snapshot.isStrictModeActive
                                ? AppLocalization.string("24 h lock active")
                                : AppLocalization.string("Lock for 24 hours"),
                            icon: state.snapshot.isStrictModeActive ? "lock.fill" : "lock.open.fill",
                            gradient: state.snapshot.isStrictModeActive
                                ? [Color(red: 0.95, green: 0.31, blue: 0.27),
                                   Color(red: 0.78, green: 0.18, blue: 0.34)]
                                : [Color(red: 0.97, green: 0.61, blue: 0.20),
                                   Color(red: 0.93, green: 0.39, blue: 0.18)],
                            action: state.snapshot.isStrictModeActive
                                ? nil
                                : { showStrictModeConfirmation = true }
                        )
                        if FeatureFlags.tipsEnabled && !state.snapshot.supportCardDismissed {
                            HeroCard(
                                title: AppLocalization.string("Support"),
                                subtitle: AppLocalization.string("Tip the developer"),
                                icon: "heart.fill",
                                gradient: [Color(red: 0.95, green: 0.42, blue: 0.55),
                                           Color(red: 0.85, green: 0.20, blue: 0.45)],
                                action: { showSupportSheet = true },
                                onDismiss: { state.dismissSupportCard() }
                            )
                        }
                    }
                    .padding(.vertical, 2)
                }
                .listRowInsets(EdgeInsets(top: 8, leading: 8, bottom: 8, trailing: 8))
            }

            if state.snapshot.isStrictModeActive {
                Section {
                    HStack(spacing: 8) {
                        Image(systemName: "lock.fill")
                            .foregroundStyle(.orange)
                        VStack(alignment: .leading, spacing: 2) {
                            Text(AppLocalization.string("Strict mode active")).fontWeight(.semibold)
                            if let until = state.snapshot.strictModeUntil {
                                Text(AppLocalization.string("Locked until \(L10n.dateTime(until))"))
                                    .font(.callout)
                                    .foregroundStyle(.secondary)
                            }
                        }
                    }
                }
            }

            #if os(iOS) && canImport(FamilyControls)
            realtimeShieldSection
            #endif

            Section {
                ForEach(sites) { site in
                    ForEach(SiteBlockingControl.controls(for: site.id)) { control in
                        Toggle(isOn: bindingForSite(control.site, feature: control.feature)) {
                            if control.feature == .all {
                                Text(site.label).fontWeight(.semibold)
                                    + Text(verbatim: " — ")
                                    + Text(control.feature.label(for: control.site)).foregroundColor(.secondary)
                            } else {
                                Text(control.feature.label(for: control.site))
                            }
                        }
                            .padding(.vertical, control.feature == .all ? 6 : 0)
                            .padding(.leading, control.feature == .all ? 8 : 16)
                            .padding(.trailing, 8)
                            .background {
                                if control.feature == .all {
                                    RoundedRectangle(cornerRadius: 8)
                                        .fill(Color.accentColor.opacity(0.08))
                                }
                            }
                            .disabled((disabledByStrict &&
                                       (control.feature == .all || state.setting(control.feature, for: control.site))) ||
                                      (control.feature != .all && state.setting(.all, for: control.site)))
                            .accessibilityIdentifier(control.id)
                    }
                }
            } header: {
                Text(AppLocalization.string("Safari extension settings"))
            } footer: {
                Text(AppLocalization.string("Infinite Feed limits scrolling. On Instagram it also includes Explore and Stories."))
                    .font(.callout)
                    .foregroundStyle(.secondary)
            }

            Section {
                Toggle(isOn: Binding(
                    get: { state.snapshot.isStrictModeActive },
                    set: { newValue in
                        if newValue { showStrictModeConfirmation = true }
                        else { state.setStrictMode(false) }
                    }
                )) {
                    VStack(alignment: .leading, spacing: 2) {
                        Text(AppLocalization.string("Strict mode"))
                        Text(AppLocalization.string("For 24 hours, enabled restrictions cannot be turned off. You can add restrictions, but cannot enable whole-site blocking."))
                            .font(.callout)
                            .foregroundStyle(.secondary)
                    }
                }
                .disabled(disabledByStrict && state.snapshot.realtimeShieldEnabled)
            } header: {
                Text(AppLocalization.string("Strict mode"))
            }

            Section {
                HStack {
                    Button {
                        Task { await state.forceRefresh() }
                    } label: {
                        if state.refreshing {
                            HStack(spacing: 6) {
                                ProgressView().controlSize(.small)
                                Text(AppLocalization.string("Updating…"))
                            }
                        } else {
                            Text(AppLocalization.string("Update rules now"))
                        }
                    }
                    .disabled(state.refreshing || disabledByStrict)

                    Spacer()

                    Text(rulesStatusText)
                        .foregroundStyle(.secondary)
                        .font(.callout)
                }
            } header: {
                Text(AppLocalization.string("Rules"))
            } footer: {
                Text(rulesFooterText)
                    .font(.callout)
                    .foregroundStyle(.secondary)
            }

            #if DEBUG
            if debugModeEnabled {
                debugSection
            }
            #endif

            Section {
                Link(AppLocalization.string("Send feedback"), destination: feedbackURL)
                if FeatureFlags.tipsEnabled {
                    Button {
                        showSupportSheet = true
                    } label: {
                        HStack {
                            Text(AppLocalization.string("Support"))
                            Spacer()
                            Image(systemName: "heart.fill")
                                .foregroundStyle(.secondary)
                        }
                    }
                    .buttonStyle(.plain)
                }
                #if os(macOS)
                Picker(AppLocalization.string("Language"), selection: $appLanguage) {
                    Text(AppLocalization.string("System default")).tag("")
                    ForEach(AppLocalization.availableLanguages, id: \.self) { identifier in
                        Text(verbatim: AppLocalization.languageName(identifier)).tag(identifier)
                    }
                }
                .accessibilityIdentifier("app.language")
                #endif
            } header: {
                Text(AppLocalization.string("Help"))
            } footer: {
                #if DEBUG
                Button(action: appVersionTapped) {
                    Text(appVersion)
                        .font(.callout)
                        .foregroundStyle(.secondary)
                }
                .buttonStyle(.plain)
                #else
                Text(appVersion)
                #endif
            }
        }
        .formStyle(.grouped)
        .navigationTitle("Slowth")
        .alert(AppLocalization.string("Heads up"),
               isPresented: Binding(
                get: { state.lastError != nil },
                set: { if !$0 { state.lastError = nil } })) {
            Button(AppLocalization.string("OK"), role: .cancel) { state.lastError = nil }
        } message: {
            Text(state.lastError ?? "")
        }
        .alert(AppLocalization.string("Enable Strict mode?"), isPresented: $showStrictModeConfirmation) {
            Button(AppLocalization.string("Enable")) { state.setStrictMode(true) }
            Button(AppLocalization.string("Cancel"), role: .cancel) { }
        } message: {
            Text(AppLocalization.string("For 24 hours, enabled restrictions cannot be turned off. You can add restrictions, but cannot enable whole-site blocking."))
        }
        .sheet(isPresented: $showAbout) {
            AboutSheet()
        }
        .sheet(isPresented: $showSupportSheet) {
            SupportSheet(tipStore: tipStore)
        }
        .sheet(isPresented: $showRealtimeBlockingBeta) {
            RealtimeBlockingBetaSheet(
                feedbackURL: realtimeBlockingFeedbackURL
            )
        }
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
                Text(AppLocalization.string("Real-time app blocking"))
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
                        Text(AppLocalization.string("Allow Screen Time access"))
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
                        Text(AppLocalization.string("Choose YouTube app"))
                        Spacer()
                        if state.hasYouTubeSelection {
                            Image(systemName: "checkmark.circle.fill").foregroundStyle(.green)
                        }
                    }
                }
                .buttonStyle(.plain)
                .disabled(disabledByStrict && state.hasYouTubeSelection)

                Toggle(AppLocalization.string("Block YouTube Shorts"), isOn: Binding(
                    get: { state.snapshot.realtimeYouTubeBlockingEnabled },
                    set: { state.setRealtimeYouTubeBlockingEnabled($0) }
                ))
                .disabled((disabledByStrict && state.snapshot.realtimeYouTubeBlockingEnabled) || !state.hasYouTubeSelection)

                Toggle(AppLocalization.string("Soft YouTube blocking"), isOn: Binding(
                    get: { state.snapshot.softYouTubeBlockingEnabled },
                    set: { state.setSoftYouTubeBlockingEnabled($0) }
                ))
                .disabled(
                    disabledByStrict && state.snapshot.softYouTubeBlockingEnabled
                        || !state.hasYouTubeSelection
                        || !state.snapshot.realtimeYouTubeBlockingEnabled
                )

                Text(AppLocalization.string("Soft mode works well for audio podcasts. Picture in Picture may still be blocked when screen recording is off."))
                    .font(.caption)
                    .foregroundStyle(.secondary)

                Button {
                    instagramSelection = decodedSelection(state.snapshot.instagramSelectionData)
                    showInstagramPicker = true
                } label: {
                    HStack {
                        Text(AppLocalization.string("Choose Instagram app"))
                        Spacer()
                        if state.hasInstagramSelection {
                            Image(systemName: "checkmark.circle.fill").foregroundStyle(.green)
                        }
                    }
                }
                .buttonStyle(.plain)
                .disabled(disabledByStrict && state.hasInstagramSelection)

                Toggle(AppLocalization.string("Block Instagram Reels"), isOn: Binding(
                    get: { state.snapshot.realtimeInstagramReelsBlockingEnabled },
                    set: { state.setRealtimeInstagramReelsBlockingEnabled($0) }
                ))
                .disabled((disabledByStrict && state.snapshot.realtimeInstagramReelsBlockingEnabled) || !state.hasInstagramSelection)

                Toggle(AppLocalization.string("Block Instagram Stories"), isOn: Binding(
                    get: { state.snapshot.realtimeInstagramStoriesBlockingEnabled },
                    set: { state.setRealtimeInstagramStoriesBlockingEnabled($0) }
                ))
                .disabled((disabledByStrict && state.snapshot.realtimeInstagramStoriesBlockingEnabled) || !state.hasInstagramSelection)

                #if DEBUG
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
                #endif
            }
        } header: {
            Text(AppLocalization.string("Block content in apps"))
        } footer: {
            Text(AppLocalization.string("Choose YouTube or Instagram, then enable the content you want to block. Enabled apps stay blocked unless you're recording your screen. Optional soft YouTube mode works well for audio podcasts, but Picture in Picture may still be blocked when recording is off. Pick one app icon per service, not a category or \"All Apps\"."))
                .font(.callout)
                .foregroundStyle(.secondary)
        }
    }

    private var realtimeRecordingGuidance: String {
        if !FamilyControlsAuth.isAuthorized(familyControlsAuthorization.authorizationStatus) {
            return AppLocalization.string("Allow Screen Time access below to finish setup.")
        }
        let youtubeReady = state.hasYouTubeSelection
            && state.snapshot.realtimeYouTubeBlockingEnabled
        let instagramReady = state.hasInstagramSelection
            && state.snapshot.realtimeInstagramBlockingEnabled
        if !youtubeReady && !instagramReady {
            return AppLocalization.string("Choose an app and enable at least one blocking option below.")
        }
        return AppLocalization.string("Tap the red button to start screen recording.")
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

    private func bindingForSite(_ siteID: String, feature: SiteFeature) -> Binding<Bool> {
        Binding(
            get: { state.setting(feature, for: siteID) },
            set: { state.setSetting(feature, enabled: $0, for: siteID) }
        )
    }

    #if DEBUG
    private var debugSection: some View {
        Section {
            Toggle("Debug mode", isOn: $debugModeEnabled)
            #if os(iOS)
            DebugSessionCaptureControls()
            if DebugModelSettings.cascadeAvailable {
                Picker("Model for next recording", selection: Binding(
                    get: { DebugModelSettings.selection(stored: debugModelBackend).rawValue },
                    set: { debugModelBackend = $0 }
                )) {
                    ForEach(DebugModelBackend.allCases, id: \.rawValue) { backend in
                        Text(backend.title).tag(backend.rawValue)
                    }
                }
                Text("Stop screen recording, choose a model, then start recording again. Turning Debug mode off selects Cascade V6 for the next recording. V14 is experimental and unqualified: validation quality gates failed. V15 and Cascade V6 are experimental and unqualified: validation quality gates failed. V15 CoreML parity failed on validation (Stories threshold and temporal trace mismatch). Cascade V6 CoreML parity passed; device qualification is still pending.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            } else {
                Text("Model selection is unavailable in this build.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            #endif
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

    #endif
    private var rulesStatusText: String {
        if let date = state.snapshot.rulesFetchedAt {
            return AppLocalization.string("Updated \(Self.relativeFormatter.localizedString(for: date, relativeTo: Date()))")
        }
        return AppLocalization.string("Never updated")
    }

    private var rulesFooterText: String {
        switch state.lastRefreshOutcome {
        case .updated?: return AppLocalization.string("Rules updated.")
        case .notModified?: return AppLocalization.string("Rules already up to date.")
        case .failed(let reason)?: return AppLocalization.string("Update failed (\(L10n.refreshError(reason))).")
        case .none: return AppLocalization.string("Safari checks for remote rule updates every 6 hours. Strict mode pauses rule changes until the lock expires.")
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
            URLQueryItem(name: "subject", value: AppLocalization.string("Slowth feedback")),
            URLQueryItem(name: "body", value: AppLocalization.string("\n\n(Helps me debug — delete if you'd rather not share.)\n\(appVersion)\n\(deviceInfo)"))
        ]
        return components.url!
    }

    private var realtimeBlockingFeedbackURL: URL {
        Self.mailURL(
            subject: AppLocalization.string("Slowth — Real-time blocking feedback"),
            body: AppLocalization.string("""
            Tell me what happened:


            App and device details (you can delete these if you'd rather not share):
            \(appVersion)
            \(deviceInfo)
            """)
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

    private static var relativeFormatter: RelativeDateTimeFormatter {
        let f = RelativeDateTimeFormatter()
        f.unitsStyle = .short
        f.locale = L10n.locale
        return f
    }
}

private struct AboutSheet: View {
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            HStack(spacing: 10) {
                Image(systemName: "sparkles")
                    .font(.title2)
                    .foregroundStyle(.tint)
                Text(AppLocalization.string("How Slowth works"))
                    .font(.title3.weight(.semibold))
                Spacer()
            }

            VStack(alignment: .leading, spacing: 12) {
                InfoRow(icon: "eye.slash.fill",
                        title: AppLocalization.string("Hide distracting surfaces"),
                        detail: AppLocalization.string("Slowth blocks YouTube Shorts, Instagram and Facebook Reels, plus Explore and trends on X while leaving the rest of each site available."))
                InfoRow(icon: "shield.lefthalf.filled",
                        title: AppLocalization.string("Block whole sites"),
                        detail: AppLocalization.string("TikTok is replaced with a friendly blocked page. You can opt any site into full block too."))
                InfoRow(icon: "slider.horizontal.3",
                        title: AppLocalization.string("Per-site control"),
                        detail: AppLocalization.string("Infinite Feed limits scrolling. On Instagram it also includes Explore and Stories."))
                InfoRow(icon: "lock.fill",
                        title: AppLocalization.string("Strict mode (24 h)"),
                        detail: AppLocalization.string("For 24 hours, enabled restrictions cannot be turned off. You can add restrictions, but cannot enable whole-site blocking. The timer survives restarts and force-quits."))
                InfoRow(icon: "arrow.triangle.2.circlepath",
                        title: AppLocalization.string("Self-updating rules"),
                        detail: AppLocalization.string("Safari checks a remote rules file for selector and redirect fixes. Strict mode pauses rule changes until its lock expires."))
            }

            HStack {
                Spacer()
                Button(AppLocalization.string("Done")) { dismiss() }
                    .keyboardShortcut(.defaultAction)
            }
        }
        .padding(20)
        #if os(macOS)
        .frame(width: 520)
        #endif
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
                #if os(macOS)
                    Button(action: action) { content }
                        .buttonStyle(.plain)
                        .focusable(false)
                #else
                    Button(action: action) { content }
                        .buttonStyle(.plain)
                #endif
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

    private var compact: Bool {
        #if os(macOS)
        return true
        #else
        return false
        #endif
    }

    private var content: some View {
        VStack(alignment: .leading, spacing: 0) {
            Image(systemName: icon)
                .font(.system(size: compact ? 14 : 16, weight: .semibold))
                .foregroundStyle(.white)
                .frame(width: compact ? 22 : 26, height: compact ? 22 : 26)
                .background(.white.opacity(0.18), in: Circle())
            Spacer(minLength: compact ? 4 : 8)
            Text(title)
                .font(.callout.weight(.semibold))
                .foregroundStyle(.white)
                .fixedSize(horizontal: false, vertical: true)
            Text(subtitle)
                .font(.caption2.weight(.medium))
                .foregroundStyle(.white.opacity(0.9))
                .fixedSize(horizontal: false, vertical: true)
        }
        .padding(compact ? 8 : 10)
        .frame(width: compact ? 160 : 190, alignment: .leading)
        .frame(minHeight: compact ? 100 : 140, alignment: .leading)
        .background(
            LinearGradient(colors: gradient, startPoint: .topLeading, endPoint: .bottomTrailing)
        )
        .clipShape(RoundedRectangle(cornerRadius: compact ? 12 : 14, style: .continuous))
        .shadow(color: gradient.last?.opacity(0.25) ?? .clear, radius: 4, y: 2)
    }
}

#if DEBUG && os(iOS) && canImport(FamilyControls)
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
                        Text(AppLocalization.string("Support Slowth"))
                            .font(.title3.weight(.semibold))
                        Text(AppLocalization.string("Doesn't unlock anything. Just a way to say thanks."))
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
                        Text(AppLocalization.string("Looks like this is broken for now"))
                            .font(.subheadline.weight(.semibold))
                        Text(AppLocalization.string("We'll fix it soon — come back later."))
                            .font(.caption)
                            .foregroundStyle(.secondary)
                            .multilineTextAlignment(.center)
                    } else {
                        Text(AppLocalization.string("Oops... try again later"))
                            .font(.subheadline.weight(.semibold))
                        Text(AppLocalization.string("Something broke. Even for a sloth, this is slow."))
                            .font(.caption)
                            .foregroundStyle(.secondary)
                            .multilineTextAlignment(.center)
                        Button {
                            retryTapped()
                        } label: {
                            if isRetrying {
                                ProgressView().controlSize(.small)
                            } else {
                                Text(AppLocalization.string("Reload"))
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
                Label(AppLocalization.string("Thanks! It really helps."), systemImage: "heart.fill")
                    .foregroundStyle(.pink)
                    .font(.callout.weight(.semibold))
            }

            if !tipStore.history.isEmpty {
                VStack(alignment: .leading, spacing: 6) {
                    Text(AppLocalization.string("Your support"))
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
                Button(AppLocalization.string("Done")) { dismiss() }
                    .keyboardShortcut(.defaultAction)
            }
        }
        .padding(20)
        #if os(macOS)
        .frame(width: 480)
        #endif
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
        .alert(AppLocalization.string("Heads up"),
               isPresented: Binding(
                get: { tipStore.lastError != nil },
                set: { if !$0 { tipStore.lastError = nil } })) {
            Button(AppLocalization.string("OK"), role: .cancel) { tipStore.lastError = nil }
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
            Text(date.formatted(.dateTime.year().month(.abbreviated).day().locale(L10n.locale)))
                .font(.callout)
                .foregroundStyle(.secondary)
        }
    }
}
