#if DEBUG
import XCTest
@testable import CascadeRuntime

final class SessionCaptureDeletionTests: XCTestCase {
    func testRemovesOnlySelectedSessionsAndContinuesAfterFailure() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let directories = (0..<3).map { root.appendingPathComponent("session-\($0)") }
        for directory in directories {
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
            try Data([1, 2, 3]).write(to: directory.appendingPathComponent("frame.jpg"))
        }
        let missing = root.appendingPathComponent("missing-session")
        let result = SessionCaptureDeletion.remove([directories[0], missing, directories[2]])
        XCTAssertEqual(result.deleted, Set([directories[0], directories[2]]))
        XCTAssertEqual(result.failures.map(\.directory), [missing])
        XCTAssertFalse(try XCTUnwrap(result.failures.first).message.isEmpty)
        XCTAssertFalse(FileManager.default.fileExists(atPath: directories[0].path))
        XCTAssertFalse(FileManager.default.fileExists(atPath: directories[2].path))
        XCTAssertEqual(try Data(contentsOf: directories[1].appendingPathComponent("frame.jpg")), Data([1, 2, 3]))
    }

    func testEmptySelectionDoesNothing() {
        let result = SessionCaptureDeletion.remove([])
        XCTAssertTrue(result.deleted.isEmpty)
        XCTAssertTrue(result.failures.isEmpty)
    }
}
#endif
