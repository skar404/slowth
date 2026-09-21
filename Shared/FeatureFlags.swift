import Foundation

enum DebugMode {
    static let storageKey = "debugModeEnabled"
    static let requiredVersionTapCount = 15

    static var isEnabled: Bool {
        resolve(stored: AppGroup.defaults.bool(forKey: storageKey))
    }

    static func resolve(stored: Bool) -> Bool {
        #if DEBUG
        return stored
        #else
        return false
        #endif
    }
}

enum FeatureFlags {
    static let tipsOverrideStorageKey = "featureFlags.tipsEnabled"

    // Keep tips hidden until the related in-app purchases are approved.
    private static let tipsEnabledInProduction = false

    // Overrides are available only while the hidden debug mode is active.
    static var tipsEnabled: Bool {
        tipsEnabledInProduction || (
            DebugMode.isEnabled && AppGroup.defaults.bool(forKey: tipsOverrideStorageKey)
        )
    }
}
