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
            if ProcessInfo.processInfo.arguments.contains("--web-app-tests") {
                // Hosted WebKit tests need a key window, not onboarding, Screen Time
                // authorization, model setup or the live recording-state poller.
                Color.clear
            } else if ProcessInfo.processInfo.arguments.contains("--preview-debug-tools") {
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
            if ProcessInfo.processInfo.arguments.contains("--diagnose-managed-settings") {
                ManagedSettingsDiagnosticsView()
            } else {
                normalIOSContent
            }
            #else
            normalIOSContent
            #endif
        }
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
