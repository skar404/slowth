import Foundation

/// Closed catalog: shortcuts can select a service, never supply an arbitrary URL.
enum WebAppService: String, CaseIterable, Identifiable {
    case youtube, instagram, tiktok, facebook, x, threads, reddit, linkedin

    var id: String { rawValue }
    var title: String {
        switch self {
        case .instagram: return "Instagram"
        case .youtube: return "YouTube"
        case .tiktok: return "TikTok"
        case .facebook: return "Facebook"
        case .x: return "X"
        case .threads: return "Threads"
        case .reddit: return "Reddit"
        case .linkedin: return "LinkedIn"
        }
    }
    var url: URL {
        // www.x.com enters the legacy twitter.com migration chain. Start on the
        // canonical host so a fresh embedded session can load X directly.
        URL(string: self == .x ? "https://x.com/" : "https://www.\(rawValue).com/")!
    }
    var shortcutURL: URL { URL(string: "https://slowth.app/shortcuts/\(rawValue)/")! }
    var icon: String { "Service-" + rawValue }

    init?(shortcut: URL) {
        guard let components = URLComponents(url: shortcut, resolvingAgainstBaseURL: false),
              components.scheme == "slowth", components.host == "web",
              components.user == nil, components.password == nil, components.port == nil,
              components.query == nil, components.fragment == nil,
              let service = Self(rawValue: String(components.percentEncodedPath.dropFirst())),
              components.percentEncodedPath == "/" + service.rawValue else { return nil }
        self = service
    }
}
