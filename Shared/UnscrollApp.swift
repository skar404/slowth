import SwiftUI

@main
struct UnscrollApp: App {
    #if os(macOS)
    @AppStorage(AppLocalization.languageKey) private var appLanguage = ""
    #endif
    #if os(iOS)
    @UIApplicationDelegateAdaptor(ShieldNotificationAppDelegate.self) private var notificationDelegate
    @AppStorage("uiMode") private var uiMode: String = "ios"
    #endif

    #if os(iOS) && DEBUG
    @State private var labelerLink: LabelerLink?
    private struct LabelerLink: Identifiable {
        let id = UUID()
        let server: String
        let token: String?
    }
    #endif

    var body: some Scene {
        WindowGroup {
            #if os(macOS)
            MacContentView()
                .id(appLanguage)
                .environment(\.locale, AppLocalization.locale)
                .environment(\.layoutDirection, AppLocalization.isRightToLeft ? .rightToLeft : .leftToRight)
                .frame(minWidth: 340, idealWidth: 360, maxWidth: 420,
                       minHeight: 520, idealHeight: 600)
            #else
            #if DEBUG && targetEnvironment(simulator)
            if #available(iOS 16.2, *), ProcessInfo.processInfo.arguments.contains("--preview-live-activity") {
                PauseActivityPreviewScreen()
            } else {
                iOSContent
            }
            #else
            iOSContent
            #endif
            #endif
        }
        #if os(macOS)
        .windowResizability(.contentSize)
        #endif
    }

    #if os(iOS)
    @ViewBuilder private var iOSContent: some View {
        Group {
            if uiMode == "mac" {
                MacContentView()
            } else {
                ContentView()
            }
        }
        #if DEBUG
        .onOpenURL { url in
            guard url.scheme == "slowth", url.host == "labeler", url.path.isEmpty,
                  url.user == nil, url.password == nil, url.port == nil,
                  let items = URLComponents(url: url, resolvingAgainstBaseURL: false)?.queryItems,
                  items.count == 1, items[0].name == "server", let value = items[0].value,
                  let server = try? SessionUploadServer.url(from: value),
                  !SessionUploadConnection.shared.isUploading else { return }
            let token: String?
            if let fragment = url.fragment {
                guard fragment.hasPrefix("token=") else { return }
                let value = String(fragment.dropFirst(6))
                guard value.range(of: "^[A-Za-z0-9_-]{43,128}$", options: .regularExpression) != nil else { return }
                token = value
            } else { token = nil }
            labelerLink = LabelerLink(server: server.absoluteString, token: token)
        }
        .sheet(item: $labelerLink) { link in
            SessionUploadConnectionView(initialServerAddress: link.server, initialCredential: link.token)
        }
        #endif
    }
    #endif
}
