#if DEBUG
import XCTest
@testable import CascadeRuntime

final class SessionCaptureTests: XCTestCase {
    private var frame: SessionCapture.Frame {
        .init(ptsValue: 0, ptsTimescale: 60, ptsEpoch: 0, ptsFlags: 1,
              orientation: nil, width: 4, height: 3, modelVersion: nil, predictions: nil)
    }

    func testPauseResumeKeepsSessionAndDoesNotCapturePausedFrames() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let id = UUID()
        let session = SessionCapture(root: root, sessionID: id, interval: 1, startedUptime: 0)
        session.pause()
        XCTAssertFalse(session.offer(frame, uptime: 1) { XCTFail("paused"); return Data() })
        session.drain()
        let url = root.appendingPathComponent(id.uuidString.lowercased()).appendingPathComponent("session.json")
        XCTAssertEqual(try JSONDecoder().decode(SessionCapture.Manifest.self, from: Data(contentsOf: url)).status, "paused")
        session.resume()
        XCTAssertTrue(session.offer(frame, uptime: 2) { Data([1]) })
        session.finish(reason: "finished")
        session.resume()
        XCTAssertFalse(session.offer(frame, uptime: 3) { XCTFail("finished"); return Data() })
        session.drain()
        let manifest = try JSONDecoder().decode(SessionCapture.Manifest.self, from: Data(contentsOf: url))
        XCTAssertEqual(manifest.sessionID, id)
        XCTAssertEqual(manifest.frames.count, 1)
        XCTAssertEqual(manifest.events.map(\.kind), ["paused", "resumed"])
    }

    func testLimitsStopOnlyCaptureAndPersistReason() throws {
        for reason in ["duration_limit", "total_disk_limit", "low_disk", "error"] {
            let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
            defer { try? FileManager.default.removeItem(at: root) }
            let id = UUID()
            var limits = SessionCapture.Limits()
            if reason == "duration_limit" { limits.duration = 1 }
            if reason == "total_disk_limit" { limits.totalBytes = 0 }
            let session = SessionCapture(root: root, sessionID: id, interval: 1, startedUptime: 10,
                limits: limits, freeBytes: { reason == "low_disk" ? 0 : Int64.max })
            session.drain()
            session.offer(frame, uptime: reason == "duration_limit" ? 11 : 10) {
                if reason == "error" { throw CocoaError(.fileWriteUnknown) }
                return Data([1])
            }
            session.drain()
            XCTAssertFalse(session.offer(frame, uptime: 20) { XCTFail("limit must latch"); return Data() })
            session.finish(reason: "finished")
            session.drain()
            let manifest = try JSONDecoder().decode(SessionCapture.Manifest.self, from:
                Data(contentsOf: root.appendingPathComponent(id.uuidString.lowercased()).appendingPathComponent("session.json")))
            XCTAssertEqual(manifest.status, reason)
            XCTAssertTrue(manifest.frames.isEmpty)
        }
    }

    func testSamplingDropsBusyFramesWithoutWaitingAndStopsAdmission() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let id = UUID()
        let session = SessionCapture(root: root, sessionID: id, interval: 0.5, startedUptime: 10)
        let gate = DispatchSemaphore(value: 0)
        XCTAssertTrue(session.offer(frame, uptime: 10) { gate.wait(); return Data([1]) })
        XCTAssertFalse(session.offer(frame, uptime: 10.1) { XCTFail("not due"); return Data() })
        XCTAssertFalse(session.offer(frame, uptime: 10.5) { XCTFail("busy"); return Data() })
        gate.signal()
        session.drain()
        XCTAssertFalse(session.offer(frame, uptime: 10.6) { XCTFail("no catch-up burst"); return Data() })
        XCTAssertTrue(session.offer(frame, uptime: 11) { Data([2]) })
        session.finish(reason: "opted_out")
        XCTAssertFalse(session.offer(frame, uptime: 12) { XCTFail("closed"); return Data() })
        session.drain()
        let manifest = try JSONDecoder().decode(SessionCapture.Manifest.self, from:
            Data(contentsOf: root.appendingPathComponent(id.uuidString.lowercased()).appendingPathComponent("session.json")))
        XCTAssertEqual(manifest.frames.count, 2)
        XCTAssertEqual(manifest.droppedFrames, 1)
        XCTAssertEqual(manifest.status, "opted_out")
    }

    func testExistingGiBDoesNotBlockUnlimitedOrLargerBudgets() throws {
        let gib = 1_024 * 1_024 * 1_024
        for limit: Int? in [nil, gib, 2 * gib] {
            let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
            defer { try? FileManager.default.removeItem(at: root) }
            try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
            let previous = root.appendingPathComponent("previous.jpg")
            XCTAssertTrue(FileManager.default.createFile(atPath: previous.path, contents: nil))
            // A sparse file exercises accounting beyond the old cap without writing a GiB.
            let file = try FileHandle(forWritingTo: previous)
            try file.truncate(atOffset: UInt64(gib))
            try file.close()
            let id = UUID()
            let session = SessionCapture(root: root, sessionID: id, interval: 1, startedUptime: 0,
                limits: .init(totalBytes: limit), freeBytes: { Int64.max })
            session.offer(frame, uptime: 0) { Data([1]) }
            session.drain()
            let manifest = try JSONDecoder().decode(SessionCapture.Manifest.self, from:
                Data(contentsOf: root.appendingPathComponent(id.uuidString.lowercased()).appendingPathComponent("session.json")))
            XCTAssertEqual(manifest.status, limit == gib ? "total_disk_limit" : "active")
            XCTAssertEqual(manifest.frames.count, limit == gib ? 0 : 1)
            XCTAssertEqual(try previous.resourceValues(forKeys: [.fileSizeKey]).fileSize, gib)
            session.finish(reason: "finished")
            session.drain()
        }
    }

    func testTotalBudgetIncludesExistingSessionsAndNewFrames() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let existing = Data([1, 2, 3])
        try existing.write(to: root.appendingPathComponent("previous.jpg"))
        let id = UUID()
        let session = SessionCapture(root: root, sessionID: id, interval: 1, startedUptime: 0,
            limits: .init(totalBytes: existing.count + 8 * 1_024 * 1_024 + 1), freeBytes: { Int64.max })
        session.offer(frame, uptime: 0) { Data([4]) }
        session.drain()
        session.offer(frame, uptime: 1) { Data([5]) }
        session.drain()
        let folder = root.appendingPathComponent(id.uuidString.lowercased())
        let manifest = try JSONDecoder().decode(SessionCapture.Manifest.self, from:
            Data(contentsOf: folder.appendingPathComponent("session.json")))
        XCTAssertEqual(manifest.status, "total_disk_limit")
        XCTAssertEqual(manifest.frames.count, 1)
        XCTAssertEqual(manifest.jpegBytes, 1)
        XCTAssertFalse(FileManager.default.fileExists(atPath: folder.appendingPathComponent("frame_000002.png").path))
    }

    func testWritesSessionWithExactFrameProvenance() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let id = UUID()
        let session = SessionCapture(root: root, sessionID: id, interval: 1, startedUptime: 10)
        let frame = SessionCapture.Frame(ptsValue: 123, ptsTimescale: 60, ptsEpoch: 0,
            ptsFlags: 1, orientation: 6, width: 4, height: 3, modelVersion: "test-v1",
            predictions: ["other_app": 0.9])
        XCTAssertTrue(session.offer(frame, uptime: 10) { Data([1, 2, 3]) })
        session.finish(reason: "finished")
        session.drain()
        let folder = root.appendingPathComponent(id.uuidString.lowercased())
        XCTAssertEqual(try root.resourceValues(forKeys: [.isExcludedFromBackupKey]).isExcludedFromBackup, true)
        let data = try Data(contentsOf: folder.appendingPathComponent("session.json"))
        let manifest = try JSONDecoder().decode(SessionCapture.Manifest.self, from: data)
        XCTAssertEqual(manifest.sessionID, id)
        XCTAssertEqual(manifest.status, "finished")
        XCTAssertEqual(manifest.frames.count, 1)
        XCTAssertEqual(manifest.frames[0].ptsValue, 123)
        XCTAssertEqual(manifest.frames[0].orientation, 6)
        XCTAssertEqual(manifest.frames[0].modelVersion, "test-v1")
        XCTAssertEqual(manifest.frames[0].predictions?["other_app"], 0.9)
        XCTAssertFalse(String(decoding: data, as: UTF8.self).contains("label"))
        XCTAssertEqual(try Data(contentsOf: folder.appendingPathComponent(manifest.frames[0].filename)), Data([1, 2, 3]))
    }
}
#endif
