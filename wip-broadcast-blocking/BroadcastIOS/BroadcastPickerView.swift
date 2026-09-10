#if os(iOS)
import SwiftUI
import ReplayKit

// Host-app-side SwiftUI wrapper for the system broadcast picker button.
// Lives under BroadcastIOS/ alongside the extension it targets, but this
// file itself compiles into the UnscrollIOS host app target, not the
// extension.
struct BroadcastPickerView: UIViewRepresentable {
    let preferredExtensionBundleID: String

    func makeUIView(context: Context) -> RPSystemBroadcastPickerView {
        // Must be created with a concrete, non-zero frame: this view is a
        // UIButton subclass whose own hit-test bounds come from the frame
        // passed to its initializer, not from SwiftUI's `.frame()` modifier
        // (that only sizes the outer layout box). Leaving `.zero` here makes
        // the button visible in the right place but completely untappable.
        let view = RPSystemBroadcastPickerView(frame: CGRect(x: 0, y: 0, width: 44, height: 44))
        view.preferredExtension = preferredExtensionBundleID
        view.showsMicrophoneButton = false
        return view
    }

    func updateUIView(_ uiView: RPSystemBroadcastPickerView, context: Context) {
        uiView.preferredExtension = preferredExtensionBundleID
    }
}
#endif
