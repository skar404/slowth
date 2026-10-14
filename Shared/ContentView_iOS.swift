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

private enum SlowthAppearance {
    static let background = Color(uiColor: UIColor { traits in
        traits.userInterfaceStyle == .dark
            ? UIColor(white: 0.065, alpha: 1) : .systemGroupedBackground
    })
    static let card = Color(uiColor: UIColor { traits in
        traits.userInterfaceStyle == .dark
            ? UIColor(white: 0.125, alpha: 1) : .secondarySystemGroupedBackground
    })
    static let sage = Color(uiColor: UIColor { traits in
        traits.userInterfaceStyle == .dark
            ? UIColor(red: 0.66, green: 0.81, blue: 0.62, alpha: 1)
            : UIColor(red: 0.27, green: 0.44, blue: 0.29, alpha: 1)
    })
}

private extension View {
    @ViewBuilder
    func compactServiceSpacing() -> some View {
        if #available(iOS 17.0, *) {
            self.listSectionSpacing(.custom(10))
                .contentMargins(.top, 8, for: .scrollContent)
        } else {
            self
        }
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
    @Environment(\.horizontalSizeClass) private var horizontalSizeClass
    @State private var selectedSection = 0
    @State private var expandedService: String?
    @State private var showSafariHelp = false
    @State private var showAbout = false
    @State private var showContribution = false
    @State private var showSupportSheet = false
    @State private var showRealtimeBlockingBeta = false
    @State private var showRealtimeRecordingPrompt = false
    @State private var recordingPromptPauseTarget: String?
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

    init() {
        #if DEBUG && targetEnvironment(simulator)
        // Presentation-only screenshot arguments; never override settings or authorization.
        let arguments = ProcessInfo.processInfo.arguments
        _selectedSection = State(initialValue: arguments.contains("--preview-safari") ? 1 : 0)
        if let index = arguments.firstIndex(of: "--preview-service"), arguments.indices.contains(index + 1) {
            _expandedService = State(initialValue: arguments[index + 1])
        }
        #endif
    }

    var body: some View {
        TabView(selection: $selectedSection) {
            sectionNavigation(0)
                .tabItem { Label(String(localized: "Apps", table: "Interface"), systemImage: "square.grid.2x2") }
                .tag(0)
            sectionNavigation(1)
                .tabItem { Label("Safari", systemImage: "safari") }
                .tag(1)
            sectionNavigation(2)
                .tabItem { Label(String(localized: "Settings", table: "Interface"), systemImage: "gearshape") }
                .tag(2)
        }
        .tint(SlowthAppearance.sage)
        // Keep the native tab bar at the bottom on iPad too. Each page receives
        // the actual window size class so its layout and sheets remain adaptive.
        .environment(\.horizontalSizeClass, .compact)
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
                onLearnMore: { showRealtimeRecordingPrompt = false; showRealtimeBlockingBeta = true },
                pauseTarget: recordingPromptPauseTarget
            )
            .compactSheetDetents(isCompact: horizontalSizeClass == .compact)
        }
        .sheet(isPresented: $showYouTubePicker) {
            FamilyActivityPickerWrapper(
                selection: youtubeSelection,
                onDone: { selection in
                    state.saveYouTubeSelection(selection)
                    expandedService = state.hasYouTubeSelection ? "apps.youtube" : nil
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
                    expandedService = state.hasInstagramSelection ? "apps.instagram" : nil
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
                    expandedService = state.hasFacebookSelection ? "apps.facebook" : nil
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
                    expandedService = state.hasXSelection ? "apps.x" : nil
                    showXPicker = false
                },
                onCancel: { showXPicker = false }
            )
        }
        .onChange(of: familyControlsAuthorization.authorizationStatus) { _ in
            state.refreshProtectionAuthorization()
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
        .onChange(of: debugCaptureLibrary.lastError) { error in
            guard debugModeEnabled, debugCaptureEnabled, let error else { return }
            state.lastError = error
        }
        .onChange(of: debugCaptureEnabled) { enabled in
            guard enabled else { return }
            debugCaptureLibrary.requestAccessAndImport()
        }
        #endif
    }

    private func sectionNavigation(_ section: Int) -> some View {
        NavigationStack {
            GeometryReader { geometry in
                settingsLayout(in: geometry.size, section: section)
            }
            .navigationTitle("")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                sectionToolbar(section)
            }
        }
        .environment(\.horizontalSizeClass, horizontalSizeClass)
    }

    private func sectionTitle(_ section: Int) -> String {
        section == 0 ? String(localized: "Apps", table: "Interface")
            : section == 1 ? "Safari" : String(localized: "Settings", table: "Interface")
    }

    private func sectionLabel(_ section: Int) -> some View {
        HStack(spacing: 6) {
            Image(systemName: "leaf.fill").foregroundStyle(SlowthAppearance.sage)
            Text(sectionTitle(section)).foregroundStyle(.primary)
        }
        .font(.headline)
        .fixedSize(horizontal: true, vertical: false)
        .accessibilityElement(children: .combine)
        .accessibilityAddTraits(.isHeader)
    }

    @ToolbarContentBuilder
    private func sectionToolbar(_ section: Int) -> some ToolbarContent {
        if #available(iOS 26.0, *) {
            ToolbarItem(placement: .navigationBarLeading) { sectionLabel(section) }
                .sharedBackgroundVisibility(.hidden)
        } else {
            ToolbarItem(placement: .navigationBarLeading) { sectionLabel(section) }
        }
    }

    private func settingsLayout(in size: CGSize, section: Int) -> some View {
        VStack(spacing: 0) {
            Form {
                Group {
                if section == 0 {
                    #if canImport(FamilyControls)
                    if FamilyControlsAuth.isAuthorized(familyControlsAuthorization.authorizationStatus) {
                        realtimeShieldSection
                    } else {
                        screenTimeAccessSection
                    }
                    #endif
                } else if section == 1 {
                    Section {
                        Button { showSafariHelp = true } label: {
                            Label(String(localized: "Check Safari extension", table: "Interface"), systemImage: "safari")
                        }
                    }
                    sitesSection
                    updatesSection
                } else {
                    heroSection
                    strictModeSection
                    PauseDurationSettings(strict: disabledByStrict)
                    helpSection
                    #if DEBUG
                    if debugModeEnabled {
                        debugSection
                    }
                    #endif
                }
                }
                .listRowBackground(SlowthAppearance.card)
            }
            .scrollContentBackground(.hidden)
            .compactServiceSpacing()
            .environment(\.defaultMinListRowHeight, 48)
            .accessibilityIdentifier(section == 0 ? "mainSettingsForm" : section == 1 ? "safariSettingsForm" : "appSettingsForm")
        }
        // The same navigation at every window width, including iPad Split View.
        .frame(maxWidth: size.width >= 700 ? 680 : .infinity)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(SlowthAppearance.background)
    }

    private func serviceCard<Content: View>(
        _ id: String, title: String, summary: String,
        isConfigured: Bool = true, onChoose: (() -> Void)? = nil,
        @ViewBuilder content: @escaping () -> Content
    ) -> some View {
        Section {
            Group {
                if !isConfigured, let onChoose {
                    Button(action: onChoose) {
                        HStack {
                            serviceLabel(id, title: title,
                                         summary: String(localized: "Choose an app", table: "Interface"),
                                         isConfigured: false)
                            Spacer()
                            Image(systemName: "plus.circle")
                                .foregroundStyle(.secondary)
                        }
                        .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                } else {
                    DisclosureGroup(isExpanded: Binding(
                        get: { expandedService == id },
                        set: { expandedService = $0 ? id : nil }
                    )) {
                        content()
                            #if canImport(FamilyControls)
                            .disabled(id.hasPrefix("apps.") && !FamilyControlsAuth.isAuthorized(familyControlsAuthorization.authorizationStatus))
                            #endif
                    } label: {
                        serviceLabel(id, title: title, summary: summary, isConfigured: true)
                    }
                }
            }
            .padding(.vertical, 3)
            .accessibilityIdentifier("service." + id)
        }
    }

    private func serviceLabel(_ id: String, title: String, summary: String, isConfigured: Bool) -> some View {
        Label {
            VStack(alignment: .leading, spacing: 2) {
                Text(title).foregroundStyle(isConfigured ? .primary : .secondary)
                Text(summary)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        } icon: {
            Image("Service-" + String(id.split(separator: ".").last ?? ""))
                .resizable()
                .renderingMode(.original)
                .scaledToFit()
                .frame(width: 34, height: 34)
                .saturation(isConfigured ? 1 : 0)
                .opacity(isConfigured ? 1 : 0.45)
                .clipShape(RoundedRectangle(cornerRadius: 6, style: .continuous))
                .accessibilityHidden(true)
        }
    }

    private func siteFeatureTitle(_ feature: SiteFeature, site: String) -> String {
        switch feature {
        case .all: return String(localized: "Whole website", table: "Interface")
        case .feed: return String(localized: "Infinite feed", table: "Interface")
        case .shorts:
            if site == "youtube" { return "Shorts" }
            if site == "x" { return String(localized: "Explore & trends", table: "Interface") }
            return "Reels"
        }
    }

    private func restrictionSummary(_ labels: [String]) -> String {
        labels.isEmpty ? String(localized: "Off") : labels.joined(separator: " · ")
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
        var target: String?
        guard SharedStore.consumeRealtimeRecordingPromptRequest(target: &target) else { return }
        recordingPromptPauseTarget = target
        state.reload()
        showRealtimeRecordingPrompt = true
    }
    #endif

    private var sitesSection: some View {
        Group {
            ForEach(sites) { site in
                serviceCard("safari." + site.id, title: site.label, summary: safariSummary(site.id)) {
                    ForEach(SiteBlockingControl.controls(for: site.id)) { control in
                        Toggle(siteFeatureTitle(control.feature, site: control.site), isOn: bindingForSite(control.site, feature: control.feature))
                            .disabled((disabledByStrict &&
                                       (control.feature == .all || state.setting(control.feature, for: control.site))) ||
                                      (control.feature != .all && state.setting(.all, for: control.site)))
                            .accessibilityIdentifier(control.id)
                    }
                    if state.setting(.all, for: site.id) {
                        Text(String(localized: "Whole-site blocking takes priority", table: "Interface"))
                            .font(.caption).foregroundStyle(.secondary)
                    }
                    if site.id == "instagram" {
                        Text(String(localized: "Infinite Feed limits scrolling. On Instagram it also includes Explore and Stories."))
                            .font(.caption).foregroundStyle(.secondary)
                    }
                }
            }
        }
    }

    private func safariSummary(_ id: String) -> String {
        if state.setting(.all, for: id) { return siteFeatureTitle(.all, site: id) }
        return restrictionSummary(SiteBlockingControl.controls(for: id).compactMap {
            $0.feature != .all && state.setting($0.feature, for: id) ? siteFeatureTitle($0.feature, site: id) : nil
        })
    }

    #if canImport(FamilyControls)
    private func chooseApplication(_ service: String) {
        guard !isAuthorizingFamilyControls else { return }
        Task { @MainActor in
            if !FamilyControlsAuth.isAuthorized(familyControlsAuthorization.authorizationStatus) {
                isAuthorizingFamilyControls = true
                let authorized = await state.requestFamilyControlsAuthorization()
                isAuthorizingFamilyControls = false
                guard authorized else { return }
            }
            switch service {
            case "youtube":
                youtubeSelection = decodedSelection(state.snapshot.youtubeSelectionData)
                showYouTubePicker = true
            case "instagram":
                instagramSelection = decodedSelection(state.snapshot.instagramSelectionData)
                showInstagramPicker = true
            case "facebook":
                facebookSelection = decodedSelection(state.snapshot.facebookSelectionData)
                showFacebookPicker = true
            case "x":
                xSelection = decodedSelection(state.snapshot.xSelectionData)
                showXPicker = true
            default: break
            }
        }
    }

    private var screenTimeAccessSection: some View {
        Section {
            Button {
                Task { @MainActor in
                    isAuthorizingFamilyControls = true
                    _ = await state.requestFamilyControlsAuthorization()
                    isAuthorizingFamilyControls = false
                }
            } label: {
                HStack {
                    Text(String(localized: "Allow Screen Time", table: "Interface"))
                    Spacer()
                    if isAuthorizingFamilyControls { ProgressView() }
                }
            }
            .disabled(isAuthorizingFamilyControls)
        }
    }

    @ViewBuilder
    private var realtimeShieldSection: some View {
        Section {
            AppRecordingCard(
                preferredExtensionBundleID: state.broadcastExtensionBundleID,
                isRecording: state.snapshot.broadcastActive,
                onLearnMore: { showRealtimeBlockingBeta = true }
            )
            .padding(.bottom, 20)
            .listRowInsets(EdgeInsets())
            .listRowBackground(Color.clear)
            .listRowSeparator(.hidden)
        }
        if !IOSPauseCoordinator.strictModeBlocksPauses(state.snapshot) {
            PausePanel(safari: false)
        }
        Group {
            Group {
                serviceCard("apps.youtube", title: "YouTube", summary: appSummary("youtube"),
                    isConfigured: state.hasYouTubeSelection, onChoose: { chooseApplication("youtube") }) {
                    Toggle("Shorts", isOn: Binding(
                        get: { state.snapshot.realtimeYouTubeBlockingEnabled },
                        set: { state.setRealtimeYouTubeBlockingEnabled($0) }
                    ))
                    .disabled((disabledByStrict && state.snapshot.realtimeYouTubeBlockingEnabled) || !state.hasYouTubeSelection)

                    Toggle(String(localized: "Soft mode", table: "Interface"), isOn: Binding(
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

                    Button(role: .destructive) {
                        state.saveYouTubeSelection(FamilyActivitySelection())
                        if !state.hasYouTubeSelection {
                            state.setSoftYouTubeBlockingEnabled(false)
                            expandedService = nil
                        }
                    } label: {
                        Text(String(localized: "Reset", table: "Interface"))
                            .font(.body)
                            .frame(maxWidth: .infinity, minHeight: 44, alignment: .leading)
                    }
                    .buttonStyle(.borderless)
                    .disabled(disabledByStrict)
                    .accessibilityIdentifier("service.youtube.reset")
                }
                serviceCard("apps.instagram", title: "Instagram", summary: appSummary("instagram"),
                    isConfigured: state.hasInstagramSelection, onChoose: { chooseApplication("instagram") }) {
                    Toggle("Reels", isOn: Binding(
                        get: { state.snapshot.realtimeInstagramReelsBlockingEnabled },
                        set: { state.setRealtimeInstagramReelsBlockingEnabled($0) }
                    ))
                    .disabled((disabledByStrict && state.snapshot.realtimeInstagramReelsBlockingEnabled) || !state.hasInstagramSelection)

                    Toggle(String(localized: "Stories", table: "Interface"), isOn: Binding(
                        get: { state.snapshot.realtimeInstagramStoriesBlockingEnabled },
                        set: { state.setRealtimeInstagramStoriesBlockingEnabled($0) }
                    ))
                    .disabled((disabledByStrict && state.snapshot.realtimeInstagramStoriesBlockingEnabled) || !state.hasInstagramSelection)

                    Button(role: .destructive) {
                        state.saveInstagramSelection(FamilyActivitySelection())
                        if !state.hasInstagramSelection {
                            expandedService = nil
                        }
                    } label: {
                        Text(String(localized: "Reset", table: "Interface"))
                            .font(.body)
                            .frame(maxWidth: .infinity, minHeight: 44, alignment: .leading)
                    }
                    .buttonStyle(.borderless)
                    .disabled(disabledByStrict)
                    .accessibilityIdentifier("service.instagram.reset")
                }
                if state.facebookModelSelected || state.snapshot.realtimeFacebookBlockingEnabled {
                    serviceCard("apps.facebook", title: "Facebook", summary: appSummary("facebook"),
                    isConfigured: state.hasFacebookSelection, onChoose: { chooseApplication("facebook") }) {
                        Toggle("Reels", isOn: Binding(
                            get: { state.snapshot.realtimeFacebookReelsBlockingEnabled },
                            set: { state.setRealtimeFacebookReelsBlockingEnabled($0) }
                        ))
                        .disabled((disabledByStrict && state.snapshot.realtimeFacebookReelsBlockingEnabled) || !state.hasFacebookSelection || (!state.facebookModelSelected && !state.snapshot.realtimeFacebookReelsBlockingEnabled))

                        Toggle(String(localized: "Stories", table: "Interface"), isOn: Binding(
                            get: { state.snapshot.realtimeFacebookStoriesBlockingEnabled },
                            set: { state.setRealtimeFacebookStoriesBlockingEnabled($0) }
                        ))
                        .disabled((disabledByStrict && state.snapshot.realtimeFacebookStoriesBlockingEnabled) || !state.hasFacebookSelection || (!state.facebookModelSelected && !state.snapshot.realtimeFacebookStoriesBlockingEnabled))

                        Button(role: .destructive) {
                            state.saveFacebookSelection(FamilyActivitySelection())
                            if !state.hasFacebookSelection {
                                expandedService = nil
                            }
                        } label: {
                            Text(String(localized: "Reset", table: "Interface"))
                                .font(.body)
                                .frame(maxWidth: .infinity, minHeight: 44, alignment: .leading)
                        }
                        .buttonStyle(.borderless)
                        .disabled(disabledByStrict)
                        .accessibilityIdentifier("service.facebook.reset")
                    }
                }
                if state.xModelSelected || state.snapshot.realtimeXBlockingEnabled {
                    serviceCard("apps.x", title: "X", summary: appSummary("x"),
                    isConfigured: state.hasXSelection, onChoose: { chooseApplication("x") }) {
                        Toggle(String(localized: "Short videos", table: "Interface"), isOn: Binding(
                            get: { state.snapshot.realtimeXReelsBlockingEnabled },
                            set: { state.setRealtimeXReelsBlockingEnabled($0) }
                        ))
                        .disabled((disabledByStrict && state.snapshot.realtimeXReelsBlockingEnabled) || !state.hasXSelection || (!state.xModelSelected && !state.snapshot.realtimeXReelsBlockingEnabled))

                        Button(role: .destructive) {
                            state.saveXSelection(FamilyActivitySelection())
                            if !state.hasXSelection {
                                expandedService = nil
                            }
                        } label: {
                            Text(String(localized: "Reset", table: "Interface"))
                                .font(.body)
                                .frame(maxWidth: .infinity, minHeight: 44, alignment: .leading)
                        }
                        .buttonStyle(.borderless)
                        .disabled(disabledByStrict)
                        .accessibilityIdentifier("service.x.reset")
                    }
                }

            }
        }
    }

    private func appSummary(_ id: String) -> String {
        let selected: Bool
        let labels: [String]
        switch id {
        case "youtube":
            selected = state.hasYouTubeSelection
            labels = [state.snapshot.realtimeYouTubeBlockingEnabled ? String(localized: "Shorts") : nil,
                      state.snapshot.softYouTubeBlockingEnabled ? String(localized: "Soft YouTube blocking") : nil].compactMap { $0 }
        case "instagram":
            selected = state.hasInstagramSelection
            labels = [state.snapshot.realtimeInstagramReelsBlockingEnabled ? String(localized: "Reels") : nil,
                      state.snapshot.realtimeInstagramStoriesBlockingEnabled ? String(localized: "Stories") : nil].compactMap { $0 }
        case "facebook":
            selected = state.hasFacebookSelection
            labels = [state.snapshot.realtimeFacebookReelsBlockingEnabled ? String(localized: "Reels") : nil,
                      state.snapshot.realtimeFacebookStoriesBlockingEnabled ? String(localized: "Stories") : nil].compactMap { $0 }
        default:
            selected = state.hasXSelection
            labels = state.snapshot.realtimeXReelsBlockingEnabled ? [String(localized: "Reels")] : []
        }
        guard selected else { return String(localized: "Choose an app", table: "Interface") }
        let summary = restrictionSummary(labels)
        return state.snapshot.realtimeShieldEnabled || labels.isEmpty ? summary : String(localized: "Off") + " · " + summary
    }

    private func decodedSelection(_ data: Data?) -> FamilyActivitySelection {
        guard let data, let decoded = try? JSONDecoder().decode(FamilyActivitySelection.self, from: data) else {
            return FamilyActivitySelection()
        }
        return decoded
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
                Text(String(localized: "Strict mode", table: "Interface"))
            }
            .disabled(disabledByStrict)
            Toggle(String(localized: "Allow pauses in Strict mode", table: "Interface"), isOn: Binding(
                get: { SharedStore.pausesAllowedInStrictMode },
                set: { state.setPausesAllowedInStrictMode($0) }
            ))
            .disabled(disabledByStrict && !SharedStore.pausesAllowedInStrictMode)
            if let until = state.snapshot.strictModeUntil, disabledByStrict {
                Text(String(localized: "Locked until \(L10n.dateTime(until))"))
                    .font(.footnote).foregroundStyle(.secondary)
            }
        } footer: {
            Text(String(localized: "Enabled restrictions are locked for 24 hours.", table: "Interface"))
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

                Text(String(localized: "Share screen recordings of short-form feeds and everyday app use to help improve recognition."))

                Text(String(localized: "Social apps look different across devices, languages and app versions. Your recordings will help me train Slowth to recognize what should be blocked and avoid blocking regular content."))

                Text(String(localized: "Just record yourself using the app as usual. No explanations or labels needed — I’ll review and label the footage myself to train and test the blocking model."))

                Text(String(localized: "Please leave out private messages, notifications and personal information."))
                    .font(.footnote)
                    .foregroundStyle(.secondary)

                Link(destination: AppLocalization.contributionUploadURL()) {
                    Label("Upload test cases", systemImage: "square.and.arrow.up")
                        .font(.subheadline.weight(.semibold))
                        .frame(maxWidth: .infinity, minHeight: 32)
                }
                .buttonStyle(.borderedProminent)
                .accessibilityIdentifier("contribution.upload")
            }
            .font(.subheadline)
            .fixedSize(horizontal: false, vertical: true)
            .padding(.vertical, 10)
    }

    private var heroSection: some View {
        Section {
            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 12) {
                    HeroCard(
                        title: String(localized: "Help improve"),
                        subtitle: String(localized: "In-app blocking") + " 👉👈",
                        icon: "heart.text.clipboard",
                        gradient: [Color(red: 0.12, green: 0.65, blue: 0.57),
                                   Color(red: 0.08, green: 0.43, blue: 0.49)],
                        action: { showContribution = true }
                    )
                    .accessibilityIdentifier("contribution.card")

                    HeroCard(
                        title: String(localized: "How it works"),
                        subtitle: String(localized: "What Slowth does for you"),
                        icon: "sparkles",
                        gradient: [Color(red: 0.36, green: 0.46, blue: 0.95),
                                   Color(red: 0.55, green: 0.32, blue: 0.86)],
                        action: { showAbout = true }
                    )
                    if FeatureFlags.tipsEnabled {
                        HeroCard(
                            title: String(localized: "Support"),
                            subtitle: String(localized: "Tip the developer"),
                            icon: "heart.fill",
                            gradient: [Color(red: 0.95, green: 0.42, blue: 0.55),
                                       Color(red: 0.85, green: 0.20, blue: 0.45)],
                            action: { showSupportSheet = true }
                        )
                        .accessibilityIdentifier("support.card")
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
            Group {
                Link(destination: feedbackURL) {
                    HStack {
                        Text(String(localized: "Send feedback"))
                        Spacer()
                        Image(systemName: "envelope")
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
                Picker("Model (next recording)", selection: Binding(
                    get: { DebugModelSettings.selection(stored: debugModelBackend).rawValue },
                    set: { debugModelBackend = $0; state.refreshFacebookModelSelection() }
                )) {
                    ForEach(DebugModelBackend.allCases, id: \.rawValue) { backend in
                        Text(backend.title).tag(backend.rawValue)
                    }
                }
                .disabled(state.snapshot.broadcastActive || (state.snapshot.isStrictModeActive && (state.snapshot.realtimeFacebookBlockingEnabled || state.snapshot.realtimeXBlockingEnabled)))
            }
            Toggle("Save detection frames", isOn: $debugCaptureEnabled)
            if debugCaptureEnabled {
                if debugCaptureLibrary.authorizationStatus == .authorized
                    || debugCaptureLibrary.authorizationStatus == .limited {
                    Button {
                        debugCaptureLibrary.importPending()
                    } label: {
                        HStack {
                            Text("Save frames to Photos")
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
                Button("Clear pending frames", role: .destructive) {
                    debugCaptureLibrary.clearPending()
                }
                .disabled(debugCaptureLibrary.pendingEvents == 0)
            }
            DebugAppReviewControls(hasEnabledBlocking: state.hasEnabledBlockingForReview,
                                   isReady: isReadyForReview)
            Toggle("Tips", isOn: $tipsFeatureEnabled)
            DebugSavedLeavesControl()
            Button(String(localized: "Reset pauses", table: "Interface")) {
                do { try IOSPauseCoordinator.resetPausesForDebug() }
                catch { state.lastError = String(localized: "Could not reset pauses. Try again.", table: "Interface") }
            }
            Button("Reset Strict mode") {
                state.resetStrictModeForDebug()
            }
            .disabled(!state.snapshot.isStrictModeActive)

        } header: {
            Text("Debug")
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
