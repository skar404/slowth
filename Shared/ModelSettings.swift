import Foundation

enum ModelBackend: String, CaseIterable {
    #if DEBUG
    case v14
    case v15
    #endif
    case cascadeV6
    case cascadeV7
    case cascadeV8
    case cascadeV10
    case flat11

    /// Capability belongs to the frozen selection, even if loading that model fails.
    /// Failed loads retain the selection's capabilities for the blocking policy.
    var supportsFacebook: Bool {
        self == .cascadeV7 || self == .cascadeV8 || self == .cascadeV10 || self == .flat11
    }

    var supportsX: Bool { self == .cascadeV8 || self == .cascadeV10 || self == .flat11 }
}

enum ModelSettings {
    static let defaultBackend: ModelBackend = .flat11
}
