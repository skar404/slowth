import Foundation

enum ModelBackend: String, CaseIterable {
    #if DEBUG
    case v14
    case v15
    case flat11IPhone13ProMax
    #endif
    case cascadeV6
    case cascadeV7
    case cascadeV8
    case cascadeV10
    case flat11
    case flat12
    case flat13
    case flat14

    /// Capability belongs to the frozen selection, even if loading that model fails.
    /// Failed loads retain the selection's capabilities for the blocking policy.
    var supportsFacebook: Bool {
        #if DEBUG
        if self == .flat11IPhone13ProMax { return true }
        #endif
        return self == .cascadeV7 || self == .cascadeV8 || self == .cascadeV10 || self == .flat11 || self == .flat12 || self == .flat13 || self == .flat14
    }

    var supportsX: Bool {
        #if DEBUG
        if self == .flat11IPhone13ProMax { return true }
        #endif
        return self == .cascadeV8 || self == .cascadeV10 || self == .flat11 || self == .flat12 || self == .flat13 || self == .flat14
    }
}

enum ModelSettings {
    static let defaultBackend: ModelBackend = .flat14
}
