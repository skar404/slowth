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
    @State private var expandedSites: Set<String> = []
    #endif
    @State private var showAbout = false
    @State private var showSupportSheet = false
    @State private var showRealtimeBlockingBeta = false
    @State private var showStrictModeConfirmation = false
    #if DEBUG
    @AppStorage(DebugMode.storageKey, store: AppGroup.defaults) private var debugModeEnabled = false
    @State private var versionTapCount = 0
    #endif
    #if os(iOS)
    @AppStorage("shieldNotificationOfferHandled") private var notificationOfferHandled = false
    @State private var showRealtimeRecordingPrompt = false
    #endif
    #if os(iOS) && canImport(FamilyControls)
    @ObservedObject private var familyControlsAuthorization = AuthorizationCenter.shared
    @State private var isAuthorizingFamilyControls = false
    @State private var showGroupedPicker = false
    @State private var groupedSelection = FamilyActivitySelection()
    @State private var showYouTubePicker = false
    @State private var youtubeSelection = FamilyActivitySelection()
    #endif

    var body: some View {
        Form {
            Section {
                ScrollView(.horizontal, showsIndicators: false) {
                    HStack(spacing: 10) {
                        #if os(iOS)
                        HeroCard(
                            title: AppLocalization.string("In-app blocking"),
                            subtitle: AppLocalization.string("Shorts, Reels & Stories"),
                            icon: "record.circle.fill",
                            gradient: [Color(red: 0.98, green: 0.24, blue: 0.34),
                                       Color(red: 0.79, green: 0.12, blue: 0.45)],
                            action: { showRealtimeBlockingBeta = true }
                        )
                        #else
                        HeroCard(
                            title: AppLocalization.string("New on iOS"),
                            subtitle: AppLocalization.string("In-app blocking"),
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

            #if os(macOS)
            safariSiteSections
            #else
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
            #endif

            #if os(iOS) && canImport(FamilyControls)
            if #unavailable(iOS 26.5) {
                Section {
                    ShieldNotificationPermissionView()
                } header: {
                    Text(String(localized: "Settings", table: "Interface"))
                }
            }
            #endif

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
                Link(AppLocalization.string("Rate Slowth"), destination: AppReviewCoordinator.reviewURL)
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
                Text(AppLocalization.string("Feedback & Support"))
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
                if let evidence = BuildProvenance.current {
                    Link(destination: evidence.runURL) {
                        Text(verbatim: "CI · \(evidence.shortCommit)")
                    }
                }
            }
        }
        .formStyle(.grouped)
        .navigationTitle("Slowth")
        .appReviewPrompt(hasEnabledBlocking: state.hasEnabledBlockingForReview, isReady: isReadyForReview)
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
            HowItWorksSheet(feedbackURL: feedbackURL)
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
                isRecording: state.snapshot.broadcastActive,
                onLearnMore: { showRealtimeRecordingPrompt = false; showRealtimeBlockingBeta = true },
                pauseTarget: "apps"
            )
        }
        .sheet(isPresented: $showGroupedPicker) {
            FamilyActivityPickerWrapper(selection: groupedSelection, allowsMultiple: true,
                onDone: { selection in
                    state.lastError = nil
                    state.saveGroupedSelection(selection)
                    if state.lastError == nil { showGroupedPicker = false }
                }, onCancel: { showGroupedPicker = false })
        }
        .sheet(isPresented: $showYouTubePicker) {
            FamilyActivityPickerWrapper(selection: youtubeSelection, appName: "YouTube",
                onDone: { selection in
                    state.lastError = nil
                    state.saveGroupedYouTube(selection)
                    if state.lastError == nil { showYouTubePicker = false }
                }, onCancel: { showYouTubePicker = false })
        }
        .onAppear(perform: presentRealtimeRecordingPromptIfRequested)
        .onReceive(NotificationCenter.default.publisher(for: UIApplication.didBecomeActiveNotification)) { _ in
            presentRealtimeRecordingPromptIfRequested()
        }
        #endif
    }

    private var disabledByStrict: Bool { state.snapshot.isStrictModeActive }

    private var isReadyForReview: Bool {
        guard state.lastError == nil, !state.refreshing,
              !showAbout, !showSupportSheet, !showRealtimeBlockingBeta,
              !showStrictModeConfirmation else { return false }
        #if os(iOS)
        guard !showRealtimeRecordingPrompt else { return false }
        #endif
        #if os(iOS) && canImport(FamilyControls)
        guard !isAuthorizingFamilyControls, !showYouTubePicker, !showGroupedPicker else { return false }
        #endif
        return true
    }

    #if os(iOS) && canImport(FamilyControls)
    private func presentRealtimeRecordingPromptIfRequested() {
        guard SharedStore.consumeRealtimeRecordingPromptRequest() else { return }
        state.reload()
        showRealtimeRecordingPrompt = true
    }
    #endif

    #if os(iOS) && canImport(FamilyControls)
    @ViewBuilder
    private var realtimeShieldSection: some View {
        if !FamilyControlsAuth.isAuthorized(familyControlsAuthorization.authorizationStatus) {
            Section {
                Button(AppLocalization.string("Allow Screen Time access")) {
                    Task {
                        isAuthorizingFamilyControls = true
                        _ = await state.requestFamilyControlsAuthorization()
                        isAuthorizingFamilyControls = false
                    }
                }.disabled(isAuthorizingFamilyControls)
            }
        } else {
            if SharedStore.hasRecordingSelection() || state.snapshot.broadcastActive {
                Section {
                    RecordingPauseCard {
                        AppRecordingCard(preferredExtensionBundleID: state.broadcastExtensionBundleID,
                            isRecording: state.snapshot.broadcastActive,
                            onLearnMore: { showRealtimeBlockingBeta = true },
                            showsPause: !IOSPauseCoordinator.strictModeBlocksPauses(state.snapshot))
                    }
                }
            }
            GroupedAppSelectionSection(state: state, tokens: GroupedApps.orderedTokens) {
                groupedSelection = GroupedApps.pickerSelection
                showGroupedPicker = true
            }
            GroupedAppAdvancedSettings(state: state, tokens: GroupedApps.orderedTokens, onChooseYouTube: {
                youtubeSelection = state.snapshot.youtubeSelectionData.flatMap {
                    try? JSONDecoder().decode(FamilyActivitySelection.self, from: $0)
                } ?? FamilyActivitySelection()
                showYouTubePicker = true
            })
        }
    }
    #endif

    #if os(macOS)
    private var safariSiteSections: some View {
        ForEach(sites) { site in
            Section {
                DisclosureGroup(isExpanded: Binding(
                    get: { expandedSites.contains(site.id) },
                    set: { expanded in
                        if expanded { expandedSites.insert(site.id) }
                        else { expandedSites.remove(site.id) }
                    }
                )) {
                    siteControls(for: site)
                        .padding(.top, 4)
                } label: {
                    HStack(spacing: 10) {
                        Image("Service-" + site.id)
                            .resizable()
                            .scaledToFit()
                            .frame(width: 26, height: 26)
                            .clipShape(RoundedRectangle(cornerRadius: 6, style: .continuous))
                            .accessibilityHidden(true)
                        Text(verbatim: site.label)
                            .font(.headline)
                            .accessibilityAddTraits(.isHeader)
                    }
                }
                .disclosureGroupStyle(SiteDisclosureStyle())
                .accessibilityIdentifier("site-section-" + site.id)
            } header: {
                if site.id == sites.first?.id {
                    Text(AppLocalization.string("Safari extension settings"))
                }
            } footer: {
                if site.id == sites.last?.id {
                    Text(AppLocalization.string("Infinite Feed limits scrolling. On Instagram it also includes Explore and Stories."))
                        .font(.callout)
                        .foregroundStyle(.secondary)
                }
            }
        }
    }
    #endif

    #if os(macOS)
    private func siteControls(for site: SiteSpec) -> some View {
        VStack(spacing: 0) {
            ForEach(SiteBlockingControl.controls(for: site.id)) { control in
                if control.feature != .all { Divider() }
                Toggle(isOn: bindingForSite(control.site, feature: control.feature)) {
                    Text(control.feature.label(for: control.site))
                        .fontWeight(control.feature == .all ? .medium : .regular)
                        .frame(maxWidth: .infinity, alignment: .leading)
                }
                .toggleStyle(.switch)
                .controlSize(.small)
                .padding(.vertical, 5)
                .disabled((disabledByStrict &&
                           (control.feature == .all || state.setting(control.feature, for: control.site))) ||
                          (control.feature != .all && state.setting(.all, for: control.site)))
                .accessibilityIdentifier(control.id)
            }
        }
        .padding(.leading, 36)
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
        DebugCompactSection(state: state, debugModeEnabled: $debugModeEnabled, isReadyForReview: isReadyForReview)
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
            subject: AppLocalization.string("Slowth — In-app blocking feedback"),
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

#if DEBUG
private extension MacContentView {
    init(previewSnapshot: SharedState) {
        _state = StateObject(wrappedValue: AppState(previewSnapshot: previewSnapshot))
    }
}
@available(iOS 17.0, macOS 14.0, *)
#Preview("Main · compact", traits: .fixedLayout(width: 680, height: 820)) {
    MacContentView(previewSnapshot: .defaultState)
        .allowsHitTesting(false)
}
@available(iOS 17.0, macOS 14.0, *)
#Preview("Main · compact · dark", traits: .fixedLayout(width: 680, height: 820)) {
    MacContentView(previewSnapshot: .defaultState)
        .preferredColorScheme(.dark)
        .allowsHitTesting(false)
}
#Preview("Support · compact") {
    SupportSheet(tipStore: TipStore())
}
#endif

#if os(macOS)
private struct SiteDisclosureStyle: DisclosureGroupStyle {
    func makeBody(configuration: Configuration) -> some View {
        VStack(alignment: .leading, spacing: 0) {
            Button {
                withAnimation(.easeInOut(duration: 0.18)) {
                    configuration.isExpanded.toggle()
                }
            } label: {
                HStack(spacing: 12) {
                    configuration.label
                    Spacer(minLength: 12)
                    Image(systemName: "chevron.down")
                        .font(.caption.weight(.semibold))
                        .foregroundStyle(.secondary)
                        .rotationEffect(.degrees(configuration.isExpanded ? 180 : 0))
                        .accessibilityHidden(true)
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(.vertical, 6)
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            if configuration.isExpanded {
                configuration.content
            }
        }
    }
}
#endif
