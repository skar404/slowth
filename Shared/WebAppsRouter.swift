import Foundation
import Combine

@MainActor
final class WebAppsRouter: ObservableObject {
    static let shared = WebAppsRouter()
    @Published var service: WebAppService?
    @Published private(set) var pending: WebAppService?
    @Published private(set) var websiteURL: URL?
    private var presentationReady = true
    private var shortcutInstructionsPresented = false
    @Published private(set) var isDismissing = false

    func open(_ next: WebAppService) {
        if isDismissing || !presentationReady || shortcutInstructionsPresented { pending = next; return }
        guard service != next else { return }
        if service != nil {
            // Finish dismissing the old cover before presenting the retained session.
            pending = next
            isDismissing = true
            service = nil
        } else { service = next }
    }
    func openWebsite(_ url: URL) -> Bool {
        guard ["http", "https"].contains(url.scheme ?? ""), url.user == nil, url.password == nil,
              url.port == nil,
              let service = WebAppService.containing(url) else { return false }
        websiteURL = url
        open(service)
        return true
    }
    func takeWebsiteURL(for service: WebAppService) -> URL? {
        guard let url = websiteURL, WebAppService.containing(url) == service else { return nil }
        websiteURL = nil
        return url
    }
    func didDismiss() {
        isDismissing = false
        presentPending()
    }
    func dismissForNativePrompt() {
        // An explicit Shield handoff supersedes a queued website. Keep the
        // presentation occupied until the cover's onDismiss has actually run.
        pending = nil
        websiteURL = nil
        if service != nil {
            isDismissing = true
            service = nil
        }
    }
    func setPresentationReady(_ ready: Bool) {
        presentationReady = ready
        if ready { presentPending() }
    }
    func setShortcutInstructionsPresented(_ presented: Bool) {
        shortcutInstructionsPresented = presented
        if !presented { presentPending() }
    }
    private func presentPending() {
        guard presentationReady, !shortcutInstructionsPresented, !isDismissing, service == nil, let next = pending else { return }
        pending = nil
        service = next
    }
}
