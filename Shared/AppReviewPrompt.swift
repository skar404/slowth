import SwiftUI
import StoreKit

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
