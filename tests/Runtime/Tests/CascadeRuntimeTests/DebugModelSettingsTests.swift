#if DEBUG
import XCTest
@testable import CascadeRuntime

final class DebugModelSettingsTests: XCTestCase {
    func testOnlyRetainedModelsAreSelectable() {
        XCTAssertEqual(ModelBackend.allCases.map(\.rawValue), ["v14", "v15", "flat11IPhone13ProMax", "cascadeV6", "cascadeV7", "cascadeV8", "cascadeV10", "flat11", "flat12", "flat13", "flat14", "flat15"])
        XCTAssertEqual(DebugModelSettings.defaultBackend, .flat15)
        XCTAssertFalse(ModelBackend.flat13.title.contains("default"))
        XCTAssertTrue(ModelBackend.flat14.supportsFacebook)
        XCTAssertTrue(ModelBackend.flat14.supportsX)
        XCTAssertFalse(ModelBackend.flat14.title.contains("default"))
        XCTAssertTrue(ModelBackend.flat15.title.contains("default"))
        XCTAssertTrue(ModelBackend.flat15.supportsFacebook)
        XCTAssertTrue(ModelBackend.flat15.supportsX)
        XCTAssertTrue(ModelBackend.flat11IPhone13ProMax.supportsFacebook)
        XCTAssertTrue(ModelBackend.flat11IPhone13ProMax.supportsX)
        XCTAssertFalse(ModelBackend.flat11IPhone13ProMax.title.contains("default"))
        XCTAssertTrue(ModelBackend.cascadeV8.supportsX)
        XCTAssertFalse(ModelBackend.cascadeV8.title.contains("default"))
        XCTAssertFalse(ModelBackend.v14.title.contains("default"))
        XCTAssertTrue(ModelBackend.v15.title.contains("CoreML parity failed"))
    }

    func testFacebookCapabilityFollowsSelectionAcrossLegacyAndDebugOff() {
        XCTAssertTrue(ModelBackend.cascadeV7.supportsFacebook)
        XCTAssertTrue(ModelBackend.cascadeV10.supportsFacebook)
        XCTAssertTrue(ModelBackend.cascadeV10.supportsX)
        XCTAssertFalse(ModelBackend.cascadeV7.supportsX)
        XCTAssertFalse(ModelBackend.cascadeV6.supportsFacebook)
        XCTAssertFalse(ModelBackend.v14.supportsFacebook)
        XCTAssertFalse(ModelBackend.v15.supportsFacebook)
        // A stored legacy choice must not override the default when Debug is turned off; the default Flat model stays available.
        let fallback = DebugModelSettings.resolve(stored: "cascadeV6", debugEnabled: false, cascadeAvailable: true)
        XCTAssertEqual(fallback, .flat15)
        XCTAssertTrue(fallback.supportsFacebook)
    }

    func testMissingUnknownAndRetiredSelectionsUseFlatDefault() {
        for stored: String? in [nil, "broken", "v10", "v11", "v12", "cascade", "cascadeV4", "cascadeV5"] {
            XCTAssertEqual(DebugModelSettings.selection(stored: stored), .flat15)
            XCTAssertEqual(DebugModelSettings.resolve(stored: stored, debugEnabled: true, cascadeAvailable: true), .flat15)
        }
    }

    func testRetainedSelectionsPersistAndRespectRuntimeGuards() throws {
        let suite = "ModelSelection-tests-" + UUID().uuidString
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        XCTAssertEqual(DebugModelSettings.resolve(stored: defaults.string(forKey: DebugModelSettings.storageKey),
                                                debugEnabled: true, cascadeAvailable: true), .flat15)
        for backend in ModelBackend.allCases {
            defaults.set(backend.rawValue, forKey: DebugModelSettings.storageKey)
            let stored = defaults.string(forKey: DebugModelSettings.storageKey)
            XCTAssertEqual(DebugModelSettings.selection(stored: stored), backend)
            XCTAssertEqual(DebugModelSettings.resolve(stored: stored, debugEnabled: true, cascadeAvailable: true), backend)
            XCTAssertEqual(DebugModelSettings.resolve(stored: stored, debugEnabled: false, cascadeAvailable: true), .flat15)
            XCTAssertEqual(DebugModelSettings.resolve(stored: stored, debugEnabled: true, cascadeAvailable: false), .flat15)
            XCTAssertEqual(DebugModelSettings.resolve(stored: stored, debugEnabled: false, cascadeAvailable: false), .flat15)
        }
    }
}
#endif
