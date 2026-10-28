#if DEBUG
import Foundation

/// Selection is read once when a broadcast starts, never mid-inference.
enum DebugModelSettings {
    static let storageKey = "debugRealtimeModelBackend"
    static let defaultBackend = ModelSettings.defaultBackend

    /// Retired selections and unknown values resolve to the current default.
    static func selection(stored: String?) -> ModelBackend {
        return stored.flatMap(ModelBackend.init(rawValue:)) ?? defaultBackend
    }

    static var cascadeAvailable: Bool {
        #if CASCADE_MODEL && os(iOS)
        return true
        #else
        return false
        #endif
    }

    static func resolve(stored: String?, debugEnabled: Bool, cascadeAvailable: Bool) -> ModelBackend {
        guard debugEnabled, cascadeAvailable else { return defaultBackend }
        return selection(stored: stored)
    }
}

extension ModelBackend {
    var title: String {
        switch self {
        #if DEBUG
        case .flat14: return "Flat 14 · 2026-10-28 (default — experimental)"
        case .flat11IPhone13ProMax: return "Flat 11 · iPhone 13 Pro Max · 2026-10-26 (experimental — unqualified)"
        case .v14: return "V14 (experimental — unqualified)"
        case .v15: return "V15 (experimental — unqualified; CoreML parity failed)"
        #endif
        case .cascadeV6: return "Cascade V6 (experimental — unqualified)"
        case .cascadeV8: return "Cascade V8 X (experimental — unqualified)"
        case .cascadeV10: return "Cascade V10 (experimental — unqualified)"
        case .flat11: return "Flat 11 · 2026-10-15 (experimental)"
        case .flat12: return "Flat 12 · 2026-10-27 (experimental)"
        case .flat13: return "Flat 13 · 2026-10-27 (experimental)"
        case .cascadeV7: return "Cascade V7 Facebook (experimental — unqualified)"
        }
    }
}
#endif
