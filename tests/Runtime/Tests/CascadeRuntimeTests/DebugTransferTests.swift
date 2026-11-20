#if DEBUG
import XCTest
@testable import CascadeRuntime

final class DebugTransferTests: XCTestCase {
    func testProfilesAndQRValidation() throws {
        let profile = DebugTransferProfile(name: "Local", transport: .http, endpoint: "http://192.168.1.2:8765/")
        XCTAssertEqual(try profile.validated().endpoint, "http://192.168.1.2:8765")
        for host in ["10.1.2.3", "172.31.1.2", "100.100.1.2", "mac.local", "[fd00::1]"] {
            XCTAssertNoThrow(try DebugTransferProfile(name: "Local", transport: .http, endpoint: "http://\(host):8765").validated())
        }
        for url in ["http://example.com", "http://8.8.8.8", "http://192.168.1.2?secret=x", "http://user:pass@192.168.1.2", "file:///tmp"] {
            XCTAssertThrowsError(try DebugTransferProfile(name: "Local", transport: .http, endpoint: url).validated())
        }
        let link = DebugTransferLink(version: 1, profile: profile, credentials: nil)
        let data = try JSONEncoder().encode(link)
        let encoded = data.base64EncodedString().replacingOccurrences(of: "+", with: "-").replacingOccurrences(of: "/", with: "_").replacingOccurrences(of: "=", with: "")
        let url = URL(string: "slowth://debug-transfer#config=\(encoded)")!
        let decoded = try DebugTransferLink.parse(url)
        XCTAssertNotEqual(decoded.profile.id, profile.id)
        XCTAssertEqual(decoded.profile.destinationID, try profile.validated().destinationID)
        XCTAssertThrowsError(try DebugTransferLink.parse(URL(string: "slowth://debug-transfer?config=\(encoded)")!))
        var other = try profile.validated(); other.endpoint = "http://192.168.1.3:8765"
        XCTAssertNotEqual(decoded.profile.destinationID, other.destinationID)
    }

    func testS3SignatureMatchesPublishedAWSVector() throws {
        var request = URLRequest(url: URL(string: "https://examplebucket.s3.amazonaws.com/test.txt")!)
        request.httpMethod = "GET"; request.setValue("bytes=0-9", forHTTPHeaderField: "Range")
        let date = ISO8601DateFormatter().date(from: "2013-05-24T00:00:00Z")!
        let secret = DebugTransferSecret(accessKeyID: "AKIAIOSFODNN7EXAMPLE", secretAccessKey: "wJalrXUtnFEMI/K7MDENG/bPxRfiCYEXAMPLEKEY")
        let signed = try DebugS3Signer.sign(request, region: "us-east-1", secret: secret, payloadHash: DebugTransferDigest.hex(Data()), date: date)
        XCTAssertTrue(signed.value(forHTTPHeaderField: "Authorization")!.hasSuffix("Signature=f0e8bdb87c964420e857bd35b5d6ed310bd44f0170aba48dd91039c6036bdb41"))
        var profile = DebugTransferProfile(name: "S3", transport: .s3, endpoint: "https://s3.example.com")
        profile.bucket = "my-bucket"; profile.region = "eu-central-1"; profile.prefix = "raw data/тест"
        let url = try DebugS3Signer.objectURL(profile: profile.validated(), key: "motion/test%file.json")
        XCTAssertEqual(url.absoluteString, "https://s3.example.com/my-bucket/raw%20data/%D1%82%D0%B5%D1%81%D1%82/motion/test%25file.json")
    }

    private func fixture(_ root: URL) throws -> DebugTransferSnapshot {
        try DebugTransferSnapshot.prepare(.motion(UUID(), ["session.json": Data("{}".utf8),
            "samples.json": Data("[]".utf8), "motion.csv": Data("x,y,z\n0,0,1\n".utf8)]), root: root)
    }
    private func videoFixture(_ root: URL) throws -> DebugTransferSnapshot {
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let video = root.appendingPathComponent("segment-test.mov")
        try Data(repeating: 42, count: 2 * 1024 * 1024).write(to: video)
        return try DebugTransferSnapshot.prepare(.motionFiles(UUID(), [
            "session.json": Data("{}".utf8), "samples.json": Data("[]".utf8),
            "edits.json": Data("{}".utf8), "video.json": Data("{}".utf8),
            "motion.csv": Data("unix_seconds,tags_json\n".utf8)], [video]), root: root)
    }
    func testVideoSnapshotCopiesFilesAndRetainsEditsWithoutSamples() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let snapshot = try videoFixture(root)
        try snapshot.validate(at: root.appendingPathComponent(snapshot.id))
        XCTAssertEqual(snapshot.inventory.files.first { $0.name == "segment-test.mov" }?.contentType, "video/quicktime")
        XCTAssertEqual(snapshot.inventory.files.first { $0.name == "segment-test.mov" }?.size, 2 * 1024 * 1024)
        try FileManager.default.removeItem(at: root.appendingPathComponent("segment-test.mov"))
        try snapshot.validate(at: root.appendingPathComponent(snapshot.id))
    }

    func testSnapshotIsStableAndRejectsCorruption() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let snapshot = try fixture(root)
        let directory = root.appendingPathComponent(snapshot.id)
        try snapshot.validate(at: directory)
        XCTAssertEqual(snapshot.inventory.files.count, 3)
        try Data("broken".utf8).write(to: directory.appendingPathComponent("motion.csv"))
        XCTAssertThrowsError(try snapshot.validate(at: directory))
        XCTAssertFalse(DebugTransferFile.validName("../private"))
        XCTAssertFalse(DebugTransferFile.validName("COMPLETE.json"))
    }

    func testHTTPAndS3ShareResumeAndCommitOrdering() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let snapshot = try fixture(root)
        for kind in DebugTransferProfile.Transport.allCases {
            var profile = DebugTransferProfile(name: "Test", transport: kind, endpoint: kind == .http ? "http://127.0.0.1:8765" : "https://s3.example.com")
            profile.bucket = "my-bucket"; profile.region = "us-east-1"
            let secret = kind == .s3 ? DebugTransferSecret(accessKeyID: "example", secretAccessKey: "example-secret") : nil
            var remote: [String: (String, Int)] = [:]
            var puts: [String] = []
            let execute: DebugTransferTransport.Execute = { request, file, progress in
                let path = request.url!.path
                let hashHeader = kind == .http ? "x-content-sha256" : "x-amz-meta-sha256"
                XCTAssertEqual(request.value(forHTTPHeaderField: "Authorization") == nil, kind == .http)
                if request.httpMethod == "HEAD" {
                    guard let stored = remote[path] else { return .init(status: 404) }
                    return .init(status: 200, headers: ["Content-Length": String(stored.1), hashHeader: stored.0])
                }
                let data = try Data(contentsOf: XCTUnwrap(file))
                XCTAssertEqual(request.value(forHTTPHeaderField: hashHeader), DebugTransferDigest.hex(data))
                remote[path] = (DebugTransferDigest.hex(data), data.count); puts.append(path)
                progress(1)
                let receipt = try JSONSerialization.data(withJSONObject: ["accepted": true, "snapshotID": snapshot.id])
                return .init(status: 200, data: receipt)
            }
            try await DebugTransferTransport.send(snapshot: snapshot, directory: root.appendingPathComponent(snapshot.id), profile: profile, secret: secret, execute: execute, progress: { _ in })
            XCTAssertEqual(puts.count, 4)
            XCTAssertTrue(puts.last!.hasSuffix(kind == .http ? "/complete" : "/COMPLETE.json"))
            try await DebugTransferTransport.send(snapshot: snapshot, directory: root.appendingPathComponent(snapshot.id), profile: profile, secret: secret, execute: execute, progress: { _ in })
            XCTAssertEqual(puts.count, 4, "Verified files must not be uploaded again")
        }
    }

    func testRealHTTPReceiverAcceptsSwiftClientForBothTypes() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        var project = URL(fileURLWithPath: #filePath).deletingLastPathComponent()
        for _ in 0..<4 { project.deleteLastPathComponent() }
        let process = Process(); let output = Pipe()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/env")
        process.arguments = ["python3", "-u", "-c", "import sys; sys.path.insert(0,sys.argv[1]); from debug_transfer_receiver import Receiver; s=Receiver(('127.0.0.1',0),sys.argv[2]); print(s.server_port,flush=True); s.serve_forever()", project.appendingPathComponent("scripts").path, root.appendingPathComponent("received").path]
        process.standardOutput = output
        try process.run()
        defer { process.terminate(); process.waitUntilExit() }
        let portData = output.fileHandleForReading.availableData
        let port = try XCTUnwrap(Int(String(decoding: portData, as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines)))
        let profile = DebugTransferProfile(name: "Integration", transport: .http, endpoint: "http://127.0.0.1:\(port)")
        let motion = try fixture(root.appendingPathComponent("staged"))
        let captureRoot = root.appendingPathComponent("captures")
        let id = UUID()
        let capture = SessionCapture(root: captureRoot, sessionID: id, interval: 1, startedUptime: 0,
            freeBytes: { Int64.max })
        capture.drain()
        capture.offer(.init(ptsValue: 0, ptsTimescale: 1, ptsEpoch: 0, ptsFlags: 1, orientation: nil,
            width: 1, height: 1, modelVersion: nil, predictions: nil), uptime: 0) { Data([137, 80, 78, 71, 13, 10, 26, 10]) }
        capture.drain(); capture.finish(reason: "finished"); capture.drain()
        let screenshot = try DebugTransferSnapshot.prepare(.screenshots(captureRoot.appendingPathComponent(id.uuidString.lowercased()), id), root: root.appendingPathComponent("staged"))
        let network = DebugTransferNetwork()
        let video = try videoFixture(root.appendingPathComponent("staged"))
        for snapshot in [motion, screenshot, video] {
            let directory = root.appendingPathComponent("staged").appendingPathComponent(snapshot.id)
            for _ in 0..<2 {
                try await DebugTransferTransport.send(snapshot: snapshot, directory: directory, profile: profile, secret: nil,
                    execute: { request, file, progress in try await network.execute(request, file: file, progress: progress) }, progress: { _ in })
            }
            let received = root.appendingPathComponent("received").appendingPathComponent(snapshot.objectPrefix)
            for file in snapshot.inventory.files {
                XCTAssertEqual(try Data(contentsOf: received.appendingPathComponent(file.name)), try Data(contentsOf: directory.appendingPathComponent(file.name)))
            }
            XCTAssertTrue(FileManager.default.fileExists(atPath: received.appendingPathComponent("COMPLETE.json").path))
        }
    }

    func testMismatchAndCancellationNeverCommit() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let snapshot = try fixture(root)
        let profile = DebugTransferProfile(name: "Local", transport: .http, endpoint: "http://127.0.0.1:8765")
        var writes = 0
        do {
            try await DebugTransferTransport.send(snapshot: snapshot, directory: root.appendingPathComponent(snapshot.id), profile: profile, secret: nil, execute: { request, _, _ in
                if request.httpMethod == "PUT" { writes += 1 }
                return .init(status: 200, headers: ["Content-Length": "0", "X-Content-SHA256": "wrong"])
            }, progress: { _ in })
            XCTFail("Mismatched remote content was accepted")
        } catch { XCTAssertEqual(writes, 0) }
        var requests = 0
        do {
            try await DebugTransferTransport.send(snapshot: snapshot, directory: root.appendingPathComponent(snapshot.id), profile: profile, secret: nil, execute: { _, _, _ in
                requests += 1; throw CancellationError()
            }, progress: { _ in })
            XCTFail("Cancellation was ignored")
        } catch is CancellationError { XCTAssertEqual(requests, 1) }
    }
}
#endif
