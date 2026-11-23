import SwiftUI

/// Shared by the compact tab and the wide Web apps column.
struct WebAppsIntroSections: View {
    @AppStorage("webapps.profile-migration-v2-acknowledged") private var migrationAcknowledged = false

    var body: some View {
        Section {
            VStack(alignment: .leading, spacing: 12) {
                Text("Beta").font(.caption.bold()).padding(.horizontal, 10).padding(.vertical, 4)
                    .background(SlowthAppearance.sage.opacity(0.15), in: Capsule())
                Text(String(localized: "Your sites, with room to breathe", table: "WebApps"))
                    .font(.title2.bold())
                Text(String(localized: "Open websites inside Slowth with your existing blocking settings. Add a shortcut to keep them where your thumb remembers.", table: "WebApps"))
                    .foregroundStyle(.secondary)
            }.padding(.vertical, 8)
        } footer: {
            Text(String(localized: "Sign in once inside Slowth. Safari sign-ins are separate. Shortcuts open Slowth; deleting a shortcut leaves your account and settings intact.", table: "WebApps"))
        }
        if #available(iOS 18.4, *) {
            if !migrationAcknowledged {
                Section {
                    Text(String(localized: "Web apps now use separate profiles. Please sign in again once. Instagram and Facebook share Meta; your old sign-ins have not been deleted.", table: "WebApps"))
                    Button(String(localized: "Got it", table: "WebApps")) { migrationAcknowledged = true }
                }
            }
        } else {
            Section {
                Text(String(localized: "Web apps require iOS 18.4 or later. You can still use the Slowth extension in Safari.", table: "WebApps"))
            }
        }
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

@available(iOS 18.4, *)
struct WebAppDataSettingsSection: View {
    @State private var confirmClear = false
    @State private var clearing = false
    @State private var clearError = false

    var body: some View {
        Section {
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
