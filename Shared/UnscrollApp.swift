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
            if uiMode == "mac" {
                MacContentView()
            } else {
                ContentView()
            }
            #endif
        }
        #if os(macOS)
        .windowResizability(.contentSize)
        #endif
    }
}
