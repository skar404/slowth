import SwiftUI
import Combine

private func pauseButtonTitle(_ seconds: Int) -> String {
    switch seconds {
    case 60: return String(localized: "Pause for 1 minute", table: "Interface")
    case 30: return String(localized: "Pause for 30 seconds", table: "Interface")
    default: return String(localized: "Pause for 3 minutes", table: "Interface")
    }
}

struct PauseDurationSettings: View {
    let strict: Bool
    @State private var seconds = 60
    @State private var readable = false
    @State private var error: String?

    var body: some View {
        Section {
            Picker(String(localized: "Pause duration", table: "Interface"), selection: Binding(
                get: { seconds },
                set: { value in
                    do {
                        try IOSPauseCoordinator.setPauseSeconds(value)
                        seconds = value
                        error = nil
                    } catch {
                        self.error = String(localized: "Could not save pause duration", table: "Interface")
                    }
                }
            )) {
                ForEach(IOSPauseLedger.pauseSecondOptions, id: \.self) { value in
                    Text(value == 30
                         ? String(localized: "30 sec", table: "Interface")
                         : String(format: String(localized: "%lld min", table: "Interface"), locale: Locale.current, value / 60))
                        .tag(value)
                }
            }
            .disabled(!readable || strict)
            if let error { Text(error).font(.footnote).foregroundStyle(.orange) }
        } footer: {
            Text(String(localized: "Applies to new pauses in apps and Safari.", table: "Interface"))
        }
        .onAppear {
            do {
                seconds = try IOSPauseCoordinator.presentationSnapshot().pauseSeconds
                readable = true
                error = nil
            } catch {
                readable = false
                self.error = String(localized: "Pause state is unavailable", table: "Interface")
            }
        }
    }
}

@MainActor private final class PausePanelModel: ObservableObject {
    @Published var ledger = IOSPauseLedger()
    @Published var error: String?
    @Published var loading = false
    @Published var snapshot = SharedStore.snapshot()
    @Published var now = IOSPauseCoordinator.clock()
    @Published var readable = false
    private var refreshInFlight = false

    func refresh() {
        if ScreenshotPresentation.activeProtection {
            #if DEBUG && targetEnvironment(simulator)
            // An in-memory presentation fixture: never starts or persists a pause.
            if ProcessInfo.processInfo.arguments.contains("--screenshot-voluntary-pause") {
                now = IOSPauseClock(wall: 100, continuous: 100, boot: "screenshot")
                ledger.lease = IOSPauseLease(id: "screenshot", kind: "application",
                    target: "youtube", started: now, day: "screenshot", phase: "active",
                    charged: true, durationSeconds: 154)
            }
            #endif
            readable = true
            return
        }
        guard !refreshInFlight else { return }
        refreshInFlight = true
        do {
            ledger = try IOSPauseCoordinator.snapshot()
            snapshot = SharedStore.snapshot()
            now = IOSPauseCoordinator.clock()
            readable = true
        } catch { self.error = String(localized: "Pause state is unavailable", table: "Interface"); readable = false }
        refreshInFlight = false
    }

    func start(target: String, safari: Bool) {
        guard !loading else { return }
        loading = true
        error = nil
        let id = UUID().uuidString
        Task {
            do {
                try await Task.detached(priority: .userInitiated) {
                    if safari { try IOSPauseCoordinator.prepareSafari(target: target, id: id) }
                    else { try IOSPauseCoordinator.startApplication(target: target, id: id) }
                }.value
                self.error = await PauseActivityHost.start(id: id)
                if safari {
                    let hosts = ["youtube": "youtube.com", "instagram": "instagram.com", "facebook": "facebook.com", "x": "x.com", "tiktok": "tiktok.com"]
                    if let host = hosts[target], let url = URL(string: "https://" + host + "/") {
                        let opened = await UIApplication.shared.open(url)
                        if !opened { try IOSPauseCoordinator.cancelSafariPreparation(id) }
                    }
                }
            } catch {
                self.error = String(localized: "Could not start pause. Check permissions and try again.", table: "Interface")
            }
            loading = false
            refresh()
        }
    }

    func switchApplication(to target: String, from lease: IOSPauseLease) {
        guard !loading else { return }
        loading = true
        error = nil
        Task {
            do {
                try await Task.detached(priority: .userInitiated) {
                    try IOSPauseCoordinator.switchApplication(id: lease.id, from: lease.target, to: target)
                }.value
            } catch {
                self.error = String(localized: "Could not switch the paused app. Check the current pause and try again.", table: "Interface")
            }
            loading = false
            refresh()
        }
    }

    func end() {
        guard !loading, let id = ledger.lease?.id else { return }
        loading = true
        Task {
            do { try await Task.detached(priority: .userInitiated) { try IOSPauseCoordinator.finish(id: id) }.value }
            catch { self.error = String(localized: "Could not confirm pause completion", table: "Interface") }
            loading = false
            refresh()
        }
    }
}

struct PausePanel: View {
    @Environment(\.dynamicTypeSize) private var dynamicTypeSize
    let safari: Bool
    var preferredTarget: String? = nil
    var embedded = false
    var compact = false
    var sharedBackground = false
    var recordingExtensionBundleID: String? = nil
    var isRecording = false
    @StateObject private var model = PausePanelModel()
    @State private var showingTargetPicker = false
    @State private var showingSwitchPicker = false
    @State private var switchSource: IOSPauseLease?
    private let timer = Timer.publish(every: 1, on: .main, in: .common).autoconnect()
    private var targets: [String] {
        if ScreenshotPresentation.activeProtection { return ["youtube", "instagram"] }
        if safari {
            return IOSPauseCoordinator.sites.filter { model.snapshot.toggles[$0]?.dictionary.values.contains(true) == true }
        }
        return IOSPauseCoordinator.apps.filter {
            IOSPauseCoordinator.enabled($0, state: model.snapshot) && IOSPauseCoordinator.selection($0, state: model.snapshot) != nil
        }
    }
    private var switchTargets: [String] {
        IOSPauseCoordinator.applicationSwitchTargets(model.ledger, state: model.snapshot, now: model.now)
    }

    private var remaining: Int {
        ScreenshotPresentation.activeProtection ? (model.ledger.lease == nil ? 3 : 2)
            : (try? model.ledger.remaining(model.now, currentZone: TimeZone.current.identifier)) ?? 0
    }

    private var isExhausted: Bool {
        model.readable && remaining == 0 && model.ledger.lease == nil
    }

    private var canStart: Bool {
        if ScreenshotPresentation.activeProtection { return true }
        return !model.loading && model.readable && model.ledger.lease == nil && remaining > 0 &&
        !targets.isEmpty && (preferredTarget == nil || targets.contains(preferredTarget!)) &&
        (safari || preferredTarget.map { !IOSPauseCoordinator.hasSelectionConflict($0, state: model.snapshot) } != false) &&
        !IOSPauseCoordinator.strictModeBlocksPauses(model.snapshot)
    }

    var body: some View {
        Group {
            if embedded {
                panelContent
                    .padding(.horizontal, sharedBackground ? 16 : compact ? 12 : 20)
                    .padding(.top, sharedBackground ? 0 : compact ? 12 : 20)
                    .padding(.bottom, sharedBackground ? 16 : compact ? 12 : 20)
                    .background(sharedBackground ? Color.clear : panelBackground)
            } else {
                Section {
                    panelContent
                        .listRowBackground(panelBackground)
                } footer: {
                    Text(String(localized: "Experimental: 3 pauses per day. Change their duration in Settings.", table: "Interface"))
                }
            }
        }
        .allowsHitTesting(!ScreenshotPresentation.activeProtection)
        .onAppear { model.refresh() }
        #if targetEnvironment(simulator)
        .task {
            // Screenshot entry point: present the real dialog without starting a pause.
            if safari && ProcessInfo.processInfo.arguments.contains("--preview-pause-picker") {
                try? await Task.sleep(nanoseconds: 350_000_000)
                model.refresh()
                if canStart { showingTargetPicker = true }
            }
        }
        #endif
        .onReceive(timer) { _ in
            model.refresh()
            if !canStart { showingTargetPicker = false }
            if switchTargets.isEmpty || model.ledger.lease?.id != switchSource?.id ||
                model.ledger.lease?.target != switchSource?.target {
                showingSwitchPicker = false
            }
        }
    }

    private var panelBackground: Color {
        isExhausted ? Color(uiColor: .tertiarySystemFill)
            : Color(uiColor: UIColor { traits in
                traits.userInterfaceStyle == .dark
                    ? UIColor(white: 0.125, alpha: 1) : .secondarySystemGroupedBackground
            })
    }

    private var panelContent: some View {
          VStack(alignment: .leading, spacing: compact ? 8 : 12) {
            HStack(alignment: .firstTextBaseline) {
                Text(String(localized: "Pauses today", table: "Interface"))
                    .font(compact ? .subheadline.weight(.medium) : .headline)
                Spacer(minLength: 8)
                HStack(spacing: 5) {
                    ForEach(0..<3) { index in
                        Image(systemName: index < remaining ? "leaf.fill" : "leaf")
                            .foregroundStyle(index < remaining ? Color.accentColor : .secondary)
                    }
                }
                .accessibilityElement(children: .ignore)
                .accessibilityLabel(String(format: String(localized: "%lld of 3 remaining", table: "Interface"), locale: Locale.current, remaining))
            }
            HStack {
                Text(String(localized: "Saved leaves", table: "Interface"))
                    .font(compact ? .caption : .body)
                Spacer()
                Label(model.readable ? "+\(model.ledger.savedLeaves)" : "—", systemImage: "leaf.fill")
                    .font((compact ? Font.caption.weight(.medium) : .headline).monospacedDigit())
                    .foregroundStyle(Color.accentColor)
            }
            if !compact {
                Text(String(localized: "Unused leaves are saved after each day as a reward.", table: "Interface"))
                    .font(.footnote).foregroundStyle(.secondary)
            }
            if let lease = model.ledger.lease {
                VStack(alignment: .leading, spacing: 16) {
                    VStack(alignment: .leading, spacing: 6) {
                        Text((PauseTargetDisplay.name(for: lease.target)) + (lease.kind == "safari" ? " · Safari" : ""))
                            .font(.headline)
                        if lease.phase == "preparing" {
                            Label(String(localized: "Waiting for Safari extension", table: "Interface"), systemImage: "hourglass")
                        } else {
                            let seconds = max(0, Int(ceil(lease.expiresAt - model.now.wall)))
                            Text(String(format: "%02d:%02d", seconds / 60, seconds % 60))
                                .font(.largeTitle.monospacedDigit())
                                .accessibilityLabel(String(localized: "Time remaining", table: "Interface"))
                                .accessibilityValue("\(seconds)")
                        }
                    }
                    let layout = dynamicTypeSize.isAccessibilitySize
                        ? AnyLayout(VStackLayout(spacing: 10))
                        : AnyLayout(HStackLayout(spacing: 10))
                    layout {
                        if lease.kind == "application" && lease.phase == "active" {
                            switchAppButton
                        }
                        if recordingExtensionBundleID == nil {
                        Button { model.end() } label: {
                            Label {
                                Text(lease.phase == "preparing"
                                     ? String(localized: "Cancel")
                                     : String(localized: "End pause", table: "Interface"))
                            } icon: {
                                Image(systemName: lease.phase == "preparing" ? "xmark" : "stop.fill")
                            }
                            .frame(maxWidth: .infinity, minHeight: 44)
                            .padding(.horizontal, 8)
                            .background(Color.primary.opacity(0.06), in: RoundedRectangle(cornerRadius: 14))
                        }
                        .buttonStyle(.plain)
                        .disabled(model.loading)
                        }
                    }
                    .font(.subheadline.weight(.semibold))
                }
                .padding(16)
                .frame(maxWidth: .infinity, alignment: .leading)
                .background(Color.accentColor.opacity(0.06), in: RoundedRectangle(cornerRadius: 20))
            } else {
                if !safari, targets.contains(where: { IOSPauseCoordinator.hasSelectionConflict($0, state: model.snapshot) }) {
                    Text(String(localized: "This app is already selected for another service.", table: "Interface"))
                        .font(.footnote).foregroundStyle(.orange)
                }
                if recordingExtensionBundleID == nil { pauseStartButton }
                if IOSPauseCoordinator.strictModeBlocksPauses(model.snapshot) {
                    Text(String(localized: "Strict mode active")).font(.footnote)
                    if let until = model.snapshot.strictModeUntil {
                        Text(String(localized: "Locked until \(L10n.dateTime(until))")).font(.footnote)
                    }
                } else if targets.isEmpty {
                    Text(String(localized: "Enable a restriction to use a pause", table: "Interface"))
                        .font(.footnote).foregroundStyle(.secondary)
                }
            }
            if let error = model.error { Text(error).font(.footnote).foregroundStyle(.orange) }
            if let recordingExtensionBundleID {
                let layout = dynamicTypeSize.isAccessibilitySize
                    ? AnyLayout(VStackLayout(spacing: 10))
                    : AnyLayout(HStackLayout(spacing: 10))
                layout {
                    RealtimeRecordingCard(preferredExtensionBundleID: recordingExtensionBundleID,
                                          isRecording: isRecording, guidance: "", actionOnly: true)
                    if let lease = model.ledger.lease {
                        Button { model.end() } label: {
                            Label(lease.phase == "preparing" ? String(localized: "Cancel")
                                  : String(localized: "End pause", table: "Interface"), systemImage: "stop.fill")
                                .font(.subheadline.weight(.medium))
                                .fixedSize(horizontal: false, vertical: true)
                                .padding(.horizontal, 12)
                                .frame(minHeight: 48, maxHeight: .infinity)
                                .background(Color.primary.opacity(0.06), in: RoundedRectangle(cornerRadius: 12))
                        }
                        .buttonStyle(.plain)
                        .disabled(model.loading)
                    } else {
                        pauseStartButton
                            .fixedSize(horizontal: !dynamicTypeSize.isAccessibilitySize, vertical: false)
                    }
                }
                .fixedSize(horizontal: false, vertical: true)
                .padding(.top, 8)
            }
          }
          .padding(.vertical, 4)
          .saturation(isExhausted && recordingExtensionBundleID == nil ? 0 : 1)
          .opacity(isExhausted && recordingExtensionBundleID == nil ? 0.65 : 1)
    }

    private var pauseStartButton: some View {
                Button {
                    model.refresh()
                    if canStart {
                        if let preferredTarget { model.start(target: preferredTarget, safari: safari) }
                        else { showingTargetPicker = true }
                    }
                } label: {
                    HStack(spacing: 6) {
                        Image(systemName: "pause.fill")
                        Text(recordingExtensionBundleID == nil ? pauseButtonTitle(model.ledger.pauseSeconds) : String(localized: "Pause", table: "Interface"))
                    }
                        .font(.subheadline.weight(.medium))
                        .fixedSize(horizontal: recordingExtensionBundleID != nil && !dynamicTypeSize.isAccessibilitySize, vertical: true)
                        .padding(.horizontal, 12)
                        .padding(.vertical, 8)
                        .frame(minHeight: recordingExtensionBundleID == nil ? 44 : 48,
                               maxHeight: recordingExtensionBundleID != nil && !dynamicTypeSize.isAccessibilitySize ? .infinity : nil)
                        .background(Color.primary.opacity(0.06), in: RoundedRectangle(cornerRadius: 12))
                }
                .buttonStyle(.plain)
                .disabled(!canStart)
                .accessibilityHint(pauseButtonTitle(model.ledger.pauseSeconds))
                .confirmationDialog(
                    String(localized: safari ? "Choose a website to pause" : "Choose an app to pause", table: "Interface"),
                    isPresented: $showingTargetPicker,
                    titleVisibility: .visible
                ) {
                    ForEach(targets, id: \.self) { target in
                        Button(PauseTargetDisplay.name(for: target)) {
                            // Recheck after the dialog: another process may have changed eligibility.
                            model.refresh()
                            guard canStart, targets.contains(target) else { return }
                            model.start(target: target, safari: safari)
                        }
                    }
                    Button(String(localized: "Cancel"), role: .cancel) { }
                }
    }

    private var switchAppButton: some View {
        Button {
            model.refresh()
            guard !switchTargets.isEmpty else { return }
            switchSource = model.ledger.lease
            showingSwitchPicker = true
        } label: {
            Label(String(localized: "Switch app", table: "Interface"), systemImage: "arrow.triangle.2.circlepath")
                .frame(maxWidth: .infinity, minHeight: 44)
                .padding(.horizontal, 8)
                .foregroundStyle(Color.accentColor)
                .background(Color.accentColor.opacity(0.14), in: RoundedRectangle(cornerRadius: 14))
        }
        .buttonStyle(.plain)
        .disabled(model.loading || !model.readable || switchTargets.isEmpty)
        .confirmationDialog(String(localized: "Choose an app to pause", table: "Interface"),
            isPresented: $showingSwitchPicker, titleVisibility: .visible) {
            ForEach(switchTargets, id: \.self) { target in
                Button(PauseTargetDisplay.name(for: target)) {
                    guard let source = switchSource else { return }
                    model.switchApplication(to: target, from: source)
                }
            }
            Button(String(localized: "Cancel"), role: .cancel) { }
        } message: {
            Text(String(localized: "The timer continues. No extra leaf is used.", table: "Interface"))
        }
    }

}
/// The Shield handoff carries the exact service; never spend a pause on another app.
struct ShieldPauseButton: View {
    let target: String
    let onStarted: () -> Void
    @State private var seconds = 60
    @State private var available = false
    @State private var starting = false
    @State private var error: String?
    private let timer = Timer.publish(every: 1, on: .main, in: .common).autoconnect()

    var body: some View {
        VStack(spacing: 0) {
            if available || starting {
                Divider()
                Button {
                    guard !starting, IOSPauseCoordinator.canStartApplicationPause(target: target) else {
                        refresh()
                        return
                    }
                    starting = true
                    error = nil
                    let id = UUID().uuidString
                    Task { @MainActor in
                        do {
                            try await Task.detached(priority: .userInitiated) {
                                try IOSPauseCoordinator.startApplication(target: target, id: id)
                            }.value
                            _ = await PauseActivityHost.start(id: id)
                            starting = false
                            onStarted()
                        } catch {
                            self.error = String(localized: "Could not start pause. Check permissions and try again.", table: "Interface")
                            starting = false
                            refresh()
                        }
                    }
                } label: {
                    HStack(spacing: 8) {
                        Image(systemName: "pause.circle")
                            .font(.system(size: 16, weight: .medium))
                            .foregroundStyle(.secondary)
                            .frame(width: 24, height: 24)
                            .accessibilityHidden(true)
                        Text(pauseButtonTitle(seconds))
                            .font(.subheadline.weight(.medium))
                            .fixedSize(horizontal: false, vertical: true)
                        if starting { ProgressView() }
                    }
                    .padding(.horizontal, 12)
                    .padding(.vertical, 8)
                    .frame(minHeight: 44, alignment: .leading)
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .background(Color(uiColor: .secondarySystemGroupedBackground))
                .disabled(starting)
                .accessibilityIdentifier("shield.pause")
            }
            if let error {
                Text(error).font(.footnote).foregroundStyle(.orange).padding(16)
            }
        }
        .onAppear { refresh() }
        .onChange(of: target) { _ in refresh() }
        .onReceive(timer) { _ in refresh() }
    }

    private func refresh() {
        guard !starting else { return }
        available = IOSPauseCoordinator.canStartApplicationPause(target: target)
        seconds = (try? IOSPauseCoordinator.presentationSnapshot().pauseSeconds) ?? 60
    }
}

/// Focused handoff from a pause-only app's Shield. Never offers recording access.
struct PauseOnlyPromptSheet: View {
    let target: String
    @Environment(\.dismiss) private var dismiss
    @StateObject private var model = PausePanelModel()
    @State private var available = false
    private let timer = Timer.publish(every: 1, on: .main, in: .common).autoconnect()

    private var appName: String { target == "tiktok" ? "TikTok" : "Snapchat" }
    private var remaining: Int? {
        guard model.readable else { return nil }
        return try? model.ledger.remaining(model.now, currentZone: TimeZone.current.identifier)
    }

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: 20) {
                    HStack(spacing: 16) {
                        Image("Service-" + target)
                            .resizable().scaledToFit().frame(width: 48, height: 48)
                            .clipShape(RoundedRectangle(cornerRadius: 12))
                            .accessibilityHidden(true)
                        VStack(alignment: .leading, spacing: 4) {
                            Text(appName).font(.title2.bold())
                                .accessibilityAddTraits(.isHeader)
                            Text(String(localized: "This app stays blocked outside pauses.", table: "Interface"))
                                .font(.subheadline).foregroundStyle(.secondary)
                        }
                    }

                    if !model.readable {
                        statusCard("Pause state is unavailable", icon: "exclamationmark.circle")
                    } else if let lease = model.ledger.lease {
                        activePause(lease)
                            .padding(20)
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .background(cardBackground, in: RoundedRectangle(cornerRadius: 22))
                    } else if let remaining {
                        pauseAllowance(remaining)
                        if remaining == 0 {
                            statusCard("Today's pause limit is reached", icon: "leaf",
                                       detail: "You have used all pauses for today. New pauses will be available tomorrow.")
                                .accessibilityIdentifier("shield.pause.exhausted")
                        } else if IOSPauseCoordinator.strictModeBlocksPauses(model.snapshot) {
                            statusCard("Strict mode active", icon: "lock.fill", table: "Localizable")
                        } else {
                            Button {
                                refresh()
                                guard available, !model.loading else { return }
                                model.start(target: target, safari: false)
                            } label: {
                                HStack(spacing: 16) {
                                    Image(systemName: "pause.fill")
                                        .font(.system(size: 20, weight: .semibold))
                                        .foregroundStyle(Color.accentColor)
                                        .frame(width: 40, height: 40)
                                        .background(Color.accentColor.opacity(0.10), in: RoundedRectangle(cornerRadius: 12))
                                        .accessibilityHidden(true)
                                    Text(pauseButtonTitle(model.ledger.pauseSeconds))
                                        .font(.body.weight(.semibold))
                                    Spacer(minLength: 0)
                                    if model.loading {
                                        ProgressView()
                                    } else {
                                        Image(systemName: "chevron.right")
                                            .font(.caption.weight(.semibold))
                                            .foregroundStyle(.secondary)
                                            .accessibilityHidden(true)
                                    }
                                }
                                .padding(20)
                                .frame(maxWidth: .infinity, minHeight: 80, alignment: .leading)
                                .contentShape(Rectangle())
                            }
                            .buttonStyle(.plain)
                            .background(cardBackground, in: RoundedRectangle(cornerRadius: 22))
                            .disabled(!available || model.loading)
                            .accessibilityIdentifier("shield.pause.start")
                            if !available && !model.loading {
                                Text(String(localized: IOSPauseCoordinator.hasSelectionConflict(target, state: model.snapshot)
                                    ? "This app is already selected for another service."
                                    : "Could not start pause. Check permissions and try again.", table: "Interface"))
                                    .font(.footnote).foregroundStyle(.secondary)
                            }
                        }
                    } else {
                        statusCard("Pause state is unavailable", icon: "exclamationmark.circle")
                    }
                    if let error = model.error {
                        Text(error).font(.footnote).foregroundStyle(.orange)
                    }
                }
                .fixedSize(horizontal: false, vertical: true)
                .frame(maxWidth: 560, alignment: .leading)
                .frame(maxWidth: .infinity)
                .padding(20)
            }
            .background(Color(uiColor: .systemGroupedBackground))
            .navigationTitle(String(localized: "In-app blocking"))
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button(String(localized: "Done")) { dismiss() }
                }
            }
        }
        .onAppear(perform: refresh)
        .onReceive(timer) { _ in refresh() }
    }

    private var cardBackground: Color { Color(uiColor: .secondarySystemGroupedBackground) }

    private func pauseAllowance(_ count: Int) -> some View {
        VStack(alignment: .leading, spacing: 12) {
            Text(String(localized: "Pauses today", table: "Interface")).font(.headline)
            HStack(spacing: 8) {
                ForEach(0..<3) { index in
                    Image(systemName: index < count ? "leaf.fill" : "leaf")
                        .font(.title2)
                        .foregroundStyle(index < count ? Color.accentColor : Color.secondary)
                        .frame(width: 44, height: 44)
                        .background(Color.accentColor.opacity(index < count ? 0.10 : 0.03), in: RoundedRectangle(cornerRadius: 12))
                }
            }
            .accessibilityHidden(true)
            Text(String(format: String(localized: "%lld of 3 remaining", table: "Interface"), locale: Locale.current, count))
                .font(.subheadline).foregroundStyle(.secondary)
        }
        .padding(20)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(cardBackground, in: RoundedRectangle(cornerRadius: 22))
    }

    private func statusCard(_ title: String.LocalizationValue, icon: String,
                            detail: String.LocalizationValue? = nil, table: String = "Interface") -> some View {
        VStack(alignment: .leading, spacing: 12) {
            Label(String(localized: title, table: table), systemImage: icon)
                .font(.headline)
            if let detail {
                Text(String(localized: detail, table: "Interface"))
                    .font(.subheadline).foregroundStyle(.secondary)
            }
        }
        .padding(20)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(cardBackground, in: RoundedRectangle(cornerRadius: 22))
    }

    private func activePause(_ lease: IOSPauseLease) -> some View {
        VStack(alignment: .leading, spacing: 20) {
            Text(String(localized: "Pause is active", table: "Interface"))
                .font(.headline)
            Text((PauseTargetDisplay.name(for: lease.target)) + (lease.kind == "safari" ? " · Safari" : ""))
            let seconds = max(0, Int(ceil(lease.expiresAt - model.now.wall)))
            Text(String(format: "%02d:%02d", seconds / 60, seconds % 60))
                .font(.largeTitle.monospacedDigit())
                .accessibilityLabel(String(localized: "Time remaining", table: "Interface"))
                .accessibilityValue("\(seconds)")
            if lease.target != target || lease.kind != "application" {
                if IOSPauseCoordinator.applicationSwitchTargets(model.ledger, state: model.snapshot, now: model.now).contains(target) {
                    Button {
                        model.switchApplication(to: target, from: lease)
                    } label: {
                        Text(String(localized: "Use this pause for this app", table: "Interface"))
                            .frame(maxWidth: .infinity, minHeight: 40)
                    }
                    .buttonStyle(.borderedProminent)
                    .disabled(model.loading)
                    Text(String(localized: "The timer continues. No extra leaf is used.", table: "Interface"))
                        .font(.footnote).foregroundStyle(.secondary)
                }
            }
            Button { model.end() } label: {
                Text(String(localized: "End pause", table: "Interface"))
                    .frame(maxWidth: .infinity, minHeight: 40)
            }
            .buttonStyle(.bordered)
            .disabled(model.loading)
        }
        .accessibilityIdentifier("shield.pause.active")
    }

    private func refresh() {
        guard !model.loading else { return }
        model.refresh()
        available = model.readable && IOSPauseCoordinator.canStartApplicationPause(target: target)
    }
}

/// An unknown Screen Time token must not imply a recording-based service.
/// Explicitly choosing a configured slot only routes the UI; it grants no access.
struct ShieldAppChoiceSheet: View {
    let onSelect: (String) -> Void
    @Environment(\.dismiss) private var dismiss
    @State private var targets: [String] = []

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: 20) {
                    Text(String(localized: "Choose an app", table: "Interface"))
                        .font(.title2.bold())
                        .accessibilityAddTraits(.isHeader)
                    Text(String(localized: "Screen Time couldn't identify the app. Choose the app you opened to continue.", table: "Interface"))
                        .font(.subheadline).foregroundStyle(.secondary)
                    VStack(spacing: 12) {
                        ForEach(targets, id: \.self) { target in
                            Button {
                                refresh()
                                guard targets.contains(target) else { return }
                                onSelect(target)
                            } label: {
                                HStack(spacing: 16) {
                                    Image("Service-" + target)
                                        .resizable().scaledToFit().frame(width: 36, height: 36)
                                        .clipShape(RoundedRectangle(cornerRadius: 9))
                                        .accessibilityHidden(true)
                                    Text(PauseTargetDisplay.name(for: target)).font(.headline)
                                    Spacer()
                                    Image(systemName: "chevron.right")
                                        .font(.caption.weight(.semibold)).foregroundStyle(.secondary)
                                        .accessibilityHidden(true)
                                }
                                .padding(20)
                                .frame(maxWidth: .infinity, alignment: .leading)
                                .contentShape(Rectangle())
                            }
                            .buttonStyle(.plain)
                            .background(Color(uiColor: .secondarySystemGroupedBackground),
                                        in: RoundedRectangle(cornerRadius: 22))
                            .accessibilityIdentifier("shield.choose." + target)
                        }
                    }
                }
                .frame(maxWidth: 560, alignment: .leading)
                .frame(maxWidth: .infinity)
                .padding(20)
            }
            .background(Color(uiColor: .systemGroupedBackground))
            .navigationTitle(String(localized: "In-app blocking"))
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button(String(localized: "Done")) { dismiss() }
                }
            }
        }
        .onAppear(perform: refresh)
    }

    private func refresh() {
        let state = SharedStore.snapshot()
        targets = IOSPauseCoordinator.apps.filter {
            IOSPauseCoordinator.selection($0, state: state) != nil
        }
    }
}

#if DEBUG
#Preview("Pause duration") {
    Form { PauseDurationSettings(strict: false) }
}
#Preview("Pause duration · strict mode") {
    Form { PauseDurationSettings(strict: true) }
}
#Preview("Pause · Safari") {
    Form { PausePanel(safari: true) }
        .tint(SlowthAppearance.sage)
}
#Preview("Pause · apps") {
    Form { PausePanel(safari: false, preferredTarget: "youtube") }
        .tint(SlowthAppearance.sage)
}
#Preview("Pause prompt") {
    PauseOnlyPromptSheet(target: "tiktok")
        .tint(SlowthAppearance.sage)
}
#Preview("Choose blocked app") {
    ShieldAppChoiceSheet(onSelect: { _ in })
        .tint(SlowthAppearance.sage)
}
#endif
