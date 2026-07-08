import SwiftUI

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

private let feedbackURL = URL(string: "mailto:denis@malina.page?subject=Slowth%20feedback")!

struct MacContentView: View {
    @StateObject private var state = AppState()
    @State private var showAbout = false
    #if os(iOS)
    @AppStorage("uiMode") private var uiMode: String = "ios"
    #endif

    var body: some View {
        Form {
            Section {
                HStack(spacing: 10) {
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
                            Text(modeLabel(mode)).tag(mode)
                        }
                    }
                    .disabled(disabledByStrict)
                }
            } header: {
                Text("Sites")
            } footer: {
                Text("Off — extension does nothing. Block shorts hides reels & shorts. Block shorts + feed also blocks the infinite feed (Facebook & Instagram). Block site redirects the whole site.")
                    .font(.callout)
                    .foregroundStyle(.secondary)
            }

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

            Section {
                Link("Send feedback", destination: feedbackURL)
            } header: {
                Text("Help")
            } footer: {
                Text(appVersion)
                    .font(.callout)
                    .foregroundStyle(.secondary)
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
    }

    private var disabledByStrict: Bool { state.snapshot.isStrictModeActive }

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
            return "Updated " + Self.relativeFormatter.localizedString(for: date, relativeTo: Date())
        }
        return "Never updated"
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
        return "Slowth v\(v) (\(b))"
    }

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
                        title: "Hide Shorts & Reels",
                        detail: "On YouTube, Instagram, Facebook and X, Slowth hides the Shorts/Reels tab, ribbon and feed entries.")
                InfoRow(icon: "shield.lefthalf.filled",
                        title: "Block whole sites",
                        detail: "TikTok is replaced with a friendly blocked page. You can opt any site into full block too.")
                InfoRow(icon: "slider.horizontal.3",
                        title: "Per-site control",
                        detail: "For each site choose Off, Block shorts, Block shorts + feed, or Block site. Facebook & Instagram add the feed option; TikTok is Off or Block.")
                InfoRow(icon: "lock.fill",
                        title: "Strict mode (24 h)",
                        detail: "Locks every toggle for 24 hours. Survives restart and force-quit. The only bypass is reinstalling the app.")
                InfoRow(icon: "arrow.triangle.2.circlepath",
                        title: "Self-updating rules",
                        detail: "Selectors and redirects are pulled from a remote rules file, so the extension keeps working when sites change their layout.")
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

    var body: some View {
        Group {
            if let action {
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
