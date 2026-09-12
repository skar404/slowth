import Foundation
#if canImport(FamilyControls)
import FamilyControls
#endif

@MainActor
enum FamilyControlsAuth {
    static var isAuthorized: Bool {
        #if canImport(FamilyControls)
        if #available(iOS 16.0, *) {
            return isAuthorized(AuthorizationCenter.shared.authorizationStatus)
        }
        #endif
        return false
    }

    static func isAuthorized(_ status: AuthorizationStatus) -> Bool {
        if status == .approved {
            return true
        }
        if #available(iOS 26.4, *), status == .approvedWithDataAccess {
            return true
        }
        return false
    }

    static func requestAuthorization() async -> Bool {
        #if canImport(FamilyControls)
        if #available(iOS 16.0, *) {
            do {
                try await AuthorizationCenter.shared.requestAuthorization(for: .individual)
                return isAuthorized(AuthorizationCenter.shared.authorizationStatus)
            } catch {
                return false
            }
        }
        #endif
        return false
    }
}
