import Foundation
#if canImport(UserNotifications) && !SHIELD_NOTIFICATION_TESTS
import UserNotifications
#endif

enum ShieldNotification {
    static let identifier = "slowth.shield.open"
    static let restIdentifier = "slowth.shield.rest"
    static let targetKey = "target"

    enum Message: String {
        case recording = "Start screen recording in Slowth to continue"
        case rest = "Open Slowth to see your remaining rest time"
        case pause = "Open Slowth to choose a pause"
        case other = "Open Slowth to choose how to continue"

        var identifier: String { self == .rest ? ShieldNotification.restIdentifier : ShieldNotification.identifier }
        var title: String {
            switch self {
            case .rest: return "Slowth · Rest"
            case .recording: return "Slowth · Screen recording"
            default: return "Slowth"
            }
        }
    }

    static func recognizes(_ identifier: String) -> Bool {
        identifier == self.identifier || identifier == restIdentifier
    }

    static func message(known: Bool, unavailable: Bool, pauseOnly: Bool,
                        recording: Bool, hasRest: Bool) -> Message {
        guard known, !unavailable else { return .other }
        if hasRest { return .rest }
        if pauseOnly { return .pause }
        if !recording { return .recording }
        return .other
    }

    static func payload(target: String?) -> [String: String] {
        target.map { [targetKey: $0] } ?? [:]
    }

    // Only navigation data is carried. Rest/pause state is read afresh by the host.
    static func open(identifier: String, defaultAction: Bool, userInfo: [AnyHashable: Any],
                     isKnown: (String) -> Bool, request: (String?) -> Void) -> Bool {
        guard recognizes(identifier), defaultAction else { return false }
        let target = userInfo[targetKey] as? String
        request(target.flatMap { isKnown($0) ? $0 : nil })
        return true
    }

    #if os(iOS) || SHIELD_NOTIFICATION_TESTS
    static func send(target: String?, message: Message, completion: @escaping (Error?) -> Void) {
        let content = UNMutableNotificationContent()
        let bundle = ShieldLocalization.bundle(in: .main)
        content.title = bundle.localizedString(forKey: message.title, value: message.title, table: "ShieldNotifications")
        content.body = bundle.localizedString(
            forKey: message.rawValue, value: message.rawValue, table: "ShieldNotifications")
        content.userInfo = payload(target: target)
        // Repeats replace their own type; a rest never replaces a recording prompt.
        // No sound, badge, authorization request, or blocking-state mutation here.
        UNUserNotificationCenter.current().add(
            UNNotificationRequest(identifier: message.identifier, content: content, trigger: nil),
            withCompletionHandler: completion)
    }
    #endif
}
