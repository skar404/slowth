import SwiftUI

@main
struct UnscrollApp: App {
    init() {
        #if os(iOS)
        // SwiftUI constructs App before UIApplicationMain. Reject early access
        // until the delegate installs the real UIKit application at launch.
        IOSPauseDatabase.beginHostAccess = { throw IOSPauseError.storage }
        #endif
    }
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

#if os(iOS)
/// Host-only: this file is not part of the app extensions. UIKit's begin/end
/// background task APIs are thread safe; no main-queue sync while SQLite waits.
final class PauseDatabaseBackgroundTask: @unchecked Sendable {
    private let application: UIApplication
    private let lock = NSLock()
    private var identifier: UIBackgroundTaskIdentifier = .invalid
    private var ended = false

    private init(application: UIApplication) { self.application = application }

    static func begin(application: UIApplication) throws -> IOSPauseDatabaseAccess {
        let task = PauseDatabaseBackgroundTask(application: application)
        let access = IOSPauseDatabaseAccess()
        access.onFinish = { task.end() }
        let identifier = application.beginBackgroundTask(withName: "Pause database") {
            // Interrupt SQL, prevent commit, and wait for rollback/close before
            // releasing the assertion. Database edits must not wait on main.
            access.cancelAndWait()
            task.end()
        }
        task.install(identifier)
        guard identifier != .invalid else {
            access.finish()
            throw IOSPauseError.storage
        }
        return access
    }

    private func install(_ identifier: UIBackgroundTaskIdentifier) {
        lock.lock()
        let alreadyEnded = ended
        if !alreadyEnded { self.identifier = identifier }
        lock.unlock()
        if alreadyEnded && identifier != .invalid { application.endBackgroundTask(identifier) }
    }

    private func end() {
        lock.lock()
        let identifier = self.identifier
        self.identifier = .invalid
        ended = true
        lock.unlock()
        if identifier != .invalid { application.endBackgroundTask(identifier) }
    }
}
#endif
