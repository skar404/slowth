import SwiftUI
import StoreKit
#if os(iOS)
import UIKit
#endif

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


struct MacContentView: View {
    @StateObject private var state = AppState()
    @StateObject private var tipStore = TipStore()
    @State private var showAbout = false
    @State private var showSupportSheet = false
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
                    if !state.snapshot.supportCardDismissed {
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
                .buttonStyle(.plain)
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
        .sheet(isPresented: $showSupportSheet) {
            SupportSheet(tipStore: tipStore)
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
            URLQueryItem(name: "subject", value: "Slowth feedback"),
            URLQueryItem(name: "body", value: "\n\n(Helps me debug — delete if you'd rather not share.)\n\(appVersion)\n\(deviceInfo)")
        ]
        return components.url!
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
    var onDismiss: (() -> Void)? = nil

    var body: some View {
        Group {
            if let action {
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
                        Text("Support Slowth")
                            .font(.title3.weight(.semibold))
                        Text("Doesn't unlock anything. Just a way to say thanks.")
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
                        Text("Looks like this is broken for now")
                            .font(.subheadline.weight(.semibold))
                        Text("We'll fix it soon — come back later.")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                            .multilineTextAlignment(.center)
                    } else {
                        Text("Oops... try again later")
                            .font(.subheadline.weight(.semibold))
                        Text("Something broke. Even for a sloth, this is slow.")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                            .multilineTextAlignment(.center)
                        Button {
                            retryTapped()
                        } label: {
                            if isRetrying {
                                ProgressView().controlSize(.small)
                            } else {
                                Text("Reload")
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
                Label("Thanks! It really helps.", systemImage: "heart.fill")
                    .foregroundStyle(.pink)
                    .font(.callout.weight(.semibold))
            }

            if !tipStore.history.isEmpty {
                VStack(alignment: .leading, spacing: 6) {
                    Text("Your support")
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
                Button("Done") { dismiss() }
                    .keyboardShortcut(.defaultAction)
            }
        }
        .padding(20)
        .frame(width: 420)
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
            Text(date.formatted(date: .abbreviated, time: .omitted))
                .font(.callout)
                .foregroundStyle(.secondary)
        }
    }
}
