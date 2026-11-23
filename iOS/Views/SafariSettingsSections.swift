import SwiftUI

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

struct SafariSiteSettingsSections: View {
    @ObservedObject var state: AppState
    @Binding var expandedService: String?
    var onlySite: String? = nil
    var showsWebAppActions = false
    @Environment(\.openURL) private var openURL
    @AppStorage("webapps.hidden-services") private var hiddenServices = ""

    private var hiddenIDs: Set<String> {
        Set(hiddenServices.split(separator: ",").map(String.init))
    }

    private var visibleSites: [SiteSpec] {
        sites.filter { site in
            if let onlySite { return site.id == onlySite }
            return !showsWebAppActions || !hiddenIDs.contains(site.id)
        }
    }

    var body: some View {
        Group {
            ForEach(visibleSites) { site in
                if onlySite != nil {
                    Section {
                        siteControls(site)
                    } footer: {
                        siteNotes(site)
                    }
                } else {
                    siteCard(site) {
                        siteControls(site)
                        siteNotes(site)
                        if showsWebAppActions {
                            Button { setHidden(true, site: site) } label: {
                                Label(String(localized: "Hide from Web apps", table: "WebApps"), systemImage: "eye.slash")
                            }
                            .buttonStyle(.borderless)
                            .accessibilityIdentifier("webapps.hide." + site.id)
                        }
                    }
                }
            }

        }
    }

    private func setHidden(_ hidden: Bool, site: SiteSpec) {
        var ids = hiddenIDs
        if hidden { ids.insert(site.id) } else { ids.remove(site.id) }
        withAnimation {
            hiddenServices = ids.sorted().joined(separator: ",")
            if expandedService == "safari." + site.id { expandedService = nil }
        }
    }

    private func siteControls(_ site: SiteSpec) -> some View {
        ForEach(SiteBlockingControl.controls(for: site.id)) { control in
            Toggle(siteFeatureTitle(control.feature, site: control.site), isOn: bindingForSite(control.site, feature: control.feature))
                .disabled(state.groupSelectionRestSeconds > 0 || (disabledByStrict &&
                           (control.feature == .all || state.setting(control.feature, for: control.site))) ||
                          (control.feature != .all && state.setting(.all, for: control.site)))
                .accessibilityIdentifier(control.id)
        }
    }

    @ViewBuilder
    private func siteNotes(_ site: SiteSpec) -> some View {
        if state.setting(.all, for: site.id) {
            Text(String(localized: "Whole-site blocking takes priority", table: "Interface"))
                .font(.caption).foregroundStyle(.secondary)
        }
        if site.id == "instagram" {
            Text(String(localized: "Infinite Feed limits scrolling. On Instagram it also includes Explore and Stories."))
                .font(.caption).foregroundStyle(.secondary)
        }
    }

    private func safariSummary(_ id: String) -> String {
        if state.setting(.all, for: id) { return siteFeatureTitle(.all, site: id) }
        return restrictionSummary(SiteBlockingControl.controls(for: id).compactMap {
            $0.feature != .all && state.setting($0.feature, for: id) ? siteFeatureTitle($0.feature, site: id) : nil
        })
    }

    private func siteCard<Content: View>(_ site: SiteSpec, @ViewBuilder content: @escaping () -> Content) -> some View {
        let id = "safari." + site.id
        return Section {
            if showsWebAppActions, let service = WebAppService(rawValue: site.id) {
                HStack {
                    serviceLabel(id, title: site.label, summary: safariSummary(site.id), isConfigured: true)
                    Spacer()
                    if #available(iOS 18.4, *) {
                        Button(String(localized: "Open", table: "WebApps")) {
                            WebAppsRouter.shared.open(service)
                        }
                        .buttonStyle(.bordered)
                        .accessibilityIdentifier("webapps.open." + service.id)
                    }
                }
                if #available(iOS 18.4, *) {
                    Button { openURL(service.shortcutURL) } label: {
                        HStack {
                            Text(String(localized: "Add to Home Screen", table: "WebApps"))
                            Spacer()
                            Image(systemName: "arrow.up.right")
                        }
                    }
                    .buttonStyle(.borderless)
                    .accessibilityIdentifier("webapps.shortcut." + service.id)
                }
            }
            DisclosureGroup(isExpanded: Binding(
                get: { expandedService == id },
                set: { expandedService = $0 ? id : nil }
            )) { content() } label: {
                if showsWebAppActions {
                    Label(String(localized: "Blocking settings", table: "WebApps"), systemImage: "slider.horizontal.3")
                } else {
                    serviceLabel(id, title: site.label, summary: safariSummary(site.id), isConfigured: true)
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
        case .hideHomeFeed: return AppLocalization.string("Hide home feed")
        case .feed: return String(localized: "Infinite feed", table: "Interface")
        case .stories: return String(localized: "Stories", table: "Interface")
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
    private func bindingForSite(_ siteID: String, feature: SiteFeature) -> Binding<Bool> {
        Binding(
            get: { state.setting(feature, for: siteID) },
            set: { state.setSetting(feature, enabled: $0, for: siteID) }
        )
    }

}

struct HiddenWebAppsSection: View {
    @AppStorage("webapps.hidden-services") private var hiddenServices = ""
    @State private var isExpanded = false

    private var hiddenIDs: Set<String> {
        Set(hiddenServices.split(separator: ",").map(String.init))
    }

    var body: some View {
        let hidden = sites.filter { hiddenIDs.contains($0.id) }
        if !hidden.isEmpty {
            Section {
                DisclosureGroup(isExpanded: $isExpanded) {
                    ForEach(hidden) { site in
                        HStack {
                            Text(site.label).foregroundStyle(.secondary)
                            Spacer()
                            Button { restore(site) } label: {
                                Label(String(localized: "Show in Web apps", table: "WebApps"), systemImage: "arrow.up")
                                    .labelStyle(.iconOnly)
                            }
                            .buttonStyle(.borderless)
                            .accessibilityLabel(Text(String(localized: "Show in Web apps", table: "WebApps")) + Text(": " + site.label))
                            .accessibilityIdentifier("webapps.restore." + site.id)
                        }
                    }
                } label: {
                    HStack {
                        Label(String(localized: "Hidden", table: "WebApps"), systemImage: "eye.slash")
                        Spacer()
                        Text(hidden.count, format: .number)
                    }.foregroundStyle(.secondary)
                }
                .accessibilityIdentifier("webapps.hidden")
            }
        }
    }

    private func restore(_ site: SiteSpec) {
        var ids = hiddenIDs
        ids.remove(site.id)
        withAnimation {
            hiddenServices = ids.sorted().joined(separator: ",")
            if ids.isEmpty { isExpanded = false }
        }
    }
}

struct SafariRulesUpdateSection: View {
    @ObservedObject var state: AppState
    private var disabledByStrict: Bool { state.snapshot.isStrictModeActive }
    var body: some View {
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

    private static let relativeFormatter: RelativeDateTimeFormatter = {
        let f = RelativeDateTimeFormatter()
        f.unitsStyle = .short
        f.locale = L10n.locale
        return f
    }()
}
