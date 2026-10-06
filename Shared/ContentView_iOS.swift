#if os(iOS)
import SwiftUI
import StoreKit
import UIKit
import Darwin
#if canImport(FamilyControls)
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

private extension View {
    @ViewBuilder
    func observeDuoCapability(_ isDuo: Binding<Bool>) -> some View {
        #if canImport(SwiftUI, _version: 8.0.85)
        if #available(iOS 27.1, *) {
            self.onHingeChange { _, context in
                isDuo.wrappedValue = context.hinge != nil && UIDevice.current.userInterfaceIdiom == .phone
            }
        } else {
            self
        }
        #else
        self
        #endif
    }

    // iPhone-style bottom-sheet detents only make sense in a compact-width
    // context. On full-screen iPad (regular width) they force an
    // undersized, bottom-anchored sheet instead of the platform's normal
    // centered form-sheet — so only apply them when the size class is compact.
    @ViewBuilder
    func compactSheetDetents(isCompact: Bool) -> some View {
        if #available(iOS 27.1, *) {
            // Let the system move and resize presentations across Duo displays
            // and reserved regions, including while a sheet is already open.
            self
        } else if isCompact {
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
    #if DEBUG
    @StateObject private var debugCaptureLibrary = DebugCapturePhotoLibrary()
    #endif
    @AppStorage("uiMode") private var uiMode: String = "ios"
    @AppStorage("contributionCardDismissed") private var contributionCardDismissed = false
    @Environment(\.horizontalSizeClass) private var horizontalSizeClass
    @Environment(\.dynamicTypeSize) private var dynamicTypeSize
    @State private var isDuo = false
    private var isPad: Bool { UIDevice.current.userInterfaceIdiom == .pad }
    @State private var showSafariHelp = false
    @State private var showAbout = false
    @State private var showContribution = false
    @State private var showSupportSheet = false
    @State private var showRealtimeBlockingBeta = false
    @State private var showRealtimeRecordingPrompt = false
    @State private var showStrictModeConfirmation = false
    #if DEBUG
    @AppStorage(DebugMode.storageKey, store: AppGroup.defaults) private var debugModeEnabled = false
    @AppStorage(DebugCaptureSettings.storageKey, store: AppGroup.defaults) private var debugCaptureEnabled = false
    @AppStorage(DebugModelSettings.storageKey, store: AppGroup.defaults) private var debugModelBackend = DebugModelSettings.defaultBackend.rawValue
    @AppStorage(FeatureFlags.tipsOverrideStorageKey, store: AppGroup.defaults) private var tipsFeatureEnabled = false
    @State private var versionTapCount = 0
    #endif
    #if canImport(FamilyControls)
    @ObservedObject private var familyControlsAuthorization = AuthorizationCenter.shared
    @State private var isAuthorizingFamilyControls = false
    @State private var showYouTubePicker = false
    @State private var showInstagramPicker = false
    @State private var showFacebookPicker = false
    @State private var showXPicker = false
    @State private var youtubeSelection = FamilyActivitySelection()
    @State private var instagramSelection = FamilyActivitySelection()
    @State private var facebookSelection = FamilyActivitySelection()
    @State private var xSelection = FamilyActivitySelection()
    #endif

    var body: some View {
        NavigationStack {
            GeometryReader { geometry in
                settingsLayout(in: geometry.size)
            }
            .navigationTitle("Slowth")
            .navigationBarTitleDisplayMode(.large)
            .toolbar {
                if isDuo { duoToolbar }
            }
        }
        .observeDuoCapability($isDuo)
        .appReviewPrompt(hasEnabledBlocking: state.hasEnabledBlockingForReview, isReady: isReadyForReview)
        .alert(String(localized: "Heads up"),
               isPresented: Binding(
                get: { state.lastError != nil },
                set: { if !$0 { state.lastError = nil } })) {
            Button(String(localized: "OK"), role: .cancel) { state.lastError = nil }
        } message: {
            Text(state.lastError ?? "")
        }
        .alert(String(localized: "Enable Strict mode?"), isPresented: $showStrictModeConfirmation) {
            Button(String(localized: "Enable")) { state.setStrictMode(true) }
            Button(String(localized: "Cancel"), role: .cancel) { }
        } message: {
            Text(String(localized: "For 24 hours, enabled restrictions cannot be turned off. You can add restrictions, but cannot enable whole-site blocking."))
        }
        .sheet(isPresented: $showSafariHelp) {
            SafariHelpSheet(openSettings: { state.openSafariExtensionSettings() })
                .compactSheetDetents(isCompact: horizontalSizeClass == .compact)
        }
        .sheet(isPresented: $showAbout) {
            HowItWorksSheet(feedbackURL: feedbackURL)
                .compactSheetDetents(isCompact: horizontalSizeClass == .compact)
        }
        .sheet(isPresented: $showContribution) {
            NavigationStack {
                ScrollView {
                    contributionContent
                        .frame(maxWidth: 560, alignment: .leading)
                        .padding(24)
                        .frame(maxWidth: .infinity)
                }
                .navigationTitle("Help improve Slowth")
                .navigationBarTitleDisplayMode(.inline)
                .toolbar {
                    ToolbarItem(placement: .confirmationAction) {
                        Button("Done") { showContribution = false }
                    }
                }
            }
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
                isRecording: state.snapshot.broadcastActive,
                onLearnMore: { showRealtimeRecordingPrompt = false; showRealtimeBlockingBeta = true }
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
        .sheet(isPresented: $showFacebookPicker) {
            FamilyActivityPickerWrapper(
                selection: facebookSelection,
                onDone: { selection in
                    state.saveFacebookSelection(selection)
                    showFacebookPicker = false
                },
                onCancel: { showFacebookPicker = false }
            )
        }

        .sheet(isPresented: $showXPicker) {
            FamilyActivityPickerWrapper(
                selection: xSelection,
                onDone: { selection in
                    state.saveXSelection(selection)
                    showXPicker = false
                },
                onCancel: { showXPicker = false }
            )
        }
        .onAppear(perform: presentRealtimeRecordingPromptIfRequested)
        .onReceive(NotificationCenter.default.publisher(for: UIApplication.didBecomeActiveNotification)) { _ in
            presentRealtimeRecordingPromptIfRequested()
        }
        #endif
        #if DEBUG
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
        #endif
    }

    @ToolbarContentBuilder
    private var duoToolbar: some ToolbarContent {
        #if canImport(SwiftUI, _version: 8.0.85)
        if #available(iOS 27.1, *), isDuo {
            ToolbarItem(placement: .bottomBar) {
                Button {
                    showStrictModeConfirmation = true
                } label: {
                    Label(
                        state.snapshot.isStrictModeActive ? String(localized: "Locked") : String(localized: "Strict"),
                        systemImage: state.snapshot.isStrictModeActive ? "lock.fill" : "lock.open"
                    )
                }
                .disabled(disabledByStrict)
                .accessibilityIdentifier("duo.strict")
            }
            #if canImport(FamilyControls)
            ToolbarItem(placement: .bottomBar) {
                RecordingToolbarButton(preferredExtensionBundleID: state.broadcastExtensionBundleID)
            }
            .axisBehavior(.verticalPreferred)
            #endif
        }
        #else
        // The enclosing isDuo condition is always false with an older SDK.
        ToolbarItem(placement: .bottomBar) { EmptyView() }
        #endif
    }

    @ViewBuilder
    private func settingsLayout(in size: CGSize) -> some View {
        if isPad {
            Group {
                if horizontalSizeClass == .regular,
                   !dynamicTypeSize.isAccessibilitySize,
                   size.width >= 900 {
                    HStack(alignment: .top, spacing: 16) {
                        settingsPane(title: String(localized: "In-app blocking"), icon: "shield.lefthalf.filled") {
                            settingsForm(includeSites: false)
                        }
                        .frame(maxWidth: .infinity)
                        settingsPane(title: "Safari", icon: "safari") {
                            Form { sitesSection }
                                .accessibilityIdentifier("safariSettingsForm")
                        }
                        .frame(maxWidth: .infinity)
                    }
                    .frame(maxWidth: 1160)
                    .padding(.horizontal, 16)
                } else {
                    settingsForm(includeSites: true)
                        .scrollContentBackground(.hidden)
                        .frame(maxWidth: 680)
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .background(Color(uiColor: .systemGroupedBackground))
        } else {
            // Use the current window, never the device model or main screen. Keep
            // tall/narrow windows and accessibility text in one scrollable form.
            // SwiftUI 8.0.85 ships ArrangementView in the iOS 27.1 SDK. Xcode
            // 27.0 uses the same Swift compiler, so a compiler check is insufficient.
            #if canImport(SwiftUI, _version: 8.0.85)
            if #available(iOS 27.1, *),
               horizontalSizeClass == .regular,
               !dynamicTypeSize.isAccessibilitySize,
               size.width >= 720, size.width > size.height {
                ArrangementView {
                    settingsPane(title: String(localized: "In-app blocking"), icon: "shield.lefthalf.filled") {
                        settingsForm(includeSites: false)
                    }
                } secondary: {
                    settingsPane(title: "Safari", icon: "safari") {
                        Form {
                            sitesSection
                        }
                        .accessibilityIdentifier("safariSettingsForm")
                    }
                }
                // Allow either axis around a fold, so neither pane is suppressed.
                // Each section has exactly one owner; do not infer visibility from
                // splitArrangementAxis, which describes layout, not visibility.
                .arrangementViewStyle(.split)
                .background(Color(uiColor: .systemGroupedBackground))
            } else {
                settingsForm(includeSites: true)
            }
            #else
            // Keep older Xcode/SDK builds working; Duo layouts require Xcode 27.1.
            settingsForm(includeSites: true)
            #endif
        }
    }

    private func settingsPane<Content: View>(
        title: String, icon: String, @ViewBuilder content: () -> Content
    ) -> some View {
        VStack(spacing: 0) {
            Label(title, systemImage: icon)
                .font(.subheadline.weight(.semibold))
                .foregroundStyle(.secondary)
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(.horizontal, 20)
                .padding(.top, 8)
                .padding(.bottom, 4)
            content()
                .scrollContentBackground(.hidden)
        }
        .padding(.horizontal, 8)
    }

    private func settingsForm(includeSites: Bool) -> some View {
        Form {
            heroSection
            if state.snapshot.isStrictModeActive {
                strictBannerSection
            }
            #if canImport(FamilyControls)
            realtimeShieldSection
            #endif
            if includeSites {
                sitesSection
            }
            if !isDuo {
                strictModeSection
            }
            updatesSection
            #if DEBUG
            if debugModeEnabled {
                debugSection
            }
            #endif
            helpSection
        }
        .accessibilityIdentifier("mainSettingsForm")
    }

    private var disabledByStrict: Bool { state.snapshot.isStrictModeActive }

    private var isReadyForReview: Bool {
        guard state.lastError == nil, !state.refreshing,
              !showSafariHelp, !showAbout, !showContribution, !showSupportSheet, !showRealtimeBlockingBeta,
              !showRealtimeRecordingPrompt, !showStrictModeConfirmation else { return false }
        #if canImport(FamilyControls)
        guard !isAuthorizingFamilyControls, !showYouTubePicker, !showInstagramPicker,
              !showFacebookPicker, !showXPicker else { return false }
        #endif
        return true
    }

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
                    if !contributionCardDismissed {
                        HeroCard(
                            title: String(localized: "Help improve"),
                            subtitle: String(localized: "In-app blocking"),
                            icon: "heart.text.clipboard",
                            gradient: [Color(red: 0.12, green: 0.65, blue: 0.57),
                                       Color(red: 0.08, green: 0.43, blue: 0.49)],
                            action: { showContribution = true },
                            onDismiss: { contributionCardDismissed = true }
                        )
                        .accessibilityIdentifier("contribution.card")
                    }
                    HeroCard(
                        title: String(localized: "In-app blocking"),
                        subtitle: String(localized: "Shorts, Reels & Stories"),
                        icon: "record.circle.fill",
                        gradient: [Color(red: 0.98, green: 0.24, blue: 0.34),
                                   Color(red: 0.79, green: 0.12, blue: 0.45)],
                        action: { showRealtimeBlockingBeta = true }
                    )
                    HeroCard(
                        title: String(localized: "How it works"),
                        subtitle: String(localized: "What Slowth does for you"),
                        icon: "sparkles",
                        gradient: [Color(red: 0.36, green: 0.46, blue: 0.95),
                                   Color(red: 0.55, green: 0.32, blue: 0.86)],
                        action: { showAbout = true }
                    )
                    HeroCard(
                        title: "Safari",
                        subtitle: String(localized: "Enable in extensions"),
                        icon: "safari.fill",
                        gradient: [Color(red: 0.21, green: 0.65, blue: 0.97),
                                   Color(red: 0.14, green: 0.45, blue: 0.84)],
                        action: { showSafariHelp = true }
                    )
                    if !isDuo {
                        HeroCard(
                            title: state.snapshot.isStrictModeActive ? String(localized: "Locked") : String(localized: "Strict"),
                            subtitle: state.snapshot.isStrictModeActive
                                ? String(localized: "24 h lock active")
                                : String(localized: "Lock for 24 hours"),
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
                    }
                    if FeatureFlags.tipsEnabled && !state.snapshot.supportCardDismissed {
                        HeroCard(
                            title: String(localized: "Support"),
                            subtitle: String(localized: "Tip the developer"),
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
                    Text(String(localized: "Strict mode active"))
                        .font(.subheadline.weight(.semibold))
                    if let until = state.snapshot.strictModeUntil {
                        Text(String(localized: "Locked until \(L10n.dateTime(until))"))
                            .font(.footnote)
                            .foregroundStyle(.secondary)
                    }
                }
            }
        }
    }

    private var sitesSection: some View {
        ForEach(sites) { site in
            Section {
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
            } header: {
                if site.id == sites.first?.id {
                    Text(String(localized: "Safari extension settings"))
                }
            } footer: {
                if site.id == sites.last?.id {
                    Text(String(localized: "Infinite Feed limits scrolling. On Instagram it also includes Explore and Stories."))
                }
            }
        }
    }

    #if canImport(FamilyControls)
    private var realtimeShieldSection: some View {
        Section {
            Toggle(isOn: Binding(
                get: { state.snapshot.realtimeShieldEnabled },
                set: { state.setRealtimeShieldEnabled($0) }
            )) {
                Text(String(localized: "In-app blocking"))
            }
            .disabled(disabledByStrict && state.snapshot.realtimeShieldEnabled)

            if state.snapshot.realtimeShieldEnabled {
                RealtimeRecordingCard(
                    preferredExtensionBundleID: state.broadcastExtensionBundleID,
                    isRecording: state.snapshot.broadcastActive,
                    guidance: realtimeRecordingGuidance
                )
                ScreenRecordingInfoCard(onLearnMore: { showRealtimeBlockingBeta = true })
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
                        Text(String(localized: "Allow Screen Time access"))
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
                        Text(String(localized: "Choose YouTube app"))
                        Spacer()
                        if state.hasYouTubeSelection {
                            Image(systemName: "checkmark.circle.fill").foregroundStyle(.green)
                        }
                    }
                }
                .disabled(disabledByStrict && state.hasYouTubeSelection)

                Toggle(String(localized: "Block YouTube Shorts"), isOn: Binding(
                    get: { state.snapshot.realtimeYouTubeBlockingEnabled },
                    set: { state.setRealtimeYouTubeBlockingEnabled($0) }
                ))
                .disabled((disabledByStrict && state.snapshot.realtimeYouTubeBlockingEnabled) || !state.hasYouTubeSelection)

                Toggle(String(localized: "Soft YouTube blocking"), isOn: Binding(
                    get: { state.snapshot.softYouTubeBlockingEnabled },
                    set: { state.setSoftYouTubeBlockingEnabled($0) }
                ))
                .disabled(
                    disabledByStrict && state.snapshot.softYouTubeBlockingEnabled
                        || !state.hasYouTubeSelection
                        || !state.snapshot.realtimeYouTubeBlockingEnabled
                )

                Text(String(localized: "Soft mode works well for audio podcasts. Picture in Picture may still be blocked when screen recording is off."))
                    .font(.caption)
                    .foregroundStyle(.secondary)

                Button {
                    instagramSelection = decodedSelection(state.snapshot.instagramSelectionData)
                    showInstagramPicker = true
                } label: {
                    HStack {
                        Text(String(localized: "Choose Instagram app"))
                        Spacer()
                        if state.hasInstagramSelection {
                            Image(systemName: "checkmark.circle.fill").foregroundStyle(.green)
                        }
                    }
                }
                .disabled(disabledByStrict && state.hasInstagramSelection)

                Toggle(String(localized: "Block Instagram Reels"), isOn: Binding(
                    get: { state.snapshot.realtimeInstagramReelsBlockingEnabled },
                    set: { state.setRealtimeInstagramReelsBlockingEnabled($0) }
                ))
                .disabled((disabledByStrict && state.snapshot.realtimeInstagramReelsBlockingEnabled) || !state.hasInstagramSelection)

                Toggle(String(localized: "Block Instagram Stories"), isOn: Binding(
                    get: { state.snapshot.realtimeInstagramStoriesBlockingEnabled },
                    set: { state.setRealtimeInstagramStoriesBlockingEnabled($0) }
                ))
                .disabled((disabledByStrict && state.snapshot.realtimeInstagramStoriesBlockingEnabled) || !state.hasInstagramSelection)

                if state.facebookModelSelected || state.snapshot.realtimeFacebookBlockingEnabled {
                    Button {
                        facebookSelection = decodedSelection(state.snapshot.facebookSelectionData)
                        showFacebookPicker = true
                    } label: {
                        HStack {
                            Text(String(localized: "Choose Facebook app"))
                            Spacer()
                            if state.hasFacebookSelection {
                                Image(systemName: "checkmark.circle.fill").foregroundStyle(.green)
                            }
                        }
                    }
                    .disabled(disabledByStrict && state.hasFacebookSelection)

                    Toggle(String(localized: "Block Facebook Reels"), isOn: Binding(
                        get: { state.snapshot.realtimeFacebookReelsBlockingEnabled },
                        set: { state.setRealtimeFacebookReelsBlockingEnabled($0) }
                    ))
                    .disabled((disabledByStrict && state.snapshot.realtimeFacebookReelsBlockingEnabled) || !state.hasFacebookSelection || (!state.facebookModelSelected && !state.snapshot.realtimeFacebookReelsBlockingEnabled))

                    Toggle(String(localized: "Block Facebook Stories"), isOn: Binding(
                        get: { state.snapshot.realtimeFacebookStoriesBlockingEnabled },
                        set: { state.setRealtimeFacebookStoriesBlockingEnabled($0) }
                    ))
                    .disabled((disabledByStrict && state.snapshot.realtimeFacebookStoriesBlockingEnabled) || !state.hasFacebookSelection || (!state.facebookModelSelected && !state.snapshot.realtimeFacebookStoriesBlockingEnabled))
                }

                if state.xModelSelected || state.snapshot.realtimeXBlockingEnabled {
                    Button {
                        xSelection = decodedSelection(state.snapshot.xSelectionData)
                        showXPicker = true
                    } label: {
                        HStack {
                            Text(String(localized: "Choose X app"))
                            Spacer()
                            if state.hasXSelection {
                                Image(systemName: "checkmark.circle.fill").foregroundStyle(.green)
                            }
                        }
                    }
                    .disabled(disabledByStrict && state.hasXSelection)

                    Toggle(String(localized: "Block X Reels"), isOn: Binding(
                        get: { state.snapshot.realtimeXReelsBlockingEnabled },
                        set: { state.setRealtimeXReelsBlockingEnabled($0) }
                    ))
                    .disabled((disabledByStrict && state.snapshot.realtimeXReelsBlockingEnabled) || !state.hasXSelection || (!state.xModelSelected && !state.snapshot.realtimeXReelsBlockingEnabled))

                }

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
                        DebugStatusRow(label: "Facebook Reels", value: state.snapshot.realtimeFacebookReelsBlockingEnabled ? "blocked" : "allowed")
                        DebugStatusRow(label: "Facebook Stories", value: state.snapshot.realtimeFacebookStoriesBlockingEnabled ? "blocked" : "allowed")
                        DebugStatusRow(label: "Facebook candidates", value: "Reels \(state.snapshot.realtimeShieldDiagnostics.facebookCandidateEvents ?? 0) · Stories \(state.snapshot.realtimeShieldDiagnostics.facebookStoriesCandidateEvents ?? 0)")
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
            Text(String(localized: "Block content in apps"))
        } footer: {
            VStack(alignment: .leading, spacing: 8) {
                Text(InAppBlockingCopy.setup)
                Text(AppLocalization.string("Apps with blocking enabled stay blocked when screen recording is off. Soft YouTube mode can delay blocking."))
                Text(AppLocalization.string("Soft mode works well for audio podcasts. Picture in Picture may still be blocked when screen recording is off."))
                Text(AppLocalization.string("Pick a single app, not a whole category or \"All Apps\" — that would block everything."))
            }
        }
    }

    private var realtimeRecordingGuidance: String {
        if !FamilyControlsAuth.isAuthorized(familyControlsAuthorization.authorizationStatus) {
            return String(localized: "Allow Screen Time access below to finish setup.")
        }
        let youtubeReady = state.hasYouTubeSelection
            && state.snapshot.realtimeYouTubeBlockingEnabled
        let instagramReady = state.hasInstagramSelection
            && state.snapshot.realtimeInstagramBlockingEnabled
        let facebookReady = state.hasFacebookSelection
            && state.snapshot.realtimeFacebookBlockingEnabled
        let xReady = state.hasXSelection
            && state.snapshot.realtimeXBlockingEnabled
        if !youtubeReady && !instagramReady && !facebookReady && !xReady {
            return String(localized: "Choose an app and enable at least one blocking option below.")
        }
        return String(localized: "Tap anywhere here to start.")
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
                set: { newValue in
                    if newValue { showStrictModeConfirmation = true }
                    else { state.setStrictMode(false) }
                }
            )) {
                Text(String(localized: "Strict mode (24 h lock)"))
            }
            .disabled(disabledByStrict)
        } footer: {
            Text(String(localized: "For 24 hours, enabled restrictions cannot be turned off. You can add restrictions, but cannot enable whole-site blocking."))
        }
    }

    private var updatesSection: some View {
        Section {
            Button {
                Task { await state.forceRefresh() }
            } label: {
                HStack {
                    Text(String(localized: "Update rules now"))
                    Spacer()
                    if state.refreshing {
                        ProgressView()
                    }
                }
            }
            .disabled(state.refreshing || disabledByStrict)

            HStack {
                Text(String(localized: "Last update"))
                    .foregroundStyle(.secondary)
                Spacer()
                Text(rulesStatusText)
                    .foregroundStyle(.secondary)
                    .font(.footnote)
            }
        } header: {
            Text(String(localized: "Rules"))
        } footer: {
            Text(rulesFooterText)
        }
    }

    private var contributionContent: some View {
            VStack(alignment: .leading, spacing: 16) {
                Label {
                    Text(String(localized: "Help improve in-app blocking"))
                        .font(.title3.weight(.semibold))
                } icon: {
                    Image(systemName: "heart.text.clipboard")
                        .foregroundStyle(.tint)
                }

                Text(String(localized: "I need short screen recordings of Instagram, Facebook and other social apps to improve Slowth’s in-app blocking."))

                Text(String(localized: "Social apps look different across devices, languages and app versions. Your recordings will help me train Slowth to recognize what should be blocked and avoid blocking regular content."))

                Text(String(localized: "Just record yourself using the app as usual. No explanations or labels needed — I’ll review and label the footage myself to train and test the blocking model."))

                Text(String(localized: "Please leave out private messages, notifications and personal information."))
                    .font(.footnote)
                    .foregroundStyle(.secondary)

                VStack(alignment: .leading, spacing: 8) {
                    Link(destination: contributionURL) {
                        Label("Email me to help", systemImage: "envelope")
                            .font(.subheadline.weight(.semibold))
                            .frame(maxWidth: .infinity, minHeight: 32)
                    }
                    .buttonStyle(.borderedProminent)
                    .accessibilityIdentifier("contribution.email")

                    Text(String(localized: "You can email me before recording. The draft includes your device model, iOS and Slowth versions — you can remove them before sending."))
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                }
            }
            .font(.subheadline)
            .fixedSize(horizontal: false, vertical: true)
            .padding(.vertical, 10)
    }

    private var contributionURL: URL {
        Self.mailURL(
            subject: String(localized: "Help improve Slowth"),
            body: String(localized: """
            Hi Denis! I’d like to help improve Slowth’s in-app blocking by sharing screen recordings.

            Device details (you can remove these before sending):
            Device: \(UIDevice.current.model) (\(deviceModelIdentifier))
            System: \(UIDevice.current.systemName) \(UIDevice.current.systemVersion)
            Slowth: \(appVersion)
            """)
        )
    }

    private var deviceModelIdentifier: String {
        #if targetEnvironment(simulator)
        if let model = ProcessInfo.processInfo.environment["SIMULATOR_MODEL_IDENTIFIER"] {
            return "\(model), Simulator"
        }
        #endif
        var systemInfo = utsname()
        uname(&systemInfo)
        return withUnsafeBytes(of: &systemInfo.machine) { bytes in
            String(decoding: bytes.prefix { $0 != 0 }, as: UTF8.self)
        }
    }

    private var helpSection: some View {
        Section {
            Link(destination: AppReviewCoordinator.reviewURL) {
                HStack {
                    Text(String(localized: "Rate Slowth"))
                    Spacer()
                    Image(systemName: "star")
                        .foregroundStyle(.secondary)
                }
            }
            if !isDuo {
                Link(destination: feedbackURL) {
                    HStack {
                        Text(String(localized: "Send feedback"))
                        Spacer()
                        Image(systemName: "envelope")
                            .foregroundStyle(.secondary)
                    }
                }
            }
            if FeatureFlags.tipsEnabled {
                Button {
                    showSupportSheet = true
                } label: {
                    HStack {
                        Text(String(localized: "Support"))
                        Spacer()
                        Image(systemName: "heart.fill")
                            .foregroundStyle(.secondary)
                    }
                }
            }
        } header: {
            Text(String(localized: "Feedback & Support"))
        } footer: {
            #if DEBUG
            Button(action: appVersionTapped) {
                Text(appVersion)
            }
            .buttonStyle(.plain)
            #else
            Text(appVersion)
            #endif
            if let evidence = BuildProvenance.current {
                Link(destination: evidence.runURL) {
                    Text(verbatim: "CI · \(evidence.shortCommit)")
                }
            }
        }
    }

    #if DEBUG
    private var debugSection: some View {
        Section {
            Toggle("Debug mode", isOn: $debugModeEnabled)
                .disabled(state.snapshot.broadcastActive || (state.snapshot.isStrictModeActive && (state.snapshot.realtimeFacebookBlockingEnabled || state.snapshot.realtimeXBlockingEnabled)))
                .onChange(of: debugModeEnabled) { _ in
                    #if os(iOS) && canImport(FamilyControls)
                    state.refreshFacebookModelSelection()
                    #endif
                }
            DebugSessionCaptureControls()
            if DebugModelSettings.cascadeAvailable {
                Picker("Model for next recording", selection: Binding(
                    get: { DebugModelSettings.selection(stored: debugModelBackend).rawValue },
                    set: { debugModelBackend = $0; state.refreshFacebookModelSelection() }
                )) {
                    ForEach(DebugModelBackend.allCases, id: \.rawValue) { backend in
                        Text(backend.title).tag(backend.rawValue)
                    }
                }
                .disabled(state.snapshot.broadcastActive || (state.snapshot.isStrictModeActive && (state.snapshot.realtimeFacebookBlockingEnabled || state.snapshot.realtimeXBlockingEnabled)))
                Text("Stop screen recording, choose a model, then start recording again. Turning Debug mode off selects Cascade V10 for the next recording. V14 is experimental and unqualified: validation quality gates failed. V15 and Cascade V6 are experimental and unqualified: validation quality gates failed. V15 CoreML parity failed on validation (Stories threshold and temporal trace mismatch). Cascade V6 CoreML parity passed; device qualification is still pending. Cascade V7 adds Facebook Reels and Stories. Cascade V8 adds X short videos. Cascade V10 is the default and uses the expanded candidate pool; validation quality gates failed and device qualification is pending.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            } else {
                Text("Model selection is unavailable in this build.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
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
            DebugAppReviewControls(hasEnabledBlocking: state.hasEnabledBlockingForReview,
                                   isReady: isReadyForReview)
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

    #endif
    private func bindingForSite(_ siteID: String, feature: SiteFeature) -> Binding<Bool> {
        Binding(
            get: { state.setting(feature, for: siteID) },
            set: { state.setSetting(feature, enabled: $0, for: siteID) }
        )
    }

    private var rulesStatusText: String {
        if let date = state.snapshot.rulesFetchedAt {
            return Self.relativeFormatter.localizedString(for: date, relativeTo: Date())
        }
        return String(localized: "Never")
    }

    private var rulesFooterText: String {
        switch state.lastRefreshOutcome {
        case .updated?: return String(localized: "Rules updated.")
        case .notModified?: return String(localized: "Rules already up to date.")
        case .failed(let reason)?: return String(localized: "Update failed (\(L10n.refreshError(reason))).")
        case .none: return String(localized: "Safari checks for remote rule updates every 6 hours. Strict mode pauses rule changes until the lock expires.")
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
            URLQueryItem(name: "subject", value: String(localized: "Slowth feedback")),
            URLQueryItem(name: "body", value: String(localized: "\n\n(Helps me debug — delete if you'd rather not share.)\n\(appVersion)\n\(deviceInfo)"))
        ]
        return components.url!
    }

    private var realtimeBlockingFeedbackURL: URL {
        Self.mailURL(
            subject: String(localized: "Slowth — In-app blocking feedback"),
            body: String(localized: """
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

    private static let relativeFormatter: RelativeDateTimeFormatter = {
        let f = RelativeDateTimeFormatter()
        f.unitsStyle = .short
        f.locale = L10n.locale
        return f
    }()
}

private struct HeroCard: View {
    @ScaledMetric(relativeTo: .title3) private var cardWidth = 180.0
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
                .accessibilityLabel(String(localized: "Hide card"))
            }
        }
    }

    private var content: some View {
        VStack(alignment: .leading, spacing: 0) {
            Image(systemName: icon)
                .font(.system(size: 20, weight: .semibold))
                .foregroundStyle(.white)
                .frame(width: 32, height: 32)
                .background(.white.opacity(0.18), in: Circle())
            Spacer(minLength: 8)
            Text(title)
                .font(.title3.bold())
                .foregroundStyle(.white)
                .fixedSize(horizontal: false, vertical: true)
            Text(subtitle)
                .font(.caption.weight(.medium))
                .foregroundStyle(.white.opacity(0.9))
                .fixedSize(horizontal: false, vertical: true)
        }
        .padding(13)
        .frame(width: cardWidth, alignment: .leading)
        .frame(minHeight: 145, alignment: .leading)
        .background(
            LinearGradient(colors: gradient, startPoint: .topLeading, endPoint: .bottomTrailing)
        )
        .clipShape(RoundedRectangle(cornerRadius: 18, style: .continuous))
        .shadow(color: gradient.last?.opacity(0.25) ?? .clear, radius: 6, y: 3)
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
                            Text(String(localized: "Enable Slowth in Safari"))
                                .font(.title3.weight(.semibold))
                            Text(String(localized: "Apple doesn't allow apps to deep-link directly into the Safari extensions list. Follow the steps below."))
                                .font(.footnote)
                                .foregroundStyle(.secondary)
                        }
                    }

                    VStack(alignment: .leading, spacing: 14) {
                        StepRow(number: 1, title: String(localized: "Open Settings"),
                                detail: String(localized: "Tap the button below — it opens iOS Settings."))
                        StepRow(number: 2, title: String(localized: "Go to Apps → Safari → Extensions"),
                                detail: String(localized: "Scroll the apps list, tap Safari, then Extensions."))
                        StepRow(number: 3, title: String(localized: "Turn on Slowth"),
                                detail: String(localized: "Toggle Slowth on. iOS may ask for permissions."))
                        StepRow(number: 4, title: String(localized: "Allow on every website"),
                                detail: String(localized: "Tap Slowth → Permissions → All Websites → Allow. Without this, the extension can't hide Shorts."))
                    }

                    Button {
                        openSettings()
                    } label: {
                        Text(String(localized: "Open Settings"))
                            .frame(maxWidth: .infinity)
                    }
                    .buttonStyle(.borderedProminent)
                    .controlSize(.large)
                }
                .padding(20)
            }
            .navigationTitle(String(localized: "Enable in Safari"))
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button(String(localized: "Done")) { dismiss() }
                }
            }
        }
    }
}

#if DEBUG && canImport(FamilyControls)
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
                                Text(String(localized: "Support Slowth"))
                                    .font(.title3.weight(.semibold))
                                Text(String(localized: "Doesn't unlock anything. Just a way to say thanks."))
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
                                Text(String(localized: "Looks like this is broken for now"))
                                    .font(.subheadline.weight(.semibold))
                                Text(String(localized: "We'll fix it soon — come back later."))
                                    .font(.footnote)
                                    .foregroundStyle(.secondary)
                                    .multilineTextAlignment(.center)
                            } else {
                                Text(String(localized: "Oops... try again later"))
                                    .font(.subheadline.weight(.semibold))
                                Text(String(localized: "Something broke. Even for a sloth, this is slow."))
                                    .font(.footnote)
                                    .foregroundStyle(.secondary)
                                    .multilineTextAlignment(.center)
                                Button {
                                    retryTapped()
                                } label: {
                                    if isRetrying {
                                        ProgressView()
                                    } else {
                                        Text(String(localized: "Reload"))
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
                        Label(String(localized: "Thanks! It really helps."), systemImage: "heart.fill")
                            .foregroundStyle(.pink)
                            .font(.subheadline.weight(.semibold))
                            .frame(maxWidth: .infinity)
                    }

                    if !tipStore.history.isEmpty {
                        VStack(alignment: .leading, spacing: 8) {
                            Text(String(localized: "Your support"))
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
            .navigationTitle(String(localized: "Support"))
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button(String(localized: "Done")) { dismiss() }
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
        .alert(String(localized: "Heads up"),
               isPresented: Binding(
                get: { tipStore.lastError != nil },
                set: { if !$0 { tipStore.lastError = nil } })) {
            Button(String(localized: "OK"), role: .cancel) { tipStore.lastError = nil }
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
            Text(date.formatted(.dateTime.year().month(.abbreviated).day().locale(L10n.locale)))
                .font(.footnote)
                .foregroundStyle(.secondary)
        }
    }
}

#Preview {
    ContentView()
}
#endif
