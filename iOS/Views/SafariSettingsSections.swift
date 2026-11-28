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
    .init(id: "x", label: "X"),
    .init(id: "threads", label: "Threads"),
    .init(id: "reddit", label: "Reddit"),
    .init(id: "linkedin", label: "LinkedIn")
]

struct SafariSiteSettingsSections: View {
    @ObservedObject var state: AppState
    @Binding var expandedService: String?
    var onlySite: String? = nil
    var body: some View {
        Group {
            ForEach(sites.filter { onlySite == nil || onlySite == $0.id }) { site in
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
                    }
                }
            }

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
            DisclosureGroup(isExpanded: Binding(
                get: { expandedService == id },
                set: { expandedService = $0 ? id : nil }
            )) { content() } label: {
                serviceLabel(id, title: site.label, summary: safariSummary(site.id), isConfigured: true)
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
        default: return feature.label(for: site)
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
