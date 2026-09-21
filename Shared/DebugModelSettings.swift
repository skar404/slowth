import Foundation

enum DebugModelBackend: String, CaseIterable {
    #if DEBUG
    case v14
    case v15
    #endif
    case cascadeV6

    var title: String {
        switch self {
        #if DEBUG
        case .v14: return "V14 (experimental — unqualified)"
        case .v15: return "V15 (experimental — unqualified; CoreML parity failed)"
        #endif
        case .cascadeV6: return "Cascade V6 (default — experimental — unqualified)"
        }
    }
}

/// Selection is read once when a broadcast starts, never mid-inference.
enum DebugModelSettings {
    static let storageKey = "debugRealtimeModelBackend"
    static let defaultBackend: DebugModelBackend = .cascadeV6

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
