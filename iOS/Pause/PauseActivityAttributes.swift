#if os(iOS)
import ActivityKit
import Foundation

@available(iOS 16.2, *)
struct PauseActivityAttributes: ActivityAttributes {
    struct ContentState: Codable, Hashable {
        var phase: String
        var startedAt: Date
        var expiresAt: Date
        var service: String? = nil
        var target: String? = nil
        var switchTargets: [String]? = nil
        var choosingApp: Bool? = nil
    }
    var pauseID: String
    var service: String
    var safari: Bool
}
#endif
