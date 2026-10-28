// Run with scripts/test_ios_welcome.sh. The token fixture exercises the same
// decoding/readiness code on macOS; native FamilyControls tokens need device QA.
import Foundation

enum AppGroup {
    static let identifier = "test.ios-welcome.\(UUID().uuidString)"
    static let defaults = UserDefaults(suiteName: identifier)!
}

enum DebugMode { static let isEnabled = false }

struct FamilyActivitySelection: Codable {
    var applicationTokens: Set<String> = []
    var categoryTokens: Set<String> = []
    var webDomainTokens: Set<String> = []
}

@main
struct IOSWelcomeTests {
    static func main() throws {
        let defaults = AppGroup.defaults
        defer { defaults.removePersistentDomain(forName: AppGroup.identifier) }
        let keys = [SharedStoreKey.youtubeSelectionData, SharedStoreKey.instagramSelectionData,
                    SharedStoreKey.facebookSelectionData, SharedStoreKey.xSelectionData,
                    "pauseOnly.tiktok.selection", "pauseOnly.snapchat.selection"]
        // Neither prior welcome, authorization, Safari nor recording/blocking flags
        // substitute for a saved binding. Readiness is a read-only operation.
        for key in ["iosWelcomeV1Handled", "onboardingDone", "broadcastActive",
                    "realtimeShieldEnabled", "realtimeYouTubeBlockingEnabled"] {
            defaults.set(true, forKey: key)
        }
        let before = defaults.dictionaryRepresentation() as NSDictionary
        precondition(!IOSWelcomeEligibility.isConfigured())
        precondition(before.isEqual(to: defaults.dictionaryRepresentation()))
        let valid = try JSONEncoder().encode(FamilyActivitySelection(applicationTokens: ["app"]))
        let invalid = try [FamilyActivitySelection(),
            FamilyActivitySelection(applicationTokens: ["a", "b"]),
            FamilyActivitySelection(applicationTokens: ["a"], categoryTokens: ["c"]),
            FamilyActivitySelection(applicationTokens: ["a"], webDomainTokens: ["web"])
        ].map { try JSONEncoder().encode($0) } + [Data([1])]
        for key in keys {
            for data in invalid {
                defaults.set(data, forKey: key)
                precondition(!IOSWelcomeEligibility.isConfigured(), "Invalid binding: \(key)")
            }
            defaults.removeObject(forKey: key)
            enum SaveFailure: Error { case coordinator }
            do {
                try SharedStore.withSelectionRollback(key: key) {
                    defaults.set(valid, forKey: key)
                    throw SaveFailure.coordinator
                }
                preconditionFailure("Expected save failure")
            } catch SaveFailure.coordinator {}
            precondition(!IOSWelcomeEligibility.isConfigured(), "Failed first save must not complete setup")
            defaults.set(valid, forKey: key)
            precondition(IOSWelcomeEligibility.isConfigured(), "Every supported app counts: \(key)")
            let savedState = defaults.dictionaryRepresentation() as NSDictionary
            do {
                try SharedStore.withSelectionRollback(key: key) {
                    defaults.removeObject(forKey: key)
                    throw SaveFailure.coordinator
                }
                preconditionFailure("Expected replacement failure")
            } catch SaveFailure.coordinator {}
            precondition(savedState.isEqual(to: defaults.dictionaryRepresentation()))
            defaults.synchronize()
            precondition(UserDefaults(suiteName: AppGroup.identifier)!.data(forKey: key) == valid)
            defaults.removeObject(forKey: key)
            precondition(!IOSWelcomeEligibility.isConfigured(), "Last removal must revoke readiness")
        }
        // Exercise the admission gate used before every side effect in SampleHandler.
        var admission = RecordingAdmission()
        precondition(!admission.enter(hasSelection: false))
        precondition(!admission.active && !admission.admitted)
        precondition(admission.enter(hasSelection: true))
        // Removing a binding has no effect on the running gate.
        precondition(admission.active)
        admission.pause()
        precondition(!admission.active && admission.admitted)
        precondition(!admission.enter(hasSelection: false))
        precondition(!admission.admitted, "Rejected resume must skip finish's blocking mutations")
        precondition(admission.enter(hasSelection: true))
        admission.finish()
        precondition(!admission.active && !admission.admitted)
        print("Welcome checks passed: 6 app types, invalid/empty selections, persistence, removal, no writes, start/resume admission")
    }
}
