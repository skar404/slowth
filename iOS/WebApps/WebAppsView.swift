import SwiftUI

struct WebAppsView: View {
    @ObservedObject private var router = WebAppsRouter.shared
    @AppStorage("webapps.profile-migration-v2-acknowledged") private var migrationAcknowledged = false
    @State private var shortcut: WebAppService?
    let openSafariSettings: () -> Void

    var body: some View {
        List {
            Section {
                VStack(alignment: .leading, spacing: 12) {
                    Text("Beta").font(.caption.bold()).padding(.horizontal, 10).padding(.vertical, 4)
                        .background(SlowthAppearance.sage.opacity(0.15), in: Capsule())
                    Text(String(localized: "Your sites, with room to breathe", table: "WebApps"))
                        .font(.title2.bold())
                    Text(String(localized: "Open websites inside Slowth with your existing blocking settings. Add a shortcut to keep them where your thumb remembers.", table: "WebApps"))
                        .foregroundStyle(.secondary)
                }.padding(.vertical, 8)
            }
            if !migrationAcknowledged {
                Section {
                    Text(String(localized: "Web apps now use separate profiles. Please sign in again once. Instagram and Facebook share Meta; your old sign-ins have not been deleted.", table: "WebApps"))
                    Button(String(localized: "Got it", table: "WebApps")) { migrationAcknowledged = true }
                }
            }
            if #available(iOS 18.4, *) {
                Section {
                    ForEach(WebAppService.allCases) { service in
                        VStack(alignment: .leading, spacing: 12) {
                            HStack(spacing: 12) {
                                Image(service.icon).resizable().scaledToFit().frame(width: 44, height: 44)
                                    .clipShape(RoundedRectangle(cornerRadius: 10)).accessibilityHidden(true)
                                Text(service.title).font(.headline)
                                Spacer()
                                Button(String(localized: "Open", table: "WebApps")) { router.open(service) }
                                    .buttonStyle(.bordered).accessibilityIdentifier("webapps.open." + service.id)
                            }
                            Button {
                                router.setShortcutInstructionsPresented(true)
                                shortcut = service
                            } label: {
                                Label(String(localized: "Add to Home Screen", table: "WebApps"), systemImage: "plus.app")
                                    .font(.subheadline)
                            }.buttonStyle(.borderless).accessibilityIdentifier("webapps.shortcut." + service.id)
                        }.padding(.vertical, 6)
                    }
                } footer: {
                    Text(String(localized: "Sign in once inside Slowth. Safari sign-ins are separate. Shortcuts open Slowth; deleting a shortcut leaves your account and settings intact.", table: "WebApps"))
                }
            } else {
                Section {
                    Text(String(localized: "Web apps require iOS 18.4 or later. You can still use the Slowth extension in Safari.", table: "WebApps"))
                    Button("Safari", action: openSafariSettings)
                }
            }
            Section {
                Button(action: openSafariSettings) {
                    Label(String(localized: "Blocking settings", table: "WebApps"), systemImage: "slider.horizontal.3")
                }
            }
        }
        .scrollContentBackground(.hidden).background(SlowthAppearance.background)
        .navigationTitle(String(localized: "Web apps", table: "WebApps"))
        .sheet(item: $shortcut, onDismiss: { router.setShortcutInstructionsPresented(false) }) { service in
            ShortcutInstructions(service: service)
        }
        .onChange(of: router.pending) { request in
            // A setup-page link can return while these instructions are still open.
            if request != nil { shortcut = nil }
        }
    }
}

private struct ShortcutInstructions: View {
    let service: WebAppService
    @Environment(\.dismiss) private var dismiss
    @Environment(\.openURL) private var openURL
    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: 24) {
                    Image(service.icon).resizable().scaledToFit().frame(width: 80, height: 80)
                        .clipShape(RoundedRectangle(cornerRadius: 18)).accessibilityHidden(true)
                    Text(service.title).font(.largeTitle.bold())
                    Text(String(localized: "Open the setup page in Safari, tap Share, then Add to Home Screen. Keep Open as Web App enabled if that option appears, then tap Add.", table: "WebApps"))
                    Text(String(localized: "The shortcut opens this website inside Slowth. iOS may ask you to confirm opening Slowth.", table: "WebApps"))
                        .foregroundStyle(.secondary)
                    Button(String(localized: "Open setup page", table: "WebApps")) { openURL(service.shortcutURL) }
                        .buttonStyle(.borderedProminent)
                    Text("slowth.app").font(.footnote).foregroundStyle(.secondary)
                }.padding(24)
            }
            .background(SlowthAppearance.background)
            .toolbar { ToolbarItem(placement: .confirmationAction) { Button(String(localized: "Close")) { dismiss() } } }
        }.tint(SlowthAppearance.sage)
    }
}

/// Own the presentation above both native and compact iOS layouts.
struct WebAppsPresentation: ViewModifier {
    @ObservedObject private var router = WebAppsRouter.shared
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
                Text(String(localized: "Slowth opens Instagram, YouTube, TikTok, Facebook and X. Open this link in your regular browser.", table: "WebApps"))
            }
            .fullScreenCover(item: $router.service, onDismiss: router.didDismiss) { service in
                if #available(iOS 18.4, *) {
                    WebAppBrowserScreen(service: service).id(service)
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
