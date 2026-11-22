#if DEBUG
import XCTest
@testable import CascadeRuntime

final class SessionUploadTests: XCTestCase {
    private let serverURL = URL(string: "https://labeler.example:9443/private")!

    func testServerAddressValidationAndNormalization() throws {
        XCTAssertEqual(try SessionUploadServer.url(from: "  https://LABELER.example:443/ ").absoluteString,
                       "https://labeler.example")
        XCTAssertEqual(try SessionUploadServer.url(from: "https://labeler.example:9443/private/").absoluteString,
                       serverURL.absoluteString)
        XCTAssertEqual(try SessionUploadServer.url(from: "http://192.168.1.20:8765/").absoluteString,
                       "http://192.168.1.20:8765")
        for value in ["http://192.169.1.20", "http://192.168.1.999", "http://192.168.1.20.evil.test", "", "labeler.example", "http://labeler.example", "https:///", "https://user:pass@labeler.example",
                      "https://labeler.example?token=secret", "https://labeler.example/#fragment", "https://labeler.example:99999"] {
            XCTAssertThrowsError(try SessionUploadServer.url(from: value), value)
        }
    }

    @MainActor func testSentPresentationRequiresAcceptedExactCurrentFingerprint() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let url = root.appendingPathComponent("index.json")
        let index = try SessionUploadIndex(url: url)
        let id = UUID()
        XCTAssertFalse(index.status(id, fingerprint: "current").isSentPresentation)
        for state: SessionUploadState in [.notSent, .uploading, .error, .accepted] {
            try index.set(id, fingerprint: "current", state: state)
            XCTAssertEqual(index.status(id, fingerprint: "current").isSentPresentation, state == .accepted)
            XCTAssertFalse(index.status(id, fingerprint: "changed").isSentPresentation)
            XCTAssertFalse(index.status(UUID(), fingerprint: "current").isSentPresentation)
        }
        let restored = try SessionUploadIndex(url: url)
        XCTAssertTrue(restored.status(id, fingerprint: "current").isSentPresentation)
        XCTAssertFalse(restored.status(id, fingerprint: "changed").isSentPresentation)
        try restored.set(id, fingerprint: "current", state: .uploading)
        XCTAssertFalse(try SessionUploadIndex(url: url).status(id, fingerprint: "current").isSentPresentation)
    }

    func testExportReportsExactSnapshotIdentity() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let manifest = SessionCapture.Manifest(sessionID: UUID(), startedAt: Date(), intervalSeconds: 1)
        try JSONEncoder().encode(manifest).write(to: root.appendingPathComponent("session.json"))
        var identity: String?
        _ = try SessionCaptureArchive.export(root, to: root.appendingPathComponent("test.zip")) {
            identity = try SessionUploadIdentity.fingerprint($0)
        }
        XCTAssertEqual(identity, try SessionUploadIdentity.fingerprint(root))
    }

    @MainActor func testIndexReceiptAndRelaunch() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let index = try SessionUploadIndex(url: root.appendingPathComponent("index.json"))
        let id = UUID()
        try index.set(id, fingerprint: "snapshot", state: .uploading)
        let restored = try SessionUploadIndex(url: root.appendingPathComponent("index.json"))
        XCTAssertEqual(restored.status(id, fingerprint: "snapshot"), .error)
        try restored.set(id, fingerprint: "snapshot", state: .accepted)
        XCTAssertEqual(restored.status(id, fingerprint: "changed"), .notSent)
        XCTAssertEqual(try SessionUploadIndex(url: root.appendingPathComponent("index.json")).status(id, fingerprint: "snapshot"), .accepted)
        let receipt = Data("{\"accepted\":true,\"receiptVersion\":1,\"archiveSHA256\":\"hash\",\"sessionID\":\"\(id)\",\"added\":2,\"duplicates\":0}".utf8)
        XCTAssertNoThrow(try SessionUploadReceipt.validate(receipt, status: 200, id: id, digest: "hash", frames: 2))
        XCTAssertThrowsError(try SessionUploadReceipt.validate(receipt, status: 409, id: id, digest: "hash", frames: 2))
        XCTAssertThrowsError(try SessionUploadReceipt.validate(receipt, status: 200, id: id, digest: "other", frames: 2))
        XCTAssertThrowsError(try SessionUploadReceipt.validate(receipt, status: 200, id: id, digest: "hash", frames: 3))
    }

    @MainActor func testSendPersistsOnlyValidatedReceiptAndExcludesConcurrentSends() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let id = UUID()
        let manifest = SessionCapture.Manifest(sessionID: id, startedAt: Date(), intervalSeconds: 1)
        try JSONEncoder().encode(manifest).write(to: root.appendingPathComponent("session.json"))
        let uploader = try SessionUploader(indexURL: root.appendingPathComponent("index.json"))
        let task = Task {
            try await uploader.send(root, id: id, serverURL: self.serverURL, token: String(repeating: "a", count: 43), permitted: { true }) { request, file in
                XCTAssertEqual(request.url?.absoluteString, "https://labeler.example:9443/private/api/native/import-session")
                let digest = try SessionUploadIdentity.hash(file)
                XCTAssertEqual(request.value(forHTTPHeaderField: "X-Archive-SHA256"), digest)
                try await Task.sleep(nanoseconds: 50_000_000)
                return (Data("{\"accepted\":true,\"receiptVersion\":1,\"archiveSHA256\":\"\(digest)\",\"sessionID\":\"\(id)\",\"added\":0,\"duplicates\":0}".utf8), 200)
            }
        }
        await Task.yield()
        do {
            try await uploader.send(root, id: id, serverURL: self.serverURL, token: String(repeating: "a", count: 43), permitted: { true })
            XCTFail("concurrent send allowed")
        } catch { XCTAssertTrue(error is SessionUploadError) }
        try await task.value
        XCTAssertEqual(uploader.index.status(id, fingerprint: try SessionUploadIdentity.fingerprint(root)), .accepted)
        do {
            try await uploader.send(root, id: id, serverURL: self.serverURL, token: String(repeating: "a", count: 43), permitted: { true }) { _, _ in (Data("{}".utf8), 200) }
            XCTFail("invalid receipt accepted")
        } catch {}
        XCTAssertEqual(uploader.index.status(id, fingerprint: try SessionUploadIdentity.fingerprint(root)), .error)
        let cancelled = Task {
            try await uploader.send(root, id: id, serverURL: self.serverURL, token: String(repeating: "a", count: 43), permitted: { true }) { _, _ in
                throw CancellationError()
            }
        }
        do { try await cancelled.value; XCTFail("cancel accepted") } catch {}
        XCTAssertFalse(uploader.isUploading)
        XCTAssertEqual(uploader.index.status(id, fingerprint: try SessionUploadIdentity.fingerprint(root)), .error)
    }

    @MainActor func testPersistenceFailureCannotLeaveInactiveUploading() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let id = UUID()
        let manifest = SessionCapture.Manifest(sessionID: id, startedAt: Date(), intervalSeconds: 1)
        try JSONEncoder().encode(manifest).write(to: root.appendingPathComponent("session.json"))
        let indexFolder = root.appendingPathComponent("index")
        let uploader = try SessionUploader(indexURL: indexFolder.appendingPathComponent("state.json"))
        do {
            try await uploader.send(root, id: id, serverURL: self.serverURL, token: String(repeating: "a", count: 43), permitted: { true }) { _, _ in
                try FileManager.default.removeItem(at: indexFolder)
                try Data([1]).write(to: indexFolder)
                throw CancellationError()
            }
            XCTFail("failure accepted")
        } catch {}
        XCTAssertFalse(uploader.isUploading)
        XCTAssertEqual(uploader.index.status(id, fingerprint: try SessionUploadIdentity.fingerprint(root)), .error)
    }

    @MainActor func testSizeFailureIsDurableAndTaskCancellationIsTerminal() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let id = UUID()
        let manifest = SessionCapture.Manifest(sessionID: id, startedAt: Date(), intervalSeconds: 1)
        try JSONEncoder().encode(manifest).write(to: root.appendingPathComponent("session.json"))
        let uploader = try SessionUploader(indexURL: root.appendingPathComponent("index.json"))
        do {
            try await uploader.send(root, id: id, serverURL: self.serverURL, token: String(repeating: "a", count: 43), permitted: { true }, maximumBytes: 1)
            XCTFail("oversize sent")
        } catch {}
        let fingerprint = try SessionUploadIdentity.fingerprint(root)
        XCTAssertEqual(uploader.index.status(id, fingerprint: fingerprint), .error)
        let started = expectation(description: "transport started")
        let task = Task {
            try await uploader.send(root, id: id, serverURL: self.serverURL, token: String(repeating: "a", count: 43), permitted: { true }) { _, _ in
                started.fulfill()
                try await Task.sleep(nanoseconds: 30_000_000_000)
                return (Data(), 200)
            }
        }
        await fulfillment(of: [started], timeout: 3)
        task.cancel()
        do { try await task.value; XCTFail("cancel accepted") } catch {}
        XCTAssertFalse(uploader.isUploading)
        XCTAssertEqual(uploader.index.status(id, fingerprint: fingerprint), .error)
    }

    func testFingerprintIncludesNameAndPixels() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        var manifest = SessionCapture.Manifest(sessionID: UUID(), startedAt: Date(), intervalSeconds: 1)
        manifest.frames = [SessionCapture.Frame(filename: "frame_000001.jpg", ptsValue: 1, ptsTimescale: 1, ptsEpoch: 0, ptsFlags: 1, orientation: nil, width: 1, height: 1, modelVersion: nil, predictions: nil)]
        try JSONEncoder().encode(manifest).write(to: root.appendingPathComponent("session.json"))
        try Data([1]).write(to: root.appendingPathComponent("frame_000001.jpg"))
        let first = try SessionUploadIdentity.fingerprint(root)
        XCTAssertEqual(first, try SessionUploadIdentity.fingerprint(root))
        try SessionCaptureName.rename(in: root, to: "Name")
        let named = try SessionUploadIdentity.fingerprint(root)
        XCTAssertNotEqual(first, named)
        try Data([2]).write(to: root.appendingPathComponent("frame_000001.jpg"))
        XCTAssertNotEqual(named, try SessionUploadIdentity.fingerprint(root))
    }

    private func batchItem(in root: URL) throws -> SessionUploader.Item {
        let id = UUID()
        let directory = root.appendingPathComponent(id.uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let manifest = SessionCapture.Manifest(sessionID: id, startedAt: Date(), intervalSeconds: 1)
        try JSONEncoder().encode(manifest).write(to: directory.appendingPathComponent("session.json"))
        return SessionUploader.Item(directory: directory, id: id)
    }

    private func acceptedReceipt(id: UUID, archive: URL) throws -> (Data, Int) {
        let digest = try SessionUploadIdentity.hash(archive)
        return (Data("{\"accepted\":true,\"receiptVersion\":1,\"archiveSHA256\":\"\(digest)\",\"sessionID\":\"\(id)\",\"added\":0,\"duplicates\":0}".utf8), 200)
    }

    @MainActor func testBatchSkipsAcceptedContinuesAfterFailureAndRetriesOnlyUnsent() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let items = try (0..<3).map { _ in try batchItem(in: root) }
        let uploader = try SessionUploader(indexURL: root.appendingPathComponent("index.json"))
        try uploader.index.set(items[0].id, fingerprint: SessionUploadIdentity.fingerprint(items[0].directory), state: .accepted)
        var calls: [UUID] = []
        try await uploader.sendAll(items, serverURL: serverURL, token: String(repeating: "a", count: 43), permitted: { true }) { _, archive in
            let id = try XCTUnwrap(uploader.uploadingID)
            calls.append(id)
            if id == items[1].id { return (Data(), 409) }
            return try self.acceptedReceipt(id: id, archive: archive)
        }
        XCTAssertEqual(calls, [items[1].id, items[2].id])
        XCTAssertEqual(uploader.batchProgress?.sent, 1)
        XCTAssertEqual(uploader.batchProgress?.skipped, 1)
        XCTAssertEqual(uploader.batchProgress?.failures.count, 1)
        XCTAssertEqual(uploader.batchProgress?.completed, 3)
        XCTAssertFalse(uploader.isUploading)
        calls = []
        try await uploader.sendAll(items, serverURL: serverURL, token: String(repeating: "a", count: 43), permitted: { true }) { _, archive in
            let id = try XCTUnwrap(uploader.uploadingID)
            calls.append(id)
            return try self.acceptedReceipt(id: id, archive: archive)
        }
        XCTAssertEqual(calls, [items[1].id])
        XCTAssertEqual(uploader.batchProgress?.skipped, 2)
        XCTAssertEqual(uploader.batchProgress?.failures.count, 0)
        try SessionCaptureName.rename(in: items[0].directory, to: "Changed")
        calls = []
        try await uploader.sendAll(items, serverURL: serverURL, token: String(repeating: "a", count: 43), permitted: { true }) { _, archive in
            let id = try XCTUnwrap(uploader.uploadingID)
            calls.append(id)
            return try self.acceptedReceipt(id: id, archive: archive)
        }
        XCTAssertEqual(calls, [items[0].id], "Skip decisions must use fresh fingerprints")
    }

    @MainActor func testBatchCancellationStopsQueueAndExcludesConcurrentUploads() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let items = try (0..<2).map { _ in try batchItem(in: root) }
        let uploader = try SessionUploader(indexURL: root.appendingPathComponent("index.json"))
        let started = expectation(description: "first upload started")
        var calls = 0
        let task = Task {
            try await uploader.sendAll(items, serverURL: serverURL, token: String(repeating: "a", count: 43), permitted: { true }) { _, _ in
                calls += 1
                started.fulfill()
                try await Task.sleep(nanoseconds: 30_000_000_000)
                return (Data(), 200)
            }
        }
        await fulfillment(of: [started], timeout: 3)
        do {
            try await uploader.sendAll(items, serverURL: serverURL, token: String(repeating: "a", count: 43), permitted: { true })
            XCTFail("Concurrent batch allowed")
        } catch SessionUploadError.busy {} catch { XCTFail("Unexpected error: \(error)") }
        task.cancel()
        do { try await task.value; XCTFail("Cancellation ignored") } catch is CancellationError {}
        XCTAssertEqual(calls, 1)
        XCTAssertFalse(uploader.isUploading)
        XCTAssertNil(uploader.uploadingID)
        XCTAssertNil(uploader.transferProgress)
        XCTAssertEqual(uploader.batchProgress?.completed, 0)
        XCTAssertNil(uploader.index.entries[items[1].id.uuidString])
    }

    @MainActor func testBatchAuthenticationFailureStopsRemainingSessions() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let items = try (0..<2).map { _ in try batchItem(in: root) }
        let uploader = try SessionUploader(indexURL: root.appendingPathComponent("index.json"))
        var calls = 0
        do {
            try await uploader.sendAll(items, serverURL: serverURL, token: String(repeating: "a", count: 43), permitted: { true }) { _, _ in
                calls += 1
                return (Data(), 401)
            }
            XCTFail("Authentication failure ignored")
        } catch SessionUploadError.http(401) {} catch { XCTFail("Unexpected error: \(error)") }
        XCTAssertEqual(calls, 1)
        XCTAssertFalse(uploader.isUploading)
        XCTAssertNil(uploader.index.entries[items[1].id.uuidString])
    }
}
#endif
