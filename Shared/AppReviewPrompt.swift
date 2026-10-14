import SwiftUI
import StoreKit
#if DEBUG && os(iOS)
import UIKit
#endif

@MainActor
private struct AppReviewPrompt: ViewModifier {
    @Environment(\.scenePhase) private var scenePhase
    @Environment(\.requestReview) private var requestReview
    let hasEnabledBlocking: Bool
    let isReady: Bool

    private struct Context: Equatable {
        let active: Bool
        let hasEnabledBlocking: Bool
        let isReady: Bool
    }

    private var supportsAutomaticRequest: Bool {
        #if DEBUG || targetEnvironment(simulator)
        return false
        #else
        let receipt = Bundle.main.appStoreReceiptURL
        guard receipt?.lastPathComponent != "sandboxReceipt" else { return false }
        #if os(macOS)
        // Direct-download Mac builds don't have an App Store receipt.
        return receipt.map { FileManager.default.fileExists(atPath: $0.path) } ?? false
        #else
        return true
        #endif
        #endif
    }

    func body(content: Content) -> some View {
        let context = Context(active: scenePhase == .active,
                              hasEnabledBlocking: hasEnabledBlocking, isReady: isReady)
        content.task(id: context) { @MainActor in
            guard supportsAutomaticRequest, context.active else { return }
            let coordinator = AppReviewCoordinator.shared
            coordinator.recordOpening()
            guard context.isReady, context.hasEnabledBlocking else { return }
            // Allow pending sheets and permission prompts to appear first.
            // SwiftUI cancels this task on backgrounding, a sheet, or a UI switch.
            do { try await Task.sleep(nanoseconds: 3_000_000_000) }
            catch { return }
            guard !Task.isCancelled,
                  coordinator.claimRequest(hasEnabledBlocking: context.hasEnabledBlocking,
                                           isReady: context.active && context.isReady) else { return }
            requestReview()
        }
    }
}

extension View {
    @MainActor
    func appReviewPrompt(hasEnabledBlocking: Bool, isReady: Bool) -> some View {
        modifier(AppReviewPrompt(hasEnabledBlocking: hasEnabledBlocking, isReady: isReady))
    }
}

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
#endif
