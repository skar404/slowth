import SwiftUI

@main
struct UnscrollApp: App {
    init() {
        #if DEBUG && os(iOS)
        // Restore a diagnostic-only shield override before normal reconciliation.
        try? ManagedSettingsDiagnostics.restoreProbe()
        #endif
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
    @State private var transferLink: DebugTransferLink?
    @State private var invalidTransferLink = false
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
            if ProcessInfo.processInfo.arguments.contains("--preview-debug-tools") {
                DebugToolsPreview()
            } else if #available(iOS 16.2, *), ProcessInfo.processInfo.arguments.contains("--preview-live-activity") {
                PauseActivityPreviewScreen()
            } else if #available(iOS 18.4, *), let service = webAppPreviewService {
                WebAppBrowserScreen(service: service)
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
    #if DEBUG && targetEnvironment(simulator)
    private var webAppPreviewService: WebAppService? {
        let arguments = ProcessInfo.processInfo.arguments
        guard let index = arguments.firstIndex(of: "--preview-web-app-service"), arguments.indices.contains(index + 1) else { return nil }
        return WebAppService(rawValue: arguments[index + 1])
    }
    #endif
    @ViewBuilder private var iOSContent: some View {
        Group {
            #if DEBUG
            if ProcessInfo.processInfo.arguments.contains("--debug-transfers") {
                DebugTransfersView()
            } else if #available(iOS 16.2, *), ProcessInfo.processInfo.arguments.contains("--motion-experiment") {
                MotionExperimentView()
            } else if ProcessInfo.processInfo.arguments.contains("--diagnose-managed-settings") {
                ManagedSettingsDiagnosticsView()
            } else {
                normalIOSContent
            }
            #else
            normalIOSContent
            #endif
        }
        #if DEBUG
        .onOpenURL { url in
            guard url.scheme == "slowth", url.host == "debug-transfer" else { return }
            do { transferLink = try DebugTransferLink.parse(url) }
            catch { invalidTransferLink = true }
        }
        .sheet(item: $transferLink) { DebugTransferConnectionView(link: $0) }
        .alert("Invalid transfer link", isPresented: $invalidTransferLink) {
            Button("OK", role: .cancel) {}
        } message: { Text("No connection settings were changed.") }
        .onReceive(NotificationCenter.default.publisher(for: UIApplication.didEnterBackgroundNotification)) { _ in
            DebugTransferStore.shared.pause()
            transferLink = nil
        }
        #endif
    }

    @ViewBuilder private var normalIOSContent: some View {
        Group {
            if uiMode == "mac" {
                MacContentView()
            } else {
                ContentView()
            }
        }
        .modifier(WebAppsPresentation())
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
