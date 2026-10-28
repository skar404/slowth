import Foundation

// Replace only the OS delivery boundary; compile the production sender and payload handling.
enum ShieldLocalization { static func bundle(in bundle: Bundle) -> Bundle { bundle } }
final class UNMutableNotificationContent {
    var title = ""
    var body = ""
    var userInfo: [AnyHashable: Any] = [:]
    var sound: String?
    var badge: Int?
}
struct UNNotificationRequest {
    let identifier: String
    let content: UNMutableNotificationContent
    let trigger: String?
}
final class UNUserNotificationCenter {
    static let shared = UNUserNotificationCenter()
    static func current() -> UNUserNotificationCenter { shared }
    var delivered: [String: UNNotificationRequest] = [:]
    var failure: Error?
    func add(_ request: UNNotificationRequest, withCompletionHandler completion: (Error?) -> Void) {
        if failure == nil { delivered[request.identifier] = request }
        completion(failure)
    }
}

@main struct ShieldNotificationTests {
    static func main() {
        for known in [false, true] {
            for unavailable in [false, true] {
                for pauseOnly in [false, true] {
                    for recording in [false, true] {
                        for rest in [false, true] {
                            let expected: ShieldNotification.Message = !known || unavailable ? .other :
                                rest ? .rest : pauseOnly ? .pause : !recording ? .recording : .other
                            assert(ShieldNotification.message(known: known, unavailable: unavailable,
                                pauseOnly: pauseOnly, recording: recording, hasRest: rest) == expected)
                        }
                    }
                }
            }
        }
        var completions = 0
        for target in ["youtube", "tiktok", "instagram"] {
            ShieldNotification.send(target: target, message: .rest) { error in
                assert(error == nil)
                completions += 1
            }
        }
        let center = UNUserNotificationCenter.shared
        assert(completions == 3 && center.delivered.count == 1)
        let request = center.delivered[ShieldNotification.restIdentifier]!
        assert(request.content.title == ShieldNotification.Message.rest.title && request.content.body == ShieldNotification.Message.rest.rawValue)
        assert(request.content.userInfo["target"] as? String == "instagram")
        assert(request.trigger == nil && request.content.sound == nil && request.content.badge == nil)
        assert(request.content.userInfo.count == 1) // No saved rest/deadline or unlock action.

        for _ in 0..<3 {
            ShieldNotification.send(target: "youtube", message: .recording) { assert($0 == nil) }
        }
        assert(center.delivered.count == 2)
        assert(center.delivered[ShieldNotification.identifier]!.content.title == ShieldNotification.Message.recording.title)
        assert(center.delivered[ShieldNotification.restIdentifier]!.content.userInfo["target"] as? String == "instagram")

        for code in [1, 2] { // Permission denied and scheduling failure both finish the callback.
            center.failure = NSError(domain: "notification", code: code)
            ShieldNotification.send(target: nil, message: .other) { error in
                assert(error != nil)
                completions += 1
            }
        }
        assert(completions == 5 && center.delivered.count == 2)
        var targets: [String?] = []
        func open(_ id: String = ShieldNotification.identifier, _ action: Bool = true,
                  _ info: [AnyHashable: Any]) -> Bool {
            ShieldNotification.open(identifier: id, defaultAction: action, userInfo: info,
                isKnown: { ["youtube", "tiktok", "instagram"].contains($0) }, request: { targets.append($0) })
        }
        assert(!open("other", true, [:]))
        assert(!open(ShieldNotification.identifier, false, [:]))
        assert(targets.isEmpty)
        assert(open(ShieldNotification.restIdentifier, true, request.content.userInfo))
        assert(targets.last! == "instagram")
        assert(open(ShieldNotification.identifier, true, ["target": "removed-app"]))
        assert(targets.last! == nil)
        assert(open(ShieldNotification.identifier, true, ["target": 42]))
        assert(targets.last! == nil)
        assert(ShieldNotification.payload(target: nil).isEmpty)
        print("Shield notification tests passed: text matrix, payload, replacement, errors, tap filtering")
    }
}
