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
    func compactServiceSpacing() -> some View {
        if #available(iOS 17.0, *) {
            self.listSectionSpacing(.custom(10))
                .contentMargins(.top, 8, for: .scrollContent)
        } else {
            self
        }
    }

    @ViewBuilder
    func serviceFormSpacing(compact: Bool) -> some View {
        if compact { self.compactServiceSpacing() } else { self }
    }

    // iPhone-style bottom-sheet detents only make sense in a compact-width
    // context. On full-screen iPad (regular width) they force an
    // undersized, bottom-anchored sheet instead of the platform's normal
    // centered form-sheet — so only apply them when the size class is compact.
    @ViewBuilder
    func compactSheetDetents(isCompact: Bool, startsCompact: Bool = false) -> some View {
        if isCompact && startsCompact {
            self.presentationDetents([.medium, .large])
                .presentationDragIndicator(.visible)
        } else if #available(iOS 27.1, *) {
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


// Observe above layout branching so folding does not discard capability or UI state.
private struct DuoHingeObserver: ViewModifier {
    @Binding var hasDeviceHinge: Bool

    @ViewBuilder
    func body(content: Content) -> some View {
        #if canImport(SwiftUI, _version: 8.0.85)
        if #available(iOS 27.1, *) {
            content.onHingeChange { _, context in
                // A nil update can mean temporary detachment during a display transition.
                if context.hinge != nil { hasDeviceHinge = true }
            }
        } else {
            content
        }
        #else
        content
        #endif
    }
}


struct ContentView: View {
    @StateObject private var state = AppState()
    @StateObject private var tipStore = TipStore()
    #if DEBUG
    @StateObject private var debugCaptureLibrary = DebugCapturePhotoLibrary()
    #endif
    @Environment(\.horizontalSizeClass) private var horizontalSizeClass
    @AppStorage("iosWelcomeV1Handled") private var welcomeHandled = false
    @AppStorage("shieldNotificationOfferHandled") private var notificationOfferHandled = false
    @State private var restToShow: IOSDetectionRest?
    @State private var restScrollTarget: String?
    @State private var restScrollRequest = UUID()
    @State private var pendingRests: [IOSDetectionRest] = []
    @State private var restPresentation = IOSRestPresentation()
    @State private var showWelcome = false
    @State private var welcomeDismissing = false
    @State private var welcomeSession = UUID()
    @State private var pendingWelcomeSafari = false
    @State private var shieldPrompt = IOSShieldPromptPresentation()
    private var pendingRecordingPrompt: Bool { shieldPrompt.isPending }
    @State private var visibleRestID: String?
    @State private var selectedSection = 0
    @State private var expandedService: String?
    @State private var expandedSafariService: String?
    @State private var hasDeviceHinge = false
    @State private var selectedDuoSection = 0

    private var isDuo: Bool { !isPad && hasDeviceHinge }
    @Environment(\.dynamicTypeSize) private var dynamicTypeSize

    private var isPad: Bool { UIDevice.current.userInterfaceIdiom == .pad }
    @State private var showSafariHelp = false
    @State private var showAbout = false
    @State private var showContribution = false
    @State private var showSupportSheet = false
    @State private var showRealtimeBlockingBeta = false
    @State private var showRealtimeRecordingPrompt = false
    @State private var showPauseOnlyPrompt = false
    @State private var recordingPromptPauseTarget: String?
    @State private var showStrictModeConfirmation = false
    #if DEBUG
    @AppStorage(DebugMode.storageKey, store: AppGroup.defaults) private var debugModeEnabled = false
    @AppStorage(DebugCaptureSettings.storageKey, store: AppGroup.defaults) private var debugCaptureEnabled = false
    @State private var versionTapCount = 0
    #endif
    #if canImport(FamilyControls)
    @ObservedObject private var familyControlsAuthorization = AuthorizationCenter.shared
    @State private var isAuthorizingFamilyControls = false
    @State private var showYouTubePicker = false
    @State private var showInstagramPicker = false
    @State private var showFacebookPicker = false
    @State private var showXPicker = false
    @State private var pauseOnlyPickerTarget: String?
    @State private var pauseOnlySelection = FamilyActivitySelection()
    @State private var youtubeSelection = FamilyActivitySelection()
    @State private var instagramSelection = FamilyActivitySelection()
    @State private var facebookSelection = FamilyActivitySelection()
    @State private var xSelection = FamilyActivitySelection()
    #endif

    init() {
        #if DEBUG && targetEnvironment(simulator)
        // Presentation-only screenshot arguments; never override settings or authorization.
        let arguments = ProcessInfo.processInfo.arguments
        if arguments.contains("--preview-rest") {
            var started = IOSPauseCoordinator.restClock()
            if let index = arguments.firstIndex(of: "--preview-rest-remaining"),
               arguments.indices.contains(index + 1), let remaining = Double(arguments[index + 1]),
               remaining.isFinite {
                started.continuous -= IOSDetectionRest.duration - min(60, max(1, remaining))
            }
            let rest = IOSDetectionRest(target: "youtube", started: started)
            _pendingRests = State(initialValue: [rest])
            _restToShow = State(initialValue: rest)
        }
        _selectedSection = State(initialValue: arguments.contains("--preview-settings") ? 2 : arguments.contains("--preview-safari") ? 1 : 0)
        _showSafariHelp = State(initialValue: arguments.contains("--preview-safari-help"))
        _showAbout = State(initialValue: arguments.contains("--preview-how-it-works"))
        if let index = arguments.firstIndex(of: "--preview-service"), arguments.indices.contains(index + 1) {
            let service = arguments[index + 1]
            if service.hasPrefix("safari.") { _expandedSafariService = State(initialValue: service) }
            _expandedService = State(initialValue: service)
        }
        #endif
    }

    var body: some View {
        GeometryReader { geometry in
            adaptiveLayout(in: geometry.size)
        }
        .modifier(DuoHingeObserver(hasDeviceHinge: $hasDeviceHinge))
        .tint(SlowthAppearance.sage)
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
        #if canImport(FamilyControls)
        .sheet(isPresented: Binding(get: { showWelcome }, set: { if !$0 { closeWelcome() } }), onDismiss: {
            welcomeDismissing = false
            finishSheetDismissal()
        }) {
            IOSWelcomeView(
                isCompact: horizontalSizeClass == .compact,
                isDuo: isDuo,
                authorized: FamilyControlsAuth.isAuthorized(familyControlsAuthorization.authorizationStatus),
                requestAuthorization: {
                    isAuthorizingFamilyControls = true
                    let granted = await state.requestFamilyControlsAuthorization()
                    isAuthorizingFamilyControls = false
                    finishSheetDismissal()
                    return granted
                },
                onAuthorized: {
                    guard showWelcome else { return }
                    selectedSection = 0
                    closeWelcome()
                },
                onSafari: {
                    pendingWelcomeSafari = true
                    closeWelcome()
                },
                onClose: { closeWelcome() }
            )
            .id(welcomeSession)
            .tint(SlowthAppearance.sage)
            .environment(\.horizontalSizeClass, horizontalSizeClass)
        }
        #endif
        .sheet(item: $restToShow, onDismiss: finishSheetDismissal) { rest in
            DetectionRestSheet(rest: rest)
                .compactSheetDetents(isCompact: horizontalSizeClass == .compact, startsCompact: true)
                .onAppear {
                    visibleRestID = rest.id
                    restPresentation.acknowledge(rest)
                }
                .onDisappear { visibleRestID = nil }
        }
        .sheet(isPresented: $showSafariHelp, onDismiss: finishSheetDismissal) {
            SafariHelpSheet(openSettings: { state.openSafariExtensionSettings() })
                .compactSheetDetents(isCompact: horizontalSizeClass == .compact)
        }
        .sheet(isPresented: $showAbout, onDismiss: finishSheetDismissal) {
            HowItWorksSheet(feedbackURL: feedbackURL)
                .compactSheetDetents(isCompact: horizontalSizeClass == .compact)
        }
        .sheet(isPresented: $showContribution, onDismiss: finishSheetDismissal) {
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
        .sheet(isPresented: $showSupportSheet, onDismiss: finishSheetDismissal) {
            SupportSheet(tipStore: tipStore)
                .compactSheetDetents(isCompact: horizontalSizeClass == .compact)
        }
        .sheet(isPresented: $showRealtimeBlockingBeta, onDismiss: finishSheetDismissal) {
            RealtimeBlockingBetaSheet(
                feedbackURL: realtimeBlockingFeedbackURL
            )
            .compactSheetDetents(isCompact: horizontalSizeClass == .compact)
        }
        #if canImport(FamilyControls)
        .sheet(isPresented: $showPauseOnlyPrompt, onDismiss: finishSheetDismissal) {
            if let target = recordingPromptPauseTarget {
                PauseOnlyPromptSheet(target: target)
                    .id(target)
                    .tint(SlowthAppearance.sage)
                    .compactSheetDetents(isCompact: horizontalSizeClass == .compact, startsCompact: true)
            }
        }
        .sheet(isPresented: $showRealtimeRecordingPrompt, onDismiss: finishSheetDismissal) {
            if let target = recordingPromptPauseTarget {
                RealtimeRecordingPromptSheet(
                    preferredExtensionBundleID: state.broadcastExtensionBundleID,
                    isRecording: state.snapshot.broadcastActive,
                    onLearnMore: { showRealtimeRecordingPrompt = false; showRealtimeBlockingBeta = true },
                    pauseTarget: target
                )
                .compactSheetDetents(isCompact: horizontalSizeClass == .compact, startsCompact: true)
            } else {
                ShieldAppChoiceSheet { target in
                    recordingPromptPauseTarget = target
                    shieldPrompt.enqueue(target: target)
                    shieldPrompt.beginDismissal()
                    showRealtimeRecordingPrompt = false
                }
                .tint(SlowthAppearance.sage)
                .compactSheetDetents(isCompact: horizontalSizeClass == .compact, startsCompact: true)
            }
        }
        .sheet(isPresented: $showYouTubePicker, onDismiss: finishSheetDismissal) {
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
        .sheet(isPresented: $showInstagramPicker, onDismiss: finishSheetDismissal) {
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
        .sheet(isPresented: $showFacebookPicker, onDismiss: finishSheetDismissal) {
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

        .sheet(isPresented: $showXPicker, onDismiss: finishSheetDismissal) {
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
        .sheet(isPresented: Binding(get: { pauseOnlyPickerTarget != nil }, set: { if !$0 { pauseOnlyPickerTarget = nil } }), onDismiss: finishSheetDismissal) {
            if let target = pauseOnlyPickerTarget {
                FamilyActivityPickerWrapper(
                    selection: pauseOnlySelection,
                    onDone: { selection in
                        state.savePauseOnlySelection(selection, target: target)
                        expandedService = state.hasPauseOnlySelection(target) ? "apps." + target : nil
                        pauseOnlyPickerTarget = nil
                    },
                    onCancel: { pauseOnlyPickerTarget = nil }
                )
                .id(target)
            }
        }
        .onReceive(Timer.publish(every: 1, on: .main, in: .common).autoconnect()) { _ in
            presentRealtimeRecordingPromptIfRequested()
            presentRestIfNeeded()
        }
        .onChange(of: state.lastError) { error in
            if error == nil { presentRealtimeRecordingPromptIfRequested() }
        }
        .onChange(of: showStrictModeConfirmation) { showing in
            if !showing { presentRealtimeRecordingPromptIfRequested() }
        }
        .onChange(of: familyControlsAuthorization.authorizationStatus) { _ in
            state.refreshProtectionAuthorization()
        }
        .onAppear {
            presentRealtimeRecordingPromptIfRequested()
            presentRestIfNeeded()
            considerAutomaticWelcome()
        }
        .onReceive(NotificationCenter.default.publisher(for: UIApplication.didBecomeActiveNotification)) { _ in
            presentRealtimeRecordingPromptIfRequested()
            presentRestIfNeeded()
            considerAutomaticWelcome()
        }
        #endif
        #if DEBUG
        .modifier(DebugCaptureLifecycle(state: state, debugCaptureLibrary: debugCaptureLibrary,
            debugCaptureEnabled: $debugCaptureEnabled, debugModeEnabled: debugModeEnabled))
        #endif
    }

    private func usesWidePadLayout(width: CGFloat) -> Bool {
        isPad && horizontalSizeClass == .regular && width >= 900 && !dynamicTypeSize.isAccessibilitySize
    }

    private var legacyTabs: some View {
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
        .environment(\.horizontalSizeClass, .compact)
    }

    @ViewBuilder
    private func adaptiveLayout(in size: CGSize) -> some View {
        #if canImport(SwiftUI, _version: 8.0.85)
        if #available(iOS 27.1, *), isDuo, horizontalSizeClass == .regular,
           size.width >= 720, !dynamicTypeSize.isAccessibilitySize {
            wideLayout(in: size, duo: true)
        } else if usesWidePadLayout(width: size.width) {
            wideLayout(in: size, duo: false)
        } else {
            legacyTabs
        }
        #else
        if usesWidePadLayout(width: size.width) {
            wideLayout(in: size, duo: false)
        } else {
            legacyTabs
        }
        #endif
    }

    @ViewBuilder
    private func wideColumns(duo: Bool) -> some View {
        #if canImport(SwiftUI, _version: 8.0.85)
        if #available(iOS 27.1, *), duo {
            // Each section has one owner, even when the system changes the split axis.
            ArrangementView {
                padColumn(0, duo: true).padding(.horizontal, 8)
            } secondary: {
                padColumn(1, duo: true).padding(.horizontal, 8)
            }
            .arrangementViewStyle(.split)
            .padding(.horizontal, -8)
        } else {
            HStack(spacing: 24) { padColumn(0); padColumn(1) }
        }
        #else
        HStack(spacing: 24) { padColumn(0); padColumn(1) }
        #endif
    }

    @ViewBuilder
    private func wideLayout(in size: CGSize, duo: Bool) -> some View {
        if #available(iOS 17.0, *), duo {
            NavigationStack {
                GeometryReader { contentGeometry in
                    duoContent(in: contentGeometry.size)
                }
                    .navigationTitle("Slowth")
                    .navigationBarTitleDisplayMode(.inline)
                    .toolbar {
                        ToolbarItem(placement: .primaryAction) {
                            Button { selectedSection = selectedSection == 2 ? 0 : 2 } label: {
                                Label(sectionTitle(2), systemImage: "gearshape")
                            }
                            .accessibilityIdentifier("duo.settings.toggle")
                        }
                    }
            }
            .inspector(isPresented: Binding(
                get: { selectedSection == 2 },
                set: { if !$0 { selectedSection = 0 } }
            )) {
                settingsPanelContent(duo: true)
                    .inspectorColumnWidth(384)
            }
        } else {
            wideContent(in: size, duo: false)
                .disabled(selectedSection == 2)
                .accessibilityHidden(selectedSection == 2)
                .overlay(alignment: .topTrailing) {
                    if selectedSection == 2 {
                        ZStack(alignment: .topTrailing) {
                            Color.black.opacity(0.15)
                                .ignoresSafeArea()
                                .contentShape(Rectangle())
                                .onTapGesture { selectedSection = 0 }
                                .accessibilityHidden(true)
                            settingsPanel(duo: false, availableHeight: size.height)
                        }
                    }
                }
        }
    }

    @ViewBuilder
    private func duoContent(in size: CGSize) -> some View {
        if size.width >= 720 {
            wideContent(in: size, duo: true)
        } else {
            // The native inspector consumes width. Adapt to the remaining content
            // area instead of squeezing two forms into unreadable columns.
            VStack(spacing: 0) {
                Picker("", selection: $selectedDuoSection) {
                    Text(sectionTitle(0)).tag(0)
                    Text(sectionTitle(1)).tag(1)
                }
                .pickerStyle(.segmented)
                .padding(.horizontal, 16)
                .padding(.vertical, 8)
                .accessibilityIdentifier("duo.content.sections")
                settingsLayout(in: size, section: selectedDuoSection)
            }
            .background(SlowthAppearance.background)
        }
    }

    private func wideContent(in size: CGSize, duo: Bool) -> some View {
        VStack(spacing: 0) {
            if !duo {
                HStack {
                    Label("Slowth", systemImage: "leaf.fill").font(.headline)
                    Spacer()
                    Button { selectedSection = 2 } label: {
                        Label(sectionTitle(2), systemImage: "gearshape")
                    }
                    .accessibilityIdentifier(duo ? "duo.settings.toggle" : "ipad.settings.toggle")
                }
                .padding(.horizontal, duo ? 16 : 24)
                .padding(.vertical, 12)
            }
            VStack(spacing: 16) {
                if duo && size.width < 900 {
                    ScrollView(.horizontal, showsIndicators: false) {
                        HStack(spacing: 12) { featureCards(compact: true) }
                            .frame(width: 720)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                    .fixedSize(horizontal: false, vertical: true)
                } else {
                    HStack(spacing: 12) { featureCards(compact: true) }
                }
                wideColumns(duo: duo)
            }
            .padding(.horizontal, duo ? 16 : 24)
            .padding(.top, 12)
            .frame(maxWidth: 1440)
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
        .background(SlowthAppearance.background)
    }

    private func settingsPanelContent(duo: Bool) -> some View {
        NavigationStack {
            settingsLayout(in: CGSize(width: 384, height: 0), section: 2)
                .navigationTitle(sectionTitle(2))
                .navigationBarTitleDisplayMode(.inline)
                .toolbar {
                    ToolbarItem(placement: .confirmationAction) {
                        Button { selectedSection = 0 } label: {
                            Image(systemName: "xmark")
                        }
                        .accessibilityLabel(String(localized: "Close", table: "Interface"))
                        .accessibilityIdentifier(duo ? "duo.settings.close" : "ipad.settings.close")
                        .keyboardShortcut(.cancelAction)
                    }
                }
        }
        .tint(.accentColor)
    }

    private func settingsPanel(duo: Bool, availableHeight: CGFloat) -> some View {
        settingsPanelContent(duo: duo)
        .frame(width: 384)
        .frame(maxHeight: duo ? max(0, availableHeight - 80) : 600)
        .clipShape(RoundedRectangle(cornerRadius: 28, style: .continuous))
        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 28, style: .continuous))
        .shadow(color: .black.opacity(0.12), radius: 20, y: 8)
        .padding(16)
        .padding(.top, 48)
        .accessibilityAddTraits(.isModal)
    }

    private func padColumn(_ section: Int, duo: Bool = false) -> some View {
        VStack(alignment: .leading, spacing: 0) {
            sectionLabel(section).padding(.horizontal, 20).padding(.vertical, 8)
            settingsLayout(in: CGSize(width: 600, height: 0), section: section, widePad: true)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .accessibilityIdentifier((duo ? "duo." : "ipad.") + (section == 0 ? "apps.column" : "safari.column"))
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

    private var previewingRest: Bool {
        #if DEBUG && targetEnvironment(simulator)
        ProcessInfo.processInfo.arguments.contains("--preview-rest")
        #else
        false
        #endif
    }

    private func settingsLayout(in size: CGSize, section: Int, widePad: Bool = false) -> some View {
        VStack(spacing: 0) {
            ScrollViewReader { proxy in
            Form {
                Group {
                if section == 0 {
                    if (isPad || isDuo) && !widePad { heroSection }
                    #if canImport(FamilyControls)
                    #if DEBUG && targetEnvironment(simulator)
                    if ScreenshotPresentation.activeProtection {
                        screenshotProtectionSection
                    } else if FamilyControlsAuth.isAuthorized(familyControlsAuthorization.authorizationStatus) || previewingRest {
                        realtimeShieldSection
                    } else {
                        screenTimeAccessSection
                        appProtectionPreviewSection
                    }
                    #else
                    if FamilyControlsAuth.isAuthorized(familyControlsAuthorization.authorizationStatus) || previewingRest {
                        realtimeShieldSection
                    } else {
                        screenTimeAccessSection
                        appProtectionPreviewSection
                    }
                    #endif
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
                    if !isPad && !isDuo { heroSection }
                    strictModeSection
                    PauseDurationSettings(strict: disabledByStrict)
                    #if canImport(FamilyControls)
                    if #unavailable(iOS 26.5) {
                        Section { ShieldNotificationPermissionView() }
                    }
                    #endif
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
            .serviceFormSpacing(compact: !((isPad || isDuo) && section == 2))
            .environment(\.defaultMinListRowHeight, 48)
            .accessibilityIdentifier(section == 0 ? "mainSettingsForm" : section == 1 ? "safariSettingsForm" : "appSettingsForm")
            .onChange(of: restScrollRequest) { _ in
                if section == 0, let target = restScrollTarget { proxy.scrollTo(target, anchor: .center) }
            }
            .onAppear {
                if section == 0, let target = restScrollTarget { proxy.scrollTo(target, anchor: .center) }
            }
            #if DEBUG && targetEnvironment(simulator)
            .task {
                let arguments = ProcessInfo.processInfo.arguments
                if ScreenshotPresentation.activeProtection, section == 0,
                   arguments.contains("--screenshot-scroll-service"), let target = expandedService {
                    try? await Task.sleep(nanoseconds: 600_000_000)
                    proxy.scrollTo(target, anchor: .top)
                }
            }
            #endif
            }
        }
        // The same navigation at every window width, including iPad Split View.
        .frame(maxWidth: size.width >= 700 ? 680 : .infinity)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(SlowthAppearance.background)
    }

    private func serviceCard<Content: View>(
        _ id: String, title: String, summary: String,
        isConfigured: Bool = true, onChoose: (() -> Void)? = nil, selectionHint: String? = nil,
        @ViewBuilder content: @escaping () -> Content
    ) -> some View {
        Section {
            Group {
                if let rest = pendingRests.first(where: { id == "apps." + $0.target }) {
                    Button {
                        // Refresh before opening: an elapsed or superseded cycle must not reappear.
                        guard presentationIsIdle else { return }
                        if previewingRest { restToShow = rest; return }
                        guard let refreshed = try? IOSPauseCoordinator.openRests() else { return }
                        pendingRests = refreshed
                        restToShow = refreshed.first { $0.id == rest.id }
                    } label: {
                        TimelineView(.periodic(from: .now, by: 1)) { _ in
                            let seconds = Int(ceil(rest.remaining(IOSPauseCoordinator.restClock())))
                            let countdown = Duration.seconds(seconds).formatted(.time(pattern: .minuteSecond))
                            HStack(spacing: 12) {
                                serviceLabel(id, title: title,
                                    summary: String(format: String(localized: "Unavailable for %@", table: "Interface"), countdown),
                                    isConfigured: true)
                                    .monospacedDigit()
                                Spacer(minLength: 0)
                                Image(systemName: "lock.fill")
                                    .foregroundStyle(.secondary)
                                    .accessibilityHidden(true)
                            }
                            .contentShape(Rectangle())
                        }
                    }
                    .buttonStyle(.plain)
                    .accessibilityIdentifier("rest." + rest.target)
                } else if !isConfigured, let onChoose {
                    Button(action: onChoose) {
                        HStack {
                            serviceLabel(id, title: title,
                                         summary: selectionHint ?? String(localized: "Choose an app", table: "Interface"),
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
                        get: { ((isPad || isDuo) && id.hasPrefix("safari.") ? expandedSafariService : expandedService) == id },
                        set: { value in
                            if (isPad || isDuo) && id.hasPrefix("safari.") { expandedSafariService = value ? id : nil }
                            else { expandedService = value ? id : nil }
                        }
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
            .id(id)
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
        guard restToShow == nil, welcomeHandled, !showWelcome, !welcomeDismissing, !pendingWelcomeSafari, !pendingRecordingPrompt,
              state.lastError == nil, !state.refreshing,
              !showSafariHelp, !showAbout, !showContribution, !showSupportSheet, !showRealtimeBlockingBeta,
              !showRealtimeRecordingPrompt, !showPauseOnlyPrompt, !showStrictModeConfirmation else { return false }
        #if canImport(FamilyControls)
        guard !isAuthorizingFamilyControls, !showYouTubePicker, !showInstagramPicker,
              !showFacebookPicker, !showXPicker, pauseOnlyPickerTarget == nil else { return false }
        #endif
        return true
    }

    #if canImport(FamilyControls)
    private func presentRealtimeRecordingPromptIfRequested() {
        let active = UIApplication.shared.applicationState == .active
        if shieldPrompt.receive(isActive: active, consume: {
            guard SharedStore.consumeRealtimeRecordingPromptRequest(target: &$0) else { return false }
            PauseOnlyApps.recordRouting("handoff", target: $0)
            return true
        }) {
            state.reload()
            selectedSection = 0
            pendingWelcomeSafari = false
            // Preserve the pending target independently of the currently visible sheet.
            let hasSheet = restToShow != nil || showWelcome || showRealtimeRecordingPrompt ||
                showPauseOnlyPrompt || showSafariHelp || showAbout || showContribution ||
                showSupportSheet || showRealtimeBlockingBeta || showYouTubePicker ||
                showInstagramPicker || showFacebookPicker || showXPicker || pauseOnlyPickerTarget != nil
            if hasSheet { shieldPrompt.beginDismissal() }
            restToShow = nil
            closeWelcome()
            showRealtimeRecordingPrompt = false
            showPauseOnlyPrompt = false
            showSafariHelp = false
            showAbout = false
            showContribution = false
            showSupportSheet = false
            showRealtimeBlockingBeta = false
            showYouTubePicker = false
            showInstagramPicker = false
            showFacebookPicker = false
            showXPicker = false
            pauseOnlyPickerTarget = nil
            showStrictModeConfirmation = false
        }
        guard active, presentationIsIdle, pendingRecordingPrompt else { return }
        let rests = try? IOSPauseCoordinator.openRests()
        guard let destination = shieldPrompt.take(isActive: active, isIdle: presentationIsIdle,
                                                   rests: rests, isPauseOnly: PauseOnlyApps.contains) else { return }
        switch destination {
        case .rest(let rest): restToShow = rest
        case .pause(let target):
            recordingPromptPauseTarget = target
            showPauseOnlyPrompt = true
        case .recording(let target):
            recordingPromptPauseTarget = target
            showRealtimeRecordingPrompt = true
        }
    }

    private func considerAutomaticWelcome() {
        guard !welcomeHandled, !ScreenshotPresentation.activeProtection else { return }
        if IOSWelcomeEligibility.isConfigured() {
            welcomeHandled = true
        } else if !pendingRecordingPrompt && !showRealtimeRecordingPrompt && presentationIsIdle {
            openWelcome()
        }
    }

    private func openWelcome() {
        guard presentationIsIdle, !pendingRecordingPrompt else { return }
        welcomeHandled = true
        welcomeSession = UUID()
        showWelcome = true
    }
    #endif

    private func closeWelcome() {
        guard showWelcome else { return }
        welcomeDismissing = true
        showWelcome = false
    }

    private var presentationIsIdle: Bool {
        guard !shieldPrompt.waitingForDismissal, restToShow == nil, !showWelcome, !welcomeDismissing, !showSafariHelp, !showAbout, !showContribution,
              !showSupportSheet, !showRealtimeBlockingBeta, !showRealtimeRecordingPrompt, !showPauseOnlyPrompt,
              !showStrictModeConfirmation, state.lastError == nil else { return false }
        #if canImport(FamilyControls)
        guard !isAuthorizingFamilyControls, !showYouTubePicker, !showInstagramPicker,
              !showFacebookPicker, !showXPicker, pauseOnlyPickerTarget == nil else { return false }
        #endif
        return true
    }

    private func presentRestIfNeeded() {
        #if DEBUG
        if ProcessInfo.processInfo.arguments.contains("--preview-rest") { return }
        #endif
        guard UIApplication.shared.applicationState == .active else { return }
        let rests = (try? IOSPauseCoordinator.openRests()) ?? []
        pendingRests = rests
        if let shown = restToShow {
            restToShow = rests.first { $0.id == shown.id }
            if let current = restToShow, visibleRestID == current.id { restPresentation.acknowledge(current) }
        } else if !pendingRecordingPrompt, presentationIsIdle, let rest = rests.first(where: { restPresentation.shouldPresent($0) }) {
            restToShow = rest
            if rest.requestedOrder != nil { selectedSection = 0 }
            expandedService = nil
            restScrollTarget = "apps." + rest.target
            restScrollRequest = UUID()
        }
    }

    private func finishSheetDismissal() {
        shieldPrompt.finishDismissal()
        #if canImport(FamilyControls)
        presentRealtimeRecordingPromptIfRequested()
        #endif
        guard UIApplication.shared.applicationState == .active, presentationIsIdle, !pendingRecordingPrompt else { return }
        if let rest = (try? IOSPauseCoordinator.openRests())?.first(where: { restPresentation.shouldPresent($0) }) {
            restToShow = rest
        } else if pendingWelcomeSafari {
            pendingWelcomeSafari = false
            selectedSection = 1
            showSafariHelp = true
        }
    }

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
            if PauseOnlyApps.contains(service) {
                pauseOnlySelection = decodedSelection(PauseOnlyApps.data(service))
                pauseOnlyPickerTarget = service
                return
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
            VStack(alignment: .leading, spacing: 14) {
                Image(systemName: "leaf.fill")
                    .font(.title2)
                    .foregroundStyle(SlowthAppearance.sage)
                    .accessibilityHidden(true)
                Text(String(localized: "Continue setup", table: "Interface"))
                    .font(.title2.bold())
                Text(String(localized: "Choose at least one app to start recording.", table: "Interface"))
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                Button(action: openWelcome) {
                    Text(String(localized: "Set up app protection", table: "Interface"))
                        .fontWeight(.semibold)
                        .frame(maxWidth: .infinity, minHeight: 36)
                }
                .buttonStyle(.borderedProminent)
                .buttonBorderShape(.capsule)
                .accessibilityIdentifier("welcome.setup")
            }
            .padding(.vertical, 12)
        }
    }

    private var appProtectionPreviewSection: some View {
        Section {
            appProtectionPreview("youtube", title: "YouTube", detail: "Shorts")
            appProtectionPreview("instagram", title: "Instagram",
                                 detail: "Reels · " + String(localized: "Stories", table: "Interface"))
            if state.facebookModelSelected || state.snapshot.realtimeFacebookBlockingEnabled {
                appProtectionPreview("facebook", title: "Facebook",
                                     detail: "Reels · " + String(localized: "Stories", table: "Interface"))
            }
            if state.xModelSelected || state.snapshot.realtimeXBlockingEnabled {
                appProtectionPreview("x", title: "X",
                                     detail: String(localized: "Short videos", table: "Interface"))
            }
            ForEach(PauseOnlyApps.targets, id: \.self) { target in
                appProtectionPreview(target, title: target == "tiktok" ? "TikTok" : "Snapchat",
                                     detail: pauseOnlyDescription(target))
            }
        } header: {
            Text(String(localized: "What you can protect", table: "Interface"))
        } footer: {
            Text(String(localized: "Screen Time is needed for app protection. You choose apps and settings after allowing access.", table: "Interface"))
        }
    }

    private func pauseOnlyDescription(_ target: String) -> String {
        target == "snapchat"
            ? String(localized: "Content blocking is in development. For now, only pause mode is available.", table: "Interface")
            : String(localized: "Currently supported only in pause mode.", table: "Interface")
    }

    private func appProtectionPreview(_ id: String, title: String, detail: String) -> some View {
        Button(action: openWelcome) {
            HStack(spacing: 12) {
                serviceLabel("apps." + id, title: title, summary: detail, isConfigured: false)
                Spacer(minLength: 0)
                Image(systemName: "chevron.right")
                    .font(.footnote.weight(.semibold))
                    .foregroundStyle(.tertiary)
            }
            .padding(.vertical, 8)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityIdentifier("preview.apps." + id)
    }

    #if DEBUG && targetEnvironment(simulator)
    @ViewBuilder
    private var screenshotProtectionSection: some View {
        Section {
            RecordingPauseCard {
                AppRecordingCard(
                    preferredExtensionBundleID: state.broadcastExtensionBundleID,
                    isRecording: true,
                    onLearnMore: {},
                    showsPause: true
                )
            }
            .allowsHitTesting(false)
            .listRowInsets(EdgeInsets())
            .listRowBackground(Color.clear)
            .listRowSeparator(.hidden)
        } footer: {
            Text(String(localized: "Experimental: 3 pauses per day. Change their duration in Settings.", table: "Interface"))
        }
        serviceCard("apps.youtube", title: "YouTube", summary: "Shorts") {
            Toggle("Shorts", isOn: .constant(true))
            Toggle(String(localized: "Soft mode", table: "Interface"), isOn: .constant(false))
        }
        .allowsHitTesting(false)
        serviceCard("apps.instagram", title: "Instagram",
                    summary: "Reels · " + String(localized: "Stories", table: "Interface")) {
            Toggle("Reels", isOn: .constant(true))
        }
        .allowsHitTesting(false)
        serviceCard("apps.facebook", title: "Facebook",
                    summary: "Reels · " + String(localized: "Stories", table: "Interface")) {
            Toggle("Reels", isOn: .constant(true))
        }
        .allowsHitTesting(false)
        serviceCard("apps.x", title: "X", summary: String(localized: "Short videos", table: "Interface")) {
            Toggle(String(localized: "Short videos", table: "Interface"), isOn: .constant(true))
        }
        .allowsHitTesting(false)
        ForEach(PauseOnlyApps.targets, id: \.self) { target in
            serviceCard("apps." + target, title: target == "tiktok" ? "TikTok" : "Snapchat",
                        summary: String(localized: "Blocked outside pauses", table: "Interface")) {
                Text(pauseOnlyDescription(target))
            }
            .allowsHitTesting(false)
        }
    }
    #endif

    @ViewBuilder
    private var realtimeShieldSection: some View {
        let configured = SharedStore.hasRecordingSelection()
        if !configured {
            Section {
                VStack(alignment: .leading, spacing: 8) {
                    Text(String(localized: "Set up the apps below", table: "Interface"))
                        .font(.headline)
                    Text(String(localized: "Choose at least one app to enable blocking.", table: "Interface"))
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                }
                .fixedSize(horizontal: false, vertical: true)
                .padding(.vertical, 8)
                .accessibilityElement(children: .combine)
                .accessibilityIdentifier("apps.setup.hint")
            }
        }
        if configured && !notificationOfferHandled {
            if #unavailable(iOS 26.5) {
                Section { ShieldNotificationPermissionView(isInitialOffer: true) }
            }
        }
        // A running recording can always be stopped, even after the last binding
        // is removed. All other recording/pause UI belongs after app selection.
        if configured || state.snapshot.broadcastActive {
            Section {
                RecordingPauseCard {
                    AppRecordingCard(
                        preferredExtensionBundleID: state.broadcastExtensionBundleID,
                        isRecording: state.snapshot.broadcastActive,
                        onLearnMore: { showRealtimeBlockingBeta = true },
                        showsPause: configured && !IOSPauseCoordinator.strictModeBlocksPauses(state.snapshot)
                    )
                }
                .listRowInsets(EdgeInsets())
                .listRowBackground(Color.clear)
                .listRowSeparator(.hidden)
            } footer: {
                if configured && !IOSPauseCoordinator.strictModeBlocksPauses(state.snapshot) {
                    Text(String(localized: "Experimental: 3 pauses per day. Change their duration in Settings.", table: "Interface"))
                }
            }
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
        ForEach(PauseOnlyApps.targets, id: \.self) { target in
            serviceCard("apps." + target, title: target == "tiktok" ? "TikTok" : "Snapchat",
                        summary: target == "snapchat" ? pauseOnlyDescription(target) : String(localized: "Blocked outside pauses", table: "Interface"),
                        isConfigured: state.hasPauseOnlySelection(target),
                        onChoose: { chooseApplication(target) },
                        selectionHint: pauseOnlyDescription(target)) {
                Label(String(localized: "Blocked outside pauses", table: "Interface"), systemImage: "lock.fill")
                if target == "snapchat" {
                    Text(pauseOnlyDescription(target))
                        .font(.subheadline).foregroundStyle(.secondary)
                }
                Text(String(localized: "Currently supported only in pause mode. Start a pause to open the app. Screen recording is not required.", table: "Interface"))
                    .font(.subheadline).foregroundStyle(.secondary)
                Button(role: .destructive) {
                    state.savePauseOnlySelection(FamilyActivitySelection(), target: target)
                    if !state.hasPauseOnlySelection(target) { expandedService = nil }
                } label: {
                    Text(String(localized: "Reset", table: "Interface"))
                        .frame(maxWidth: .infinity, minHeight: 44, alignment: .leading)
                }
                .disabled(disabledByStrict)
                .accessibilityIdentifier("service." + target + ".reset")
            }
        }
    }

    private func appSummary(_ id: String) -> String {
        let selected: Bool
        let labels: [String]
        switch id {
        case "youtube":
            selected = state.hasYouTubeSelection
            labels = [state.snapshot.realtimeYouTubeBlockingEnabled ? "Shorts" : nil,
                      state.snapshot.softYouTubeBlockingEnabled ? String(localized: "Soft YouTube blocking") : nil].compactMap { $0 }
        case "instagram":
            selected = state.hasInstagramSelection
            labels = [state.snapshot.realtimeInstagramReelsBlockingEnabled ? "Reels" : nil,
                      state.snapshot.realtimeInstagramStoriesBlockingEnabled ? String(localized: "Stories", table: "Interface") : nil].compactMap { $0 }
        case "facebook":
            selected = state.hasFacebookSelection
            labels = [state.snapshot.realtimeFacebookReelsBlockingEnabled ? "Reels" : nil,
                      state.snapshot.realtimeFacebookStoriesBlockingEnabled ? String(localized: "Stories", table: "Interface") : nil].compactMap { $0 }
        default:
            selected = state.hasXSelection
            labels = state.snapshot.realtimeXReelsBlockingEnabled ? ["Reels"] : []
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
            .tint(isPad ? .green : SlowthAppearance.sage)
            .disabled(disabledByStrict)
            Toggle(String(localized: "Allow pauses in Strict mode", table: "Interface"), isOn: Binding(
                get: { SharedStore.pausesAllowedInStrictMode },
                set: { state.setPausesAllowedInStrictMode($0) }
            ))
            .tint(isPad ? .green : SlowthAppearance.sage)
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
            Group {
                if !isPad && !isDuo {
                    VStack(spacing: 10) {
                        let layout = dynamicTypeSize.isAccessibilitySize
                            ? AnyLayout(VStackLayout(spacing: 10))
                            : AnyLayout(HStackLayout(alignment: .top, spacing: 10))
                        layout {
                            featureCards(compact: false, flexible: true, includeSupport: false)
                        }
                        if FeatureFlags.tipsEnabled { phoneSupportCard }
                    }
                    .padding(.vertical, 12)
                } else {
                    ScrollView(.horizontal, showsIndicators: false) {
                        Group {
                            if isDuo {
                                HStack(spacing: 12) { featureCards(compact: true) }
                                    .frame(width: 720)
                                    .fixedSize(horizontal: false, vertical: true)
                            } else {
                                HStack(spacing: 12) { featureCards(compact: false) }
                            }
                        }
                        .padding(.horizontal, 16)
                        .padding(.vertical, 12)
                    }
                }
            }
            .listRowInsets(EdgeInsets())
            .listRowBackground(Color.clear)
            .listRowSeparator(.hidden)
        }
    }

    @ViewBuilder
    private func featureCards(compact: Bool, flexible: Bool = false, includeSupport: Bool = true) -> some View {
        IOSFeatureCard(
            title: String(localized: "Help improve"),
            subtitle: String(localized: "In-app blocking") + " 👉👈",
            icon: "heart.text.clipboard",
            gradient: [Color(red: 0.12, green: 0.65, blue: 0.57),
                       Color(red: 0.08, green: 0.43, blue: 0.49)],
            action: { showContribution = true }, compact: compact, flexible: flexible
        )
        .accessibilityIdentifier("contribution.card")

        IOSFeatureCard(
            title: String(localized: "How it works"),
            subtitle: String(localized: "What Slowth does for you"),
            icon: "sparkles",
            gradient: [Color(red: 0.36, green: 0.46, blue: 0.95),
                       Color(red: 0.55, green: 0.32, blue: 0.86)],
            action: { showAbout = true }, compact: compact, flexible: flexible
        )
        if includeSupport && FeatureFlags.tipsEnabled {
            IOSFeatureCard(
                title: String(localized: "Support"),
                subtitle: String(localized: "Tip the developer"),
                icon: "heart.fill",
                gradient: [Color(red: 0.95, green: 0.42, blue: 0.55),
                           Color(red: 0.85, green: 0.20, blue: 0.45)],
                action: { showSupportSheet = true }, compact: compact
            )
            .accessibilityIdentifier("support.card")
        }
    }


    private var phoneSupportCard: some View {
        Button { showSupportSheet = true } label: {
            HStack(spacing: 10) {
                Image(systemName: "heart.fill")
                    .font(.body)
                Text(String(localized: "Tip the developer"))
                    .font(.subheadline.weight(.semibold))
                    .fixedSize(horizontal: false, vertical: true)
                Spacer(minLength: 0)
                Image(systemName: "chevron.forward")
                    .font(.caption.weight(.semibold))
            }
            .foregroundStyle(.white)
            .padding(.horizontal, 16)
            .padding(.vertical, 12)
            .frame(maxWidth: .infinity, minHeight: 48, alignment: .leading)
            .background(LinearGradient(
                colors: [Color(red: 0.95, green: 0.42, blue: 0.55), Color(red: 0.85, green: 0.20, blue: 0.45)],
                startPoint: .leading, endPoint: .trailing))
            .clipShape(RoundedRectangle(cornerRadius: 16, style: .continuous))
        }
        .buttonStyle(.plain)
        .accessibilityIdentifier("support.card")
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
            VStack(alignment: .leading, spacing: 4) {
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
    }

    #if DEBUG
    private var debugSection: some View {
        DebugIOSSection(state: state, debugModeEnabled: $debugModeEnabled, isReadyForReview: isReadyForReview, debugCaptureLibrary: debugCaptureLibrary, debugCaptureEnabled: $debugCaptureEnabled)
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


#endif

#if os(iOS)
private struct DetectionRestSheet: View {
    let rest: IOSDetectionRest
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(spacing: 12) {
                    Group {
                        TimelineView(.periodic(from: .now, by: 1)) { _ in
                            let remaining = rest.remaining(IOSPauseCoordinator.restClock())
                            DetectionRestCountdown(target: rest.target, remaining: remaining, compact: true)
                        }
                    }
                    .padding(12)
                    .background(SlowthAppearance.card, in: RoundedRectangle(cornerRadius: 18))

                    PausePanel(safari: false, preferredTarget: rest.target, embedded: true, compact: true)
                        .clipShape(RoundedRectangle(cornerRadius: 18))

                    if !SharedStore.snapshot().broadcastActive {
                        Group {
                            VStack(alignment: .leading, spacing: 12) {
                                Text(String(localized: "Screen recording is off", table: "Interface"))
                                    .font(.headline)
                                HStack {
                                    Text(String(localized: "Enable blocking", table: "Interface"))
                                    Spacer()
                                    RecordingToolbarButton(preferredExtensionBundleID: (Bundle.main.bundleIdentifier ?? "") + ".Broadcast")
                                }
                            }
                            .padding(.vertical, 8)
                        }
                        .padding(12)
                        .background(SlowthAppearance.card, in: RoundedRectangle(cornerRadius: 18))
                    }
                }
                .frame(maxWidth: 560)
                .frame(maxWidth: .infinity)
                .padding(.horizontal, 16)
                .padding(.vertical, 12)
            }
            .background(SlowthAppearance.background)
            .navigationTitle(String(localized: "Rest", table: "Interface"))
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button(String(localized: "Close", table: "Interface")) { dismiss() }
                        .accessibilityIdentifier("rest.close")
                }
            }
        }
        .tint(SlowthAppearance.sage)
        .buttonBorderShape(.capsule)
    }
}
#endif

#if DEBUG && os(iOS)
private extension ContentView {
    init(previewSection: Int) {
        _state = StateObject(wrappedValue: AppState(previewSnapshot: .defaultState))
        _selectedSection = State(initialValue: previewSection)
        _selectedDuoSection = State(initialValue: previewSection)
    }

    // Render the real layout without the host's automatic onboarding and shield prompts.
    var previewLayout: some View {
        GeometryReader { geometry in
            adaptiveLayout(in: geometry.size)
        }
        .tint(SlowthAppearance.sage)
        .allowsHitTesting(false)
    }

    var contributionPreview: some View {
        NavigationStack {
            ScrollView {
                contributionContent.padding(24)
            }
            .navigationTitle("Help improve Slowth")
            .navigationBarTitleDisplayMode(.inline)
        }
    }
}

#Preview("Apps · iPhone") {
    ContentView(previewSection: 0).previewLayout
}
#Preview("Safari · iPhone") {
    ContentView(previewSection: 1).previewLayout
}
#Preview("Settings · iPhone") {
    ContentView(previewSection: 2).previewLayout
}
#Preview("Settings · dark · large text") {
    ContentView(previewSection: 2).previewLayout
        .preferredColorScheme(.dark)
        .dynamicTypeSize(.accessibility1)
}
@available(iOS 17.0, macOS 14.0, *)
#Preview("Main · iPad", traits: .fixedLayout(width: 1194, height: 834)) {
    ContentView(previewSection: 0).previewLayout
        .environment(\.horizontalSizeClass, .regular)
}
#Preview("Contribute") {
    ContentView(previewSection: 2).contributionPreview
}
#Preview("Support · iOS") {
    SupportSheet(tipStore: TipStore())
}
#Preview("Detection rest") {
    DetectionRestSheet(rest: IOSDetectionRest(target: "youtube", started: IOSPauseCoordinator.restClock()))
        .tint(SlowthAppearance.sage)
}
#endif
