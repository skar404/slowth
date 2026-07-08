#if os(iOS)
import SwiftUI

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

private let feedbackURL = URL(string: "mailto:denis@malina.page?subject=Slowth%20feedback")!

struct ContentView: View {
    @StateObject private var state = AppState()
    @AppStorage("uiMode") private var uiMode: String = "ios"
    @State private var showSafariHelp = false
    @State private var showAbout = false

    var body: some View {
        NavigationStack {
            Form {
                heroSection
                if state.snapshot.isStrictModeActive {
                    strictBannerSection
                }
                sitesSection
                strictModeSection
                updatesSection
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
                .presentationDetents([.medium, .large])
                .presentationDragIndicator(.visible)
        }
        .sheet(isPresented: $showAbout) {
            AboutSheet()
                .presentationDetents([.medium, .large])
                .presentationDragIndicator(.visible)
        }
    }

    private var disabledByStrict: Bool { state.snapshot.isStrictModeActive }

    private var heroSection: some View {
        Section {
            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 12) {
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
        } header: {
            Text("Help")
        } footer: {
            Text(appVersion)
        }
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

    var body: some View {
        Group {
            if let action = action {
                Button(action: action) { content }
                    .buttonStyle(.plain)
            } else {
                content
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

#Preview {
    ContentView()
}
#endif
