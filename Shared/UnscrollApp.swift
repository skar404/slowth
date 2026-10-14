import SwiftUI

@main
struct UnscrollApp: App {
    #if os(macOS)
    @AppStorage(AppLocalization.languageKey) private var appLanguage = ""
    #endif
    #if os(iOS)
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
            if uiMode == "mac" {
                MacContentView()
            } else {
                ContentView()
            }
    }
    #endif
}
