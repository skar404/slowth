// Pure policy: inputs are facts captured by the coordinator under its existing
// transaction. No clocks, defaults, Apple frameworks or storage are read here.
struct BlockingContext {
    var target = "youtube"
    var enabled = true
    var recording = false
    var foreground = false
    var pauseOnly = false
    var activePause = false
    var inferenceFailed = false
    var pendingRest = false
    var graceActive = false
    var soft = false
    var deferred = false
    var validSelection = true
    var currentGeneration = true
    var requestedShield = false
    var runtimeFresh = false
    var runtimeWantsShield = true
    var bindingChanged = false
    var currentBinding = true
}

enum BlockingEvent {
    case shieldRequest, pauseEnded, hostAtRest
    case hostOpened, hostClosed, recordingStarted, recordingStopped
    case usageThreshold, monitorEligibility, monitorFailed
    case observation, contentDetected
}

struct BlockingDecision {
    enum Detection { case accept, suppress, unavailable, stale }
    var detection: Detection? = nil
    enum Shield { case keep, block, clear }
    enum Monitor { case keep, stop, start }
    var shield: Shield = .keep
    var monitor: Monitor = .keep
    var deferred: Bool? = nil
    var useRequestedSelection = false
    var resetObservations = false
    var reason: String
}

enum BlockingRules {
    static let restSeconds: Double = 60
    static let navigationGraceSeconds: Double = 5
    static let softUsageSeconds = 1

    enum SettingsRejection { case strict, youtubeDisabled }
    static func softModeRejection(enabling: Bool, strict: Bool, initialActivation: Bool,
                                  youtubeEnabled: Bool) -> SettingsRejection? {
        if strict && enabling && !initialActivation { return .strict }
        if enabling && !youtubeEnabled { return .youtubeDisabled }
        return nil
    }

    static func decide(_ c: BlockingContext, _ event: BlockingEvent) -> BlockingDecision {
        switch event {
        case .contentDetected:
            if !c.recording || !c.enabled || c.pauseOnly {
                return .init(detection: .unavailable, reason: "Detection service inactive")
            }
            if !c.currentBinding { return .init(detection: .stale, reason: "Selection or revision changed") }
            if c.inferenceFailed { return .init(detection: .unavailable, reason: "Classifier unavailable") }
            if c.activePause { return .init(detection: .suppress, resetObservations: true, reason: "Paused observations discarded") }
            return .init(detection: .accept, reason: "Create or retain detection rest")
        case .observation:
            return .init(resetObservations: c.bindingChanged || c.activePause || c.graceActive,
                         reason: "Discard observations across bindings, pauses and grace")
        case .shieldRequest:
            if c.activePause { return .init(shield: .clear, reason: "Active ordinary pause") }
            if c.enabled && !c.pauseOnly {
                if c.recording && c.inferenceFailed { return .init(shield: .block, reason: "Classifier unavailable") }
                if c.pendingRest { return .init(shield: .block, reason: "Rest unfinished") }
                if c.recording && c.graceActive { return .init(shield: .clear, reason: "Committed navigation grace") }
            }
            return .init(shield: c.requestedShield ? .block : .clear, useRequestedSelection: true, reason: "Current runtime request")
        case .pauseEnded:
            if !c.enabled || !c.validSelection { return .init(shield: .clear, reason: "Service unconfigured") }
            if c.recording && c.inferenceFailed { return .init(shield: .block, reason: "Classifier unavailable") }
            if c.pendingRest { return .init(shield: .block, reason: "Rest unfinished") }
            if c.pauseOnly { return .init(shield: .block, reason: "Recording independent protection") }
            if !c.recording && c.target == "youtube" && c.soft && c.deferred {
                return .init(shield: .clear, reason: "Soft YouTube usage pending")
            }
            return .init(shield: !c.recording || !c.runtimeFresh || c.runtimeWantsShield ? .block : .clear,
                         reason: "Restore current recorder intent or default protection")
        case .hostAtRest:
            if c.recording { return .init(reason: "Recorder owns runtime protection") }
            if !c.enabled || !c.validSelection { return .init(shield: .clear, reason: "Service unconfigured") }
            if c.target == "youtube" && (c.deferred || (c.soft && c.foreground)) {
                return .init(shield: .clear, reason: "Soft YouTube navigation")
            }
            return .init(shield: .block, reason: "Stopped recording")
        case .recordingStarted:
            return .init(shield: c.enabled && c.inferenceFailed ? .block : .clear,
                         resetObservations: true, reason: "Recording startup classification availability")
        case .hostOpened:
            if c.recording { return .init(monitor: .stop, reason: "Recording active") }
            if c.enabled && c.soft {
                return .init(shield: .clear, monitor: .stop, deferred: true, reason: "Slowth foreground window")
            }
            return .init(monitor: .stop, deferred: false, reason: "Normal mode")
        case .hostClosed, .recordingStopped:
            if c.recording || !c.enabled || !c.soft {
                return .init(monitor: .stop, deferred: event == .recordingStopped ? false : nil, reason: "Soft mode inactive")
            }
            if event == .recordingStopped && c.foreground {
                return .init(shield: .clear, monitor: .stop, deferred: true, reason: "Slowth foreground window")
            }
            return .init(shield: .clear, monitor: .start, deferred: true, reason: "Wait for one second of YouTube use")
        case .monitorEligibility, .usageThreshold:
            if !c.currentGeneration {
                return .init(monitor: .stop, reason: "Stale callback")
            }
            if !c.enabled || !c.soft || !c.deferred || c.recording || c.foreground || !c.validSelection {
                return .init(monitor: .stop, reason: "Monitor ineligible")
            }
            if event == .monitorEligibility { return .init(monitor: .start, reason: "Eligible usage monitor") }
            return .init(shield: .block, monitor: .stop, deferred: false, reason: "Usage threshold reached")
        case .monitorFailed:
            return .init(shield: .block, deferred: false, reason: "Monitor registration failed")
        }
    }
}
