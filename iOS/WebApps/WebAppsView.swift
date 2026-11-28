import SwiftUI

enum WebAppsHelpTopic: String, Identifiable {
    case safariExtension, webApps
    var id: Self { self }
}

struct WebAppsLauncher: View {
    @Binding var editMode: EditMode
    var showsHelpCards = true
    let showHelp: (WebAppsHelpTopic) -> Void
    let showSettings: (WebAppService) -> Void
    @AppStorage("webapps.hidden-services") private var hiddenServices = ""
    @Environment(\.dynamicTypeSize) private var dynamicTypeSize
    @Environment(\.verticalSizeClass) private var verticalSizeClass
    @Environment(\.openURL) private var openURL

    private var hidden: Set<String> {
        Set(hiddenServices.split(separator: ",").map(String.init))
    }

    var body: some View {
        GeometryReader { geometry in
            VStack(spacing: 0) {
                if showsHelpCards {
                    helpCards
                        .fixedSize(horizontal: false, vertical: true)
                        .padding(.horizontal, 16)
                        .padding(.vertical, 8)
                }

                ScrollView {
                    if #available(iOS 18.4, *) {
                        let services = WebAppService.allCases.filter { editMode.isEditing || !hidden.contains($0.id) }
                        if services.isEmpty {
                            Button { editMode = .active } label: {
                                Label(String(localized: "Show in Web apps", table: "WebApps"), systemImage: "eye")
                            }.padding()
                        } else {
                            let available = max(1, geometry.size.width - 32)
                            let cellWidth: CGFloat = dynamicTypeSize.isAccessibilitySize ? 138 : 82
                            let count = min(6, max(1, Int(available / cellWidth)))
                            LazyVGrid(columns: Array(repeating: GridItem(.flexible(), spacing: 0), count: count),
                                      alignment: .leading, spacing: 24) {
                                ForEach(services) { service in
                                    tile(service)
                                }
                            }
                            .padding(.horizontal, 16)
                            .padding(.vertical, 24)
                        }
                    } else {
                        Text(String(localized: "Web apps require iOS 18.4 or later. You can still use the Slowth extension in Safari.", table: "WebApps"))
                            .padding()
                    }
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
                .accessibilityIdentifier("webapps.launcher")
            }
        }
    }

    private var helpCards: some View {
        let compact = verticalSizeClass == .compact
        let layout = dynamicTypeSize.isAccessibilitySize && !compact
            ? AnyLayout(VStackLayout(spacing: 10))
            : AnyLayout(HStackLayout(alignment: .top, spacing: 10))
        return layout {
            WebAppsHelpCards(compact: compact, showHelp: showHelp)
        }
    }

    @ViewBuilder
    @available(iOS 18.4, *)
    private func tile(_ service: WebAppService) -> some View {
        let isHidden = hidden.contains(service.id)
        let label = WebAppIconLabel(service: service, editing: editMode.isEditing, hidden: isHidden)
        if editMode.isEditing {
            Button { showSettings(service) } label: { label }
            .buttonStyle(.plain)
            .accessibilityLabel(service.title)
            .accessibilityHint(String(localized: "Blocking settings", table: "WebApps"))
            .accessibilityIdentifier("webapps.settings." + service.id)
            .contextMenu { actions(for: service) }
            .overlay(alignment: .top) {
                Button { toggleVisibility(service) } label: {
                    Image(systemName: isHidden ? "plus.circle.fill" : "minus.circle.fill")
                        .font(.system(size: 21, weight: .bold))
                        .symbolRenderingMode(.palette)
                        .foregroundStyle(.white, isHidden ? SlowthAppearance.sage : Color.secondary)
                        .frame(width: 44, height: 44)
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .accessibilityLabel(visibilityTitle(isHidden) + ", " + service.title)
                .accessibilityIdentifier((isHidden ? "webapps.restore." : "webapps.hide.") + service.id)
                .offset(x: -27, y: -17)
            }
        } else {
            Button { WebAppsRouter.shared.open(service) } label: { label }
                .buttonStyle(.plain)
                .accessibilityIdentifier("webapps.open." + service.id)
                .contextMenu { actions(for: service) }
        }
    }

    @ViewBuilder
    private func actions(for service: WebAppService) -> some View {
        Button { showSettings(service) } label: {
            Label(String(localized: "Blocking settings", table: "WebApps"), systemImage: "slider.horizontal.3")
        }
        Button { openURL(service.shortcutURL) } label: {
            Label(String(localized: "Add to Home Screen", table: "WebApps"), systemImage: "square.and.arrow.up")
        }
        let isHidden = hidden.contains(service.id)
        Button { toggleVisibility(service) } label: {
            Label(visibilityTitle(isHidden), systemImage: isHidden ? "eye" : "eye.slash")
        }
    }

    private func visibilityTitle(_ isHidden: Bool) -> String {
        isHidden ? String(localized: "Show in Web apps", table: "WebApps") : String(localized: "Hide from Web apps", table: "WebApps")
    }

    private func toggleVisibility(_ service: WebAppService) {
        var ids = hidden
        if ids.remove(service.id) == nil { ids.insert(service.id) }
        hiddenServices = ids.sorted().joined(separator: ",")
    }
}

struct WebAppsHelpCards: View {
    let compact: Bool
    let showHelp: (WebAppsHelpTopic) -> Void

    var body: some View {
        IOSFeatureCard(title: String(localized: "Safari extension", table: "WebApps"),
                       subtitle: String(localized: "Enable in Safari"), icon: "safari.fill",
                       gradient: [.blue, .indigo], action: { showHelp(.safariExtension) }, compact: compact, flexible: true)
            .accessibilityIdentifier("webapps.help.safari")
        if #available(iOS 18.4, *) {
            IOSFeatureCard(title: AppLocalization.string("How it works"),
                           subtitle: String(localized: "Blocking settings", table: "WebApps"), icon: "sparkles",
                           gradient: [.indigo, .purple], action: { showHelp(.webApps) }, compact: compact, flexible: true)
                .accessibilityIdentifier("webapps.help.guide")
        }
    }
}

@available(iOS 18.4, *)
private struct WebAppIconLabel: View {
    let service: WebAppService
    let editing: Bool
    let hidden: Bool
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        VStack(spacing: 7) {
            let icon = Image(service.icon)
                .resizable()
                .scaledToFill()
                .frame(width: 62, height: 62)
                .clipShape(RoundedRectangle(cornerRadius: 14, style: .continuous))
                .accessibilityHidden(true)
            if editing && !reduceMotion {
                let angle = (WebAppService.allCases.firstIndex(of: service) ?? 0).isMultiple(of: 2) ? 2.0 : -2.0
                icon.phaseAnimator([false, true]) { view, phase in
                    view.rotationEffect(.degrees(phase ? angle : -angle))
                } animation: { _ in .easeInOut(duration: 0.13) }
            } else {
                icon
            }
            Text(verbatim: service.title)
                .font(.footnote)
                .multilineTextAlignment(.center)
        }
        .foregroundStyle(.primary)
        .opacity(hidden ? 0.5 : 1)
        .frame(maxWidth: .infinity)
        .contentShape(Rectangle())
    }
}

/// Own the presentation above both native and compact iOS layouts.
struct WebAppsPresentation: ViewModifier {
    @ObservedObject private var router = WebAppsRouter.shared
    @State private var presentedService: WebAppService?
    @State private var unsupportedWebsite = false
    func body(content: Content) -> some View {
        content
            .onOpenURL { url in
                if ["https", "http"].contains(url.scheme ?? "") {
                    unsupportedWebsite = !router.openWebsite(url)
                    return
                }
                guard let service = WebAppService(shortcut: url) else { return }
                router.open(service)
            }
            .alert(String(localized: "Website not in the catalog", table: "WebApps"), isPresented: $unsupportedWebsite) {
                Button(String(localized: "OK"), role: .cancel) {}
            } message: {
                let sites = WebAppService.allCases.map(\.title).formatted(.list(type: .and))
                Text(String(format: String(localized: "Slowth opens %@. Open this link in your regular browser.", table: "WebApps"), sites))
            }
            .fullScreenCover(item: $router.service, onDismiss: {
                if #available(iOS 18.4, *), let service = presentedService {
                    WebAppProfileRuntime.shared(service.profile).session(service).stop()
                }
                presentedService = nil
                router.didDismiss()
            }) { service in
                if #available(iOS 18.4, *) {
                    WebAppBrowserScreen(service: service).id(service)
                        .onAppear { presentedService = service }
                } else {
                    UnsupportedWebAppScreen()
                }
            }
    }
}

private struct UnsupportedWebAppScreen: View {
    @Environment(\.dismiss) private var dismiss
    var body: some View {
        VStack(spacing: 24) {
            Text(String(localized: "Web apps require iOS 18.4 or later. You can still use the Slowth extension in Safari.", table: "WebApps"))
            Button(String(localized: "Close")) { dismiss() }
        }.padding(32)
    }
}

@available(iOS 18.4, *)
struct WebAppDataSettingsSection: View {
    @AppStorage("webapps.profile-migration-v2-acknowledged") private var migrationAcknowledged = false
    @State private var confirmClear = false
    @State private var clearing = false
    @State private var clearError = false

    var body: some View {
        Section {
            if !migrationAcknowledged {
                Text(String(localized: "Web apps now use separate profiles. Please sign in again once. Instagram and Facebook share Meta; your old sign-ins have not been deleted.", table: "WebApps"))
                Button(String(localized: "Got it", table: "WebApps")) { migrationAcknowledged = true }
            }
            Button(role: .destructive) { confirmClear = true } label: {
                HStack {
                    Label(String(localized: "Clear all website data", table: "WebApps"), systemImage: "trash")
                    Spacer()
                    if clearing { ProgressView() }
                }
            }
            .disabled(clearing)
        } header: {
            Text(String(localized: "Web apps", table: "WebApps"))
        }
        .confirmationDialog(String(localized: "Clear all website data?", table: "WebApps"), isPresented: $confirmClear, titleVisibility: .visible) {
            Button(String(localized: "Clear all website data", table: "WebApps"), role: .destructive) {
                clearing = true
                Task { @MainActor in
                    do { try await WebAppProfileRuntime.clearAllData() }
                    catch { clearError = true }
                    clearing = false
                }
            }
            Button(String(localized: "Cancel"), role: .cancel) {}
        } message: {
            Text(String(localized: "This signs you out of all websites in Slowth and deletes their cookies, cache and temporary downloads. Blocking settings, Safari data and files saved to Files stay unchanged.", table: "WebApps"))
        }
        .alert(String(localized: "Could not clear all website data. Please try again.", table: "WebApps"), isPresented: $clearError) {
            Button(String(localized: "OK"), role: .cancel) {}
        }
    }
}
