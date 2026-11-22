#if DEBUG
import XCTest
@testable import CascadeRuntime

final class SessionNameTests: XCTestCase {
    func testInvalidNamesDoNotReplaceSavedName() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let id = UUID()
        let capture = SessionCapture(root: root, sessionID: id, interval: 1, startedUptime: 0)
        capture.finish(reason: "finished")
        capture.drain()
        let directory = root.appendingPathComponent(id.uuidString.lowercased())
        try SessionCaptureName.rename(in: directory, to: "Keep me")
        for invalid in ["", " \n\t ", "line\nbreak", "null\u{0}byte", String(repeating: "a", count: 121)] {
            XCTAssertThrowsError(try SessionCaptureName.rename(in: directory, to: invalid))
            XCTAssertEqual(try SessionCaptureName.load(from: directory), "Keep me")
        }
    }

    func testRenameWhileFrameIsWritingSurvivesPauseResumeAndFinish() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let id = UUID()
        let capture = SessionCapture(root: root, sessionID: id, interval: 1, startedUptime: 0)
        capture.drain()
        let directory = root.appendingPathComponent(id.uuidString.lowercased())
        let entered = DispatchSemaphore(value: 0)
        let release = DispatchSemaphore(value: 0)
        defer { release.signal() }
        XCTAssertTrue(capture.offer(.init(ptsValue: 123, ptsTimescale: 60, ptsEpoch: 0, ptsFlags: 1,
            orientation: 6, width: 4, height: 3, modelVersion: "fixture", predictions: nil), uptime: 0) {
            entered.signal()
            release.wait()
            return Data([1, 2, 3])
        })
        XCTAssertEqual(entered.wait(timeout: .now() + 5), .success)
        try SessionCaptureName.rename(in: directory, to: "Live recording")
        capture.pause()
        capture.resume()
        capture.finish(reason: "finished")
        release.signal()
        capture.drain()
        XCTAssertEqual(try SessionCaptureName.load(from: directory), "Live recording")
        let manifest = try JSONDecoder().decode(SessionCapture.Manifest.self,
            from: Data(contentsOf: directory.appendingPathComponent("session.json")))
        XCTAssertEqual(manifest.sessionID, id)
        XCTAssertEqual(manifest.status, "finished")
        XCTAssertEqual(manifest.events.map(\.kind), ["paused", "resumed"])
        XCTAssertEqual(manifest.frames.count, 1)
        XCTAssertEqual(manifest.frames.first?.ptsValue, 123)
        XCTAssertEqual(manifest.jpegBytes, 3)
        XCTAssertEqual(try Data(contentsOf: directory.appendingPathComponent("frame_000001.png")), Data([1, 2, 3]))
    }

    func testMissingRecordingIsNotCreatedByRename() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        XCTAssertThrowsError(try SessionCaptureName.rename(in: directory, to: "Missing"))
        XCTAssertFalse(FileManager.default.fileExists(atPath: directory.path))
    }

    func testReadAndWriteErrorsAreReportedWithoutChangingManifest() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let id = UUID()
        let capture = SessionCapture(root: root, sessionID: id, interval: 1, startedUptime: 0)
        capture.finish(reason: "finished")
        capture.drain()
        let directory = root.appendingPathComponent(id.uuidString.lowercased())
        let manifestURL = directory.appendingPathComponent("session.json")
        let original = try Data(contentsOf: manifestURL)
        let nameURL = directory.appendingPathComponent(SessionCaptureName.filename)
        try Data("not JSON".utf8).write(to: nameURL)
        XCTAssertThrowsError(try SessionCaptureName.load(from: directory))
        try SessionCaptureName.rename(in: directory, to: "Recovered")
        XCTAssertEqual(try SessionCaptureName.load(from: directory), "Recovered")
        try FileManager.default.removeItem(at: nameURL)
        try FileManager.default.createDirectory(at: nameURL, withIntermediateDirectories: false)
        XCTAssertThrowsError(try SessionCaptureName.rename(in: directory, to: "Cannot write"))
        XCTAssertEqual(try Data(contentsOf: manifestURL), original)
    }

    func testRenamePersistsWithoutChangingRecording() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let id = UUID()
        let capture = SessionCapture(root: root, sessionID: id, interval: 1, startedUptime: 0)
        capture.finish(reason: "finished")
        capture.drain()
        let directory = root.appendingPathComponent(id.uuidString.lowercased())
        let manifestURL = directory.appendingPathComponent("session.json")
        let original = try Data(contentsOf: manifestURL)
        XCTAssertNil(try SessionCaptureName.load(from: directory)) // legacy recording
        try SessionCaptureName.rename(in: directory, to: "  Поездка 📷  \n")
        XCTAssertEqual(try SessionCaptureName.load(from: directory), "Поездка 📷")
        XCTAssertEqual(try Data(contentsOf: manifestURL), original)
        try SessionCaptureName.rename(in: directory, to: "Second name")
        XCTAssertEqual(try SessionCaptureName.load(from: directory), "Second name")
        XCTAssertEqual(try Data(contentsOf: manifestURL), original)
    }
}
#endif
