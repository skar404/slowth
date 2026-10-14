import SwiftUI
import Combine

private func pauseButtonTitle(_ minutes: Int) -> String {
    switch minutes {
    case 1: return String(localized: "Pause for 1 minute", table: "Interface")
    case 5: return String(localized: "Pause for 5 minutes", table: "Interface")
    default: return String(localized: "Pause for 3 minutes", table: "Interface")
    }
}

struct PauseDurationSettings: View {
    let strict: Bool
    @State private var minutes = 3
    @State private var readable = false
    @State private var error: String?

    var body: some View {
        Section {
            Picker(String(localized: "Pause duration", table: "Interface"), selection: Binding(
                get: { minutes },
                set: { value in
                    do {
                        try IOSPauseCoordinator.setPauseMinutes(value)
                        minutes = value
                        error = nil
                    } catch {
                        self.error = String(localized: "Could not save pause duration", table: "Interface")
                    }
                }
            )) {
                ForEach(IOSPauseLedger.pauseMinuteOptions, id: \.self) { value in
                    Text(String(format: String(localized: "%lld min", table: "Interface"), value))
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
                minutes = try IOSPauseCoordinator.presentationSnapshot().pauseMinutes
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
    @StateObject private var model = PausePanelModel()
    @State private var showingTargetPicker = false
    @State private var showingSwitchPicker = false
    @State private var switchSource: IOSPauseLease?
    private let timer = Timer.publish(every: 1, on: .main, in: .common).autoconnect()
    private var labels: [String: String] { ["youtube": "YouTube", "instagram": "Instagram", "facebook": "Facebook", "x": "X", "tiktok": "TikTok"] }
    private var targets: [String] {
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
        (try? model.ledger.remaining(model.now, currentZone: TimeZone.current.identifier)) ?? 0
    }

    private var isExhausted: Bool {
        model.readable && remaining == 0 && model.ledger.lease == nil
    }

    private var canStart: Bool {
        !model.loading && model.readable && model.ledger.lease == nil && remaining > 0 &&
        !targets.isEmpty && !IOSPauseCoordinator.strictModeBlocksPauses(model.snapshot)
    }

    var body: some View {
        Section {
          VStack(alignment: .leading, spacing: 12) {
            HStack(alignment: .firstTextBaseline) {
                Text(String(localized: "Pauses today", table: "Interface")).font(.headline)
                Spacer(minLength: 8)
                HStack(spacing: 5) {
                    ForEach(0..<3) { index in
                        Image(systemName: index < remaining ? "leaf.fill" : "leaf")
                            .foregroundStyle(index < remaining ? Color.accentColor : .secondary)
                    }
                }
                .accessibilityElement(children: .ignore)
                .accessibilityLabel(String(format: String(localized: "%lld of 3 remaining", table: "Interface"), remaining))
            }
            HStack {
                Text(String(localized: "Saved leaves", table: "Interface"))
                Spacer()
                Label(model.readable ? "+\(model.ledger.savedLeaves)" : "—", systemImage: "leaf.fill")
                    .font(.headline.monospacedDigit())
                    .foregroundStyle(Color.accentColor)
            }
            Text(String(localized: "Unused leaves are saved after each day as a reward.", table: "Interface"))
                .font(.footnote).foregroundStyle(.secondary)
            if let lease = model.ledger.lease {
                VStack(alignment: .leading, spacing: 16) {
                    VStack(alignment: .leading, spacing: 6) {
                        Text((labels[lease.target] ?? lease.target) + (lease.kind == "safari" ? " · Safari" : ""))
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
                    .font(.subheadline.weight(.semibold))
                }
                .padding(16)
                .frame(maxWidth: .infinity, alignment: .leading)
                .background(Color.accentColor.opacity(0.06), in: RoundedRectangle(cornerRadius: 20))
            } else {
                Button {
                    model.refresh()
                    if canStart { showingTargetPicker = true }
                } label: {
                    Label(pauseButtonTitle(model.ledger.pauseMinutes), systemImage: "play.fill")
                        .frame(maxWidth: .infinity, minHeight: 32)
                }
                .buttonStyle(.borderedProminent)
                .disabled(!canStart)
                .confirmationDialog(
                    String(localized: safari ? "Choose a website to pause" : "Choose an app to pause", table: "Interface"),
                    isPresented: $showingTargetPicker,
                    titleVisibility: .visible
                ) {
                    ForEach(targets, id: \.self) { target in
                        Button(labels[target] ?? target) {
                            // Recheck after the dialog: another process may have changed eligibility.
                            model.refresh()
                            guard canStart, targets.contains(target) else { return }
                            model.start(target: target, safari: safari)
                        }
                    }
                    Button(String(localized: "Cancel"), role: .cancel) { }
                }
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
          }
          .padding(.vertical, 4)
          .saturation(isExhausted ? 0 : 1)
          .opacity(isExhausted ? 0.65 : 1)
          .listRowBackground(isExhausted
              ? Color(uiColor: .tertiarySystemFill)
              : Color(uiColor: UIColor { traits in
                  traits.userInterfaceStyle == .dark
                      ? UIColor(white: 0.125, alpha: 1) : .secondarySystemGroupedBackground
              }))
        } footer: {
            Text(String(localized: "Experimental: 3 pauses per day. Change their duration in Settings.", table: "Interface"))
        }
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
                Button(labels[target] ?? target) {
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
    @State private var minutes = 3
    @State private var available = false
    @State private var starting = false
    @State private var error: String?
    private let timer = Timer.publish(every: 1, on: .main, in: .common).autoconnect()

    var body: some View {
        VStack(spacing: 0) {
            if available || starting {
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
                            .font(.system(size: 20, weight: .semibold))
                            .foregroundStyle(.secondary)
                            .frame(width: 32, height: 32)
                            .accessibilityHidden(true)
                        Text(pauseButtonTitle(minutes))
                            .font(.body.weight(.semibold))
                        Spacer(minLength: 8)
                        if starting { ProgressView() }
                    }
                    .padding(20)
                    .frame(maxWidth: .infinity, minHeight: 80, alignment: .leading)
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .background(Color(uiColor: .secondarySystemGroupedBackground),
                            in: RoundedRectangle(cornerRadius: 22, style: .continuous))
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
        minutes = (try? IOSPauseCoordinator.presentationSnapshot().pauseMinutes) ?? 3
    }
}
