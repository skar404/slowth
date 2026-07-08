import Foundation
#if canImport(FamilyControls)
import FamilyControls
#endif

@MainActor
enum FamilyControlsAuth {
    static var isAuthorized: Bool {
        #if canImport(FamilyControls)
        if #available(iOS 16.0, *) {
            return AuthorizationCenter.shared.authorizationStatus == .approved
        }
        #endif
        return false
    }

    static func requestAuthorization() async -> Bool {
        #if canImport(FamilyControls)
        if #available(iOS 16.0, *) {
            do {
                try await AuthorizationCenter.shared.requestAuthorization(for: .individual)
                return AuthorizationCenter.shared.authorizationStatus == .approved
            } catch {
                return false
            }
        }
        #endif
        return false
    }
}
