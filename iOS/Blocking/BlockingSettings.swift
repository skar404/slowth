import Foundation

/// iOS-only delegation from shared settings. The macOS implementation and all
/// persisted keys stay unchanged.
enum BlockingSettings {
    static func setSoftYouTubeBlockingEnabled(_ enabled: Bool,
                                              allowInitialStrictActivation: Bool) throws -> SharedState {
        let state = SharedStore.snapshot()
        if let rejection = BlockingRules.softModeRejection(enabling: enabled,
            strict: state.isStrictModeActive, initialActivation: allowInitialStrictActivation,
            youtubeEnabled: state.realtimeYouTubeBlockingEnabled) {
            switch rejection {
            case .strict: throw SharedStoreError.strictModeActive
            case .youtubeDisabled: throw SharedStoreError.invalidValue
            }
        }
        let defaults = AppGroup.defaults
        defaults.set(enabled, forKey: SharedStoreKey.softYouTubeBlockingEnabled)
        if !enabled {
            defaults.set(false, forKey: SharedStoreKey.youtubeShieldRestoreDeferred)
            defaults.removeObject(forKey: SharedStoreKey.softYouTubeMonitorGeneration)
        }
        return SharedStore.snapshot()
    }
}
