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
    @State private var status = AppReviewCoordinator.shared.debugStatus()
    @State private var result: String?
    let hasEnabledBlocking: Bool
    let isReady: Bool

    var body: some View {
        Group {
            Text("App Store review")
                .font(.headline)
            row("Operating system", value: ProcessInfo.processInfo.operatingSystemVersionString)
            row("Receipt", value: Bundle.main.appStoreReceiptURL?.lastPathComponent ?? "None")
            row("Request API", value: requestAPI)
            row("Presentation window", value: systemReviewRequest == nil ? "No unique active key window" : "Available")
            row("First tracked opening", value: dateText(status.firstOpenedAt))
            row("Seven-day threshold", value: dateText(status.eligibleAfter))
            row("Opening dates", value: "\(status.activeDays) / 3")
            row("Request attempted", value: status.attempted ? "Yes" : "No")
            row("Blocking enabled", value: hasEnabledBlocking ? "Yes" : "No")
            row("Screen ready", value: isReady && scenePhase == .active ? "Yes" : "No")

            Button("Show system review prompt now") {
                guard let invoke = systemReviewRequest else {
                    result = "No StoreKit call: no unique foreground-active key window. Return to the app and retry. The attempt flag was not changed."
                    return
                }
                result = "\(requestAPI) called. Opening history, blocking settings and attempt flag were not changed. Apple does not report whether the prompt appeared."
                invoke()
            }
            .disabled(!isReady || scenePhase != .active)
            Button("Prepare review test (7 days / 3 dates)") {
                AppReviewCoordinator.shared.prepareEligibleHistoryForDebug()
                refresh()
                result = "Review history prepared; the attempt flag is cleared. Blocking settings still apply."
            }
            Button("Test one-time review request") {
                guard let invoke = systemReviewRequest else {
                    result = "No StoreKit call: no unique foreground-active key window. The attempt flag was not changed."
                    return
                }
                let coordinator = AppReviewCoordinator.shared
                let now = Date()
                let ready = isReady && scenePhase == .active
                let claimed = coordinator.claimRequest(at: now,
                    hasEnabledBlocking: hasEnabledBlocking, isReady: ready)
                refresh()
                if claimed {
                    result = "\(requestAPI) called; attempt saved. Apple does not report whether the prompt appeared."
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
                refresh()
                result = "Review dates and attempt flag cleared."
            }
            if let result {
                Text(verbatim: result)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .textSelection(.enabled)
            }
            Text("Show system review prompt now calls StoreKit without changing the attempt flag. To test the one-time rules, prepare history, test once, then test again to confirm no second request. Reset clears only local review preferences. Automatic requests stay off in Debug; TestFlight does not show the system prompt.")
                .font(.caption)
                .foregroundStyle(.secondary)
            Text("If the request is called but no window appears on beta iOS, repeat the test on a stable OS. Beta builds have been reported to suppress review prompts. A saved attempt confirms the API call, not presentation.")
                .font(.caption)
                .foregroundStyle(.secondary)
        }
        .onAppear(perform: refresh)
        .onChange(of: scenePhase) { _ in refresh() }
    }

    private func refresh() {
        status = AppReviewCoordinator.shared.debugStatus()
    }

    private var requestAPI: String {
        #if os(iOS)
        return "AppStore.requestReview(in:)"
        #else
        return "SwiftUI requestReview"
        #endif
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

    private func dateText(_ date: Date?) -> String {
        date?.formatted(date: .abbreviated, time: .shortened) ?? "Not tracked"
    }

    private func row(_ title: String, value: String) -> some View {
        HStack {
            Text(verbatim: title).foregroundStyle(.secondary)
            Spacer()
            Text(verbatim: value).multilineTextAlignment(.trailing)
        }
        .font(.caption)
    }
}
#endif
