import Foundation

enum AppGroup {
    static let identifier: String = {
        let prefix = (Bundle.main.object(forInfoDictionaryKey: "BundleIdPrefix") as? String)
            ?? "com.unscroll.local"
        return "group.\(prefix).shared"
    }()

    static var defaults: UserDefaults {
        UserDefaults(suiteName: identifier) ?? .standard
    }
}
