#if DEBUG
import XCTest
@testable import CascadeRuntime

final class SessionCaptureSettingsTests: XCTestCase {
    func testStorageSelectionPersistsAndDefaultsToUnlimited() throws {
        let suite = "SessionCaptureSettingsTests.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        XCTAssertNil(SessionCaptureSettings.captureLimits(defaults: defaults).totalBytes)

        for gib in [1, 2, 5, 10, 20, 50] {
            defaults.set(gib, forKey: SessionCaptureSettings.storageLimitKey)
            let reopened = try XCTUnwrap(UserDefaults(suiteName: suite))
            XCTAssertEqual(SessionCaptureSettings.captureLimits(defaults: reopened).totalBytes,
                           gib * 1_024 * 1_024 * 1_024)
        }
        for value in [0, -1, Int.max] {
            defaults.set(value, forKey: SessionCaptureSettings.storageLimitKey)
            XCTAssertNil(SessionCaptureSettings.captureLimits(defaults: defaults).totalBytes)
        }
    }

    func testOptInRequiresDebugAndSeparateConsentAndValidatesInterval() {
        XCTAssertNil(SessionCaptureSettings.resolve(debug: false, optedIn: true, interval: 0.5))
        XCTAssertNil(SessionCaptureSettings.resolve(debug: true, optedIn: false, interval: 1))
        XCTAssertEqual(SessionCaptureSettings.resolve(debug: true, optedIn: true, interval: 0), 1)
        XCTAssertEqual(SessionCaptureSettings.resolve(debug: true, optedIn: true, interval: 0.5), 0.5)
        XCTAssertEqual(SessionCaptureSettings.resolve(debug: true, optedIn: true, interval: .nan), 1)
    }
}
#endif
