import Foundation
#if !PAUSE_COORDINATOR_TESTS
import FamilyControls
import DeviceActivity
#endif

/// Host and extension entry points. Durable pause/rest decisions are applied by
/// IOSPauseCoordinator under SQLite locking; soft-monitor races retain their
/// generation and foreground rechecks on both sides of the system write.
enum BlockingCoordinator {
    enum Setting { case recordingProtection, youtube, softYouTube }
    static func settingsChanged(_ setting: Setting, enabled: Bool,
                                facebookSupported: Bool, xSupported: Bool) {
        if enabled {
            hostOpened(facebookSupported: facebookSupported, xSupported: xSupported)
            return
        }
        SoftYouTubeActivityMonitoring.stop()
        switch setting {
        case .recordingProtection:
            for surface in [ManagedSettingsApplier.Surface.youtube, .instagram, .facebook, .x] {
                ManagedSettingsApplier.clear(surface: surface)
            }
        case .youtube:
            ManagedSettingsApplier.clear(surface: .youtube)
        case .softYouTube:
            if !SharedStore.snapshot().broadcastActive {
                enforceAtRest(SharedStore.snapshot(), facebookSupported: facebookSupported, xSupported: xSupported)
            }
        }
    }

    static func softContext(_ state: SharedState) -> BlockingContext {
        let selected = state.youtubeSelectionData.flatMap {
            try? JSONDecoder().decode(FamilyActivitySelection.self, from: $0)
        }
        return BlockingContext(enabled: state.realtimeShieldEnabled && state.realtimeYouTubeBlockingEnabled,
            recording: state.broadcastActive, foreground: SharedStore.isSlowthAppForeground(),
            soft: state.softYouTubeBlockingEnabled, deferred: state.youtubeShieldRestoreDeferred,
            validSelection: selected?.applicationTokens.count == 1)
    }

    static func enforceAtRest(_ state: SharedState, facebookSupported: Bool, xSupported: Bool) {
        enforcePauseOnlyApps()
        guard state.realtimeShieldEnabled, !state.broadcastActive else { return }
        for target in ["youtube", "instagram", "facebook", "x"] {
            let data = IOSPauseCoordinator.selection(target, state: state)
            let selection = data.flatMap { try? JSONDecoder().decode(FamilyActivitySelection.self, from: $0) }
            let supported = (target != "facebook" || facebookSupported) && (target != "x" || xSupported)
            let context = BlockingContext(target: target,
                enabled: IOSPauseCoordinator.enabled(target, state: state) && supported,
                recording: state.broadcastActive, foreground: SharedStore.isSlowthAppForeground(),
                soft: state.softYouTubeBlockingEnabled, deferred: state.youtubeShieldRestoreDeferred,
                validSelection: selection != nil)
            let decision = BlockingRules.decide(context, .hostAtRest)
            ManagedSettingsApplier.apply(surface: ManagedSettingsApplier.Surface(rawValue: target)!,
                selection: decision.shield == .block ? selection : nil)
        }
    }

    static func enforcePauseOnlyApps() {
        let approved = IOSProtectionAuthorization.approved(AuthorizationCenter.shared.authorizationStatus)
        for target in PauseOnlyApps.targets {
            ManagedSettingsApplier.apply(surface: ManagedSettingsApplier.Surface(rawValue: target)!,
                selection: approved ? PauseOnlyApps.selection(target) : nil)
        }
    }

    static func hostOpened(facebookSupported: Bool, xSupported: Bool) {
        enforcePauseOnlyApps()
        SharedStore.syncRealtimeShieldAuthorization(AuthorizationCenter.shared.authorizationStatus)
        if !IOSProtectionAuthorization.approved(AuthorizationCenter.shared.authorizationStatus) {
            SoftYouTubeActivityMonitoring.stop()
            for surface in [ManagedSettingsApplier.Surface.youtube, .instagram, .facebook, .x] {
                ManagedSettingsApplier.clear(surface: surface)
            }
        }
        _ = try? IOSPauseCoordinator.snapshot()
        SharedStore.setSlowthAppForeground(true)
        SoftYouTubeActivityMonitoring.stop()
        let decision = BlockingRules.decide(softContext(SharedStore.snapshot()), .hostOpened)
        if let deferred = decision.deferred { SharedStore.setYouTubeShieldRestoreDeferred(deferred) }
        if decision.shield == .clear { ManagedSettingsApplier.clear(surface: .youtube) }
        enforceAtRest(SharedStore.snapshot(), facebookSupported: facebookSupported, xSupported: xSupported)
    }

    static func hostClosed(facebookSupported: Bool, xSupported: Bool) {
        SharedStore.setSlowthAppForeground(false)
        let decision = BlockingRules.decide(softContext(SharedStore.snapshot()), .hostClosed)
        if let deferred = decision.deferred { SharedStore.setYouTubeShieldRestoreDeferred(deferred) }
        guard decision.monitor == .start else { SoftYouTubeActivityMonitoring.stop(); return }
        guard SoftYouTubeActivityMonitoring.start() else {
            SharedStore.setYouTubeShieldRestoreDeferred(BlockingRules.decide(softContext(SharedStore.snapshot()), .monitorFailed).deferred!)
            enforceAtRest(SharedStore.snapshot(), facebookSupported: facebookSupported, xSupported: xSupported)
            return
        }
        ManagedSettingsApplier.clear(surface: .youtube)
    }

    /// Returns the recorder's stopped-state YouTube latch. Other detector latches
    /// remain frame-processing state in SampleHandler.
    static func recordingStopped(_ state: SharedState) -> Bool {
        let decision = BlockingRules.decide(softContext(state), .recordingStopped)
        if let deferred = decision.deferred { SharedStore.setYouTubeShieldRestoreDeferred(deferred) }
        if decision.monitor == .start {
            if !SoftYouTubeActivityMonitoring.start() {
                SharedStore.setYouTubeShieldRestoreDeferred(false)
                return state.realtimeYouTubeBlockingEnabled
            }
        } else {
            SoftYouTubeActivityMonitoring.stop()
        }
        return state.realtimeYouTubeBlockingEnabled && decision.deferred != true
    }

    static func usageThreshold(_ event: DeviceActivityEvent.Name, activity: DeviceActivityName) {
        guard let generation = SoftYouTubeActivityMonitoring.generation(for: activity, event: event) else { return }
        let state = SharedStore.snapshot()
        var context = softContext(state)
        context.currentGeneration = SharedStore.softYouTubeMonitorGeneration() == generation
        let decision = BlockingRules.decide(context, .usageThreshold)
        guard decision.shield == .block,
              let data = state.youtubeSelectionData,
              let selection = try? JSONDecoder().decode(FamilyActivitySelection.self, from: data) else {
            SoftYouTubeActivityMonitoring.stop(activity: activity, generation: generation)
            return
        }
        ManagedSettingsApplier.apply(surface: .youtube, selection: selection)
        // Preserve the existing post-write race check: a newer foreground
        // transition wins even when it happens while Shield is being written.
        guard !SharedStore.isSlowthAppForeground(),
              SharedStore.softYouTubeMonitorGeneration() == generation else {
            ManagedSettingsApplier.clear(surface: .youtube)
            SoftYouTubeActivityMonitoring.stop(activity: activity, generation: generation)
            return
        }
        SharedStore.setYouTubeShieldRestoreDeferred(false)
        SoftYouTubeActivityMonitoring.stop(activity: activity, generation: generation)
    }
}
