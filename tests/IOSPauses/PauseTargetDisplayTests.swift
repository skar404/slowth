import Foundation

@main
struct PauseTargetDisplayTests {
    static func main() {
        let expected = ["youtube": "YouTube", "instagram": "Instagram", "facebook": "Facebook",
                        "x": "X", "tiktok": "TikTok", "snapchat": "Snapchat"]
        for (target, name) in expected {
            precondition(PauseTargetDisplay.name(for: target) == name)
        }
        for unknown in ["", "future-service", "YouTube", "未知"] {
            precondition(PauseTargetDisplay.name(for: unknown) == unknown)
        }
        print("PASS: pause target names and unknown targets preserved")
    }
}
