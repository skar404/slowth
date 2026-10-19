#if DEBUG && os(iOS)
import SwiftUI
import UIKit

/// Attach to the host root so capture refresh is independent of the visible tab.
struct DebugCaptureLifecycle: ViewModifier {
    @ObservedObject var state: AppState
    @ObservedObject var debugCaptureLibrary: DebugCapturePhotoLibrary
    @Binding var debugCaptureEnabled: Bool
    let debugModeEnabled: Bool

    func body(content: Content) -> some View {
        content
        .onAppear {
            if !debugModeEnabled {
                debugCaptureEnabled = false
            }
            debugCaptureLibrary.refresh(importIfPossible: debugCaptureEnabled)
        }
        .onReceive(NotificationCenter.default.publisher(for: UIApplication.didBecomeActiveNotification)) { _ in
            debugCaptureLibrary.refresh(importIfPossible: debugCaptureEnabled)
        }
        .onChange(of: debugModeEnabled) { enabled in
            if !enabled {
                debugCaptureEnabled = false
            }
        }
        .onChange(of: debugCaptureLibrary.lastError) { error in
            guard debugModeEnabled, debugCaptureEnabled, let error else { return }
            state.lastError = error
        }
        .onChange(of: debugCaptureEnabled) { enabled in
            guard enabled else { return }
            debugCaptureLibrary.requestAccessAndImport()
        }
    }
}
#endif
