import SwiftUI
import StoreKit
#if os(iOS)
import UIKit
#endif

#if DEBUG
/// Explicit developer actions use the real one-shot claim and StoreKit request.
/// Automatic requests remain disabled in Debug builds.
@MainActor
struct DebugAppReviewControls: View {
    @Environment(\.scenePhase) private var scenePhase
    @Environment(\.requestReview) private var requestReview
    @State private var result: String?
    let hasEnabledBlocking: Bool
    let isReady: Bool

    var body: some View {
        Group {
            Button("Show review prompt") {
                guard let invoke = systemReviewRequest else {
                    result = "No StoreKit call: no unique foreground-active key window. Return to the app and retry. The attempt flag was not changed."
                    return
                }
                result = nil
                invoke()
            }
            .disabled(!isReady || scenePhase != .active)
            Button("Prepare review test") {
                AppReviewCoordinator.shared.prepareEligibleHistoryForDebug()
                result = "Review history prepared; the attempt flag is cleared. Blocking settings still apply."
            }
            Button("Test one-time review") {
                guard let invoke = systemReviewRequest else {
                    result = "No StoreKit call: no unique foreground-active key window. The attempt flag was not changed."
                    return
                }
                let coordinator = AppReviewCoordinator.shared
                let now = Date()
                let ready = isReady && scenePhase == .active
                let claimed = coordinator.claimRequest(at: now,
                    hasEnabledBlocking: hasEnabledBlocking, isReady: ready)
                if claimed {
                    result = nil
                    invoke()
                } else {
                    let reason = coordinator.requestBlocker(at: now,
                        hasEnabledBlocking: hasEnabledBlocking, isReady: ready)
                    result = "No StoreKit call: " + (reason?.explanation ?? "Eligibility changed; try again.")
                }
            }
            .disabled(!isReady || scenePhase != .active)
            Button("Reset review history") {
                AppReviewCoordinator.shared.resetForDebug()
                result = "Review dates and attempt flag cleared."
            }
        }
        .alert("Review test", isPresented: Binding(
            get: { result != nil },
            set: { if !$0 { result = nil } }
        )) {
            Button("OK", role: .cancel) { result = nil }
        } message: {
            Text(verbatim: result ?? "")
        }
    }

    /// Resolve an explicit presentation scene for the iOS debug test. Refuse an
    /// absent or ambiguous window before consuming the one-time attempt.
    private var systemReviewRequest: (() -> Void)? {
        #if os(iOS)
        let scenes = UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }
            .filter { $0.activationState == .foregroundActive && $0.windows.contains(where: \.isKeyWindow) }
        guard scenes.count == 1, let scene = scenes.first else { return nil }
        return { AppStore.requestReview(in: scene) }
        #else
        return { requestReview() }
        #endif
    }

}

#Preview("Review test controls") {
    Form { DebugAppReviewControls(hasEnabledBlocking: true, isReady: true) }
        .allowsHitTesting(false)
}

#endif
