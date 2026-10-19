import Foundation

/// Product names are shared; sentence localization stays with each consumer.
enum PauseTargetDisplay {
    static func name(for target: String) -> String {
        switch target {
        case "youtube": return "YouTube"
        case "instagram": return "Instagram"
        case "facebook": return "Facebook"
        case "x": return "X"
        case "tiktok": return "TikTok"
        case "snapchat": return "Snapchat"
        default: return target
        }
    }
}
