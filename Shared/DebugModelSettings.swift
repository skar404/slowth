import Foundation

enum DebugModelBackend: String, CaseIterable {
    #if DEBUG
    case v14
    case v15
    #endif
    case cascadeV6
    case cascadeV7
    case cascadeV8
    case cascadeV10

    /// Capability belongs to the frozen selection, even if loading that model fails.
    /// Failed loads retain the selection's capabilities for the blocking policy.
    var supportsFacebook: Bool {
        self == .cascadeV7 || self == .cascadeV8 || self == .cascadeV10
    }

    var supportsX: Bool { self == .cascadeV8 || self == .cascadeV10 }

    var title: String {
        switch self {
        #if DEBUG
        case .v14: return "V14 (experimental — unqualified)"
        case .v15: return "V15 (experimental — unqualified; CoreML parity failed)"
        #endif
        case .cascadeV6: return "Cascade V6 (experimental — unqualified)"
        case .cascadeV8: return "Cascade V8 X (experimental — unqualified)"
        case .cascadeV10: return "Cascade V10 (default — experimental — unqualified)"
        case .cascadeV7: return "Cascade V7 Facebook (experimental — unqualified)"
        }
    }
}

/// Selection is read once when a broadcast starts, never mid-inference.
enum DebugModelSettings {
    static let storageKey = "debugRealtimeModelBackend"
    static let defaultBackend: DebugModelBackend = .cascadeV10

    /// Retired selections and unknown values resolve to the current default.
    static func selection(stored: String?) -> DebugModelBackend {
        #if DEBUG
        return stored.flatMap(DebugModelBackend.init(rawValue:)) ?? defaultBackend
        #else
        return defaultBackend
        #endif
    }

    static var cascadeAvailable: Bool {
        #if DEBUG && CASCADE_MODEL && os(iOS)
        return true
        #else
        return false
        #endif
    }

    static func resolve(stored: String?, debugEnabled: Bool, cascadeAvailable: Bool) -> DebugModelBackend {
        #if DEBUG
        guard debugEnabled, cascadeAvailable else { return defaultBackend }
        return selection(stored: stored)
        #else
        return defaultBackend
        #endif
    }
}
