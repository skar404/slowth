#if DEBUG
import XCTest
@testable import CascadeRuntime

final class SessionArchiveTests: XCTestCase {
    func testNativeArchiveContainsWholeSession() throws {
        try checkNativeArchive(renamed: true)
    }

    func testLegacySessionExportsWithoutNameMetadata() throws {
        try checkNativeArchive(renamed: false)
    }

    private func checkNativeArchive(renamed: Bool) throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let id = UUID()
        let session = SessionCapture(root: root, sessionID: id, interval: 1, startedUptime: 0)
        session.offer(.init(ptsValue: 0, ptsTimescale: 1, ptsEpoch: 0, ptsFlags: 1,
            orientation: nil, width: 1, height: 1, modelVersion: nil, predictions: nil), uptime: 0) { Data([1, 2]) }
        session.finish(reason: "finished")
        session.drain()
        let folder = root.appendingPathComponent(id.uuidString.lowercased())
        // A crash between JPEG and manifest writes can leave an unreferenced file.
        try Data([9]).write(to: folder.appendingPathComponent("orphan.jpg"))
        if renamed { try SessionCaptureName.rename(in: folder, to: "../../Поездка : screenshots") }
        let archive = try SessionCaptureArchive.export(folder, to: root.appendingPathComponent("export.zip"))
        XCTAssertEqual(archive.lastPathComponent, "export.zip")
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/ditto")
        let unpacked = root.appendingPathComponent("unpacked")
        process.arguments = ["-x", "-k", archive.path, unpacked.path]
        try process.run(); process.waitUntilExit()
        XCTAssertEqual(process.terminationStatus, 0)
        let files = FileManager.default.enumerator(at: unpacked, includingPropertiesForKeys: nil)!.allObjects as! [URL]
        XCTAssertFalse(files.contains { $0.lastPathComponent == "orphan.jpg" })
        let json = try XCTUnwrap(files.first { $0.lastPathComponent == "session.json" })
        let image = try XCTUnwrap(files.first { $0.lastPathComponent == "frame_000001.png" })
        if renamed {
            let name = try XCTUnwrap(files.first { $0.lastPathComponent == "session-name.json" })
            XCTAssertEqual(try SessionCaptureName.load(from: name.deletingLastPathComponent()), "../../Поездка : screenshots")
        } else {
            XCTAssertFalse(files.contains { $0.lastPathComponent == "session-name.json" })
        }
        XCTAssertEqual(try Data(contentsOf: json), try Data(contentsOf: folder.appendingPathComponent("session.json")))
        XCTAssertEqual(try Data(contentsOf: image), Data([1, 2]))
    }
}
#endif
