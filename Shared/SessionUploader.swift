#if DEBUG
import Foundation
import Combine

enum SessionUploadServer {
    static let storageKey = "privateSessionUpload.serverURL"

    static func url(from value: String) throws -> URL {
        guard var components = URLComponents(string: value.trimmingCharacters(in: .whitespacesAndNewlines)),
              components.scheme?.lowercased() == "https",
              let host = components.host, !host.isEmpty,
              components.user == nil, components.password == nil,
              components.query == nil, components.fragment == nil,
              components.port.map({ (1...65535).contains($0) }) ?? true else {
            throw SessionUploadError.serverURL
        }
        components.scheme = "https"
        components.host = host.lowercased()
        if components.port == 443 { components.port = nil }
        while components.path.hasSuffix("/") { components.path.removeLast() }
        guard let url = components.url else { throw SessionUploadError.serverURL }
        return url
    }
}

private final class SessionUploadRedirectGuard: NSObject, URLSessionTaskDelegate {
    let progress: @Sendable (Double) -> Void
    init(progress: @escaping @Sendable (Double) -> Void) { self.progress = progress }
    func urlSession(_ session: URLSession, task: URLSessionTask, didSendBodyData bytesSent: Int64,
                    totalBytesSent: Int64, totalBytesExpectedToSend: Int64) {
        guard totalBytesExpectedToSend > 0 else { return }
        progress(min(1, Double(totalBytesSent) / Double(totalBytesExpectedToSend)))
    }
    func urlSession(_ session: URLSession, task: URLSessionTask,
                    willPerformHTTPRedirection response: HTTPURLResponse, newRequest request: URLRequest,
                    completionHandler: @escaping (URLRequest?) -> Void) { completionHandler(nil) }
}

@MainActor final class SessionUploader: ObservableObject {
    struct Item {
        let directory: URL
        let id: UUID
    }
    struct BatchProgress {
        let total: Int
        var sent = 0
        var skipped = 0
        var failures: [String] = []
        var completed: Int { sent + skipped + failures.count }
    }
    let index: SessionUploadIndex
    @Published private(set) var isUploading = false
    @Published private(set) var uploadingID: UUID?
    @Published private(set) var revision = 0
    @Published private(set) var transferProgress: Double?
    @Published private(set) var batchProgress: BatchProgress?
    init(indexURL: URL) throws { index = try SessionUploadIndex(url: indexURL) }

    typealias Transport = (URLRequest, URL) async throws -> (Data, Int)
    func send(_ directory: URL, id: UUID, serverURL: URL, token: String, permitted: () -> Bool,
              maximumBytes: Int = SessionUploadIdentity.maximumBytes, transport: Transport? = nil) async throws {
        guard !isUploading else { throw SessionUploadError.busy }
        batchProgress = nil
        isUploading = true
        defer { isUploading = false }
        _ = try await performSend(directory, id: id, serverURL: serverURL, token: token, permitted: permitted,
                                 maximumBytes: maximumBytes, transport: transport, skipAccepted: false)
    }

    func sendAll(_ items: [Item], serverURL: URL, token: String, permitted: () -> Bool,
                 transport: Transport? = nil) async throws {
        guard !isUploading else { throw SessionUploadError.busy }
        isUploading = true
        batchProgress = BatchProgress(total: items.count)
        defer { isUploading = false }
        for item in items {
            try Task.checkCancellation()
            do {
                let sent = try await performSend(item.directory, id: item.id, serverURL: serverURL, token: token,
                                                permitted: permitted, maximumBytes: SessionUploadIdentity.maximumBytes,
                                                transport: transport, skipAccepted: true)
                if sent { batchProgress?.sent += 1 } else { batchProgress?.skipped += 1 }
            } catch {
                if Task.isCancelled || error is CancellationError { throw CancellationError() }
                // Connection/authorization errors affect the entire queue; local failures do not.
                if let failure = error as? SessionUploadError {
                    switch failure {
                    case .permission, .serverURL, .http(401): throw failure
                    default: break
                    }
                }
                if error is URLError { throw error }
                batchProgress?.failures.append("\(item.id.uuidString): \(error.localizedDescription)")
            }
        }
    }

    private func performSend(_ directory: URL, id: UUID, serverURL: URL, token: String, permitted: () -> Bool,
                             maximumBytes: Int, transport: Transport?, skipAccepted: Bool) async throws -> Bool {
        let endpoint = try SessionUploadServer.url(from: serverURL.absoluteString)
            .appendingPathComponent("api/native/import-session")
        guard permitted(), token.range(of: "^[A-Za-z0-9_-]{43,128}$", options: .regularExpression) != nil else {
            throw SessionUploadError.permission
        }
        uploadingID = id
        transferProgress = nil
        defer { uploadingID = nil; transferProgress = nil; revision += 1 }
        let archive = FileManager.default.temporaryDirectory.appendingPathComponent("slowth-upload-\(UUID()).zip")
        defer { try? FileManager.default.removeItem(at: archive) }
        var fingerprint: String?
        do {
            let initial = Task.detached(priority: .utility) { try SessionUploadIdentity.fingerprint(directory) }
            let initialFingerprint = try await withTaskCancellationHandler(operation: { try await initial.value },
                                                                            onCancel: { initial.cancel() })
            fingerprint = initialFingerprint
            try Task.checkCancellation()
            if skipAccepted, index.status(id, fingerprint: initialFingerprint) == .accepted { return false }
            try index.set(id, fingerprint: initialFingerprint, state: .uploading)
            revision += 1
            let preparation = Task.detached(priority: .utility) { () -> (String, String, Int, Int) in
                var identity = ""
                var count = 0
                _ = try SessionCaptureArchive.export(directory, to: archive) { snapshot in
                    identity = try SessionUploadIdentity.fingerprint(snapshot)
                    let manifest = try JSONDecoder().decode(SessionCapture.Manifest.self,
                        from: Data(contentsOf: snapshot.appendingPathComponent("session.json")))
                    guard manifest.sessionID == id else { throw SessionUploadError.receipt }
                    count = manifest.frames.count
                }
                try Task.checkCancellation()
                let size = try archive.resourceValues(forKeys: [.fileSizeKey]).fileSize ?? 0
                guard size > 0, size <= min(maximumBytes, SessionUploadIdentity.maximumBytes) else { throw SessionUploadError.size }
                return (identity, try SessionUploadIdentity.hash(archive), count, size)
            }
            let prepared = try await withTaskCancellationHandler(operation: { try await preparation.value },
                                                                  onCancel: { preparation.cancel() })
            fingerprint = prepared.0
            try Task.checkCancellation()
            guard permitted() else { throw SessionUploadError.permission }
            try index.set(id, fingerprint: prepared.0, state: .uploading, archiveSHA256: prepared.1)
            revision += 1
            var request = URLRequest(url: endpoint)
            request.httpMethod = "POST"
            request.timeoutInterval = 120
            request.setValue("application/zip", forHTTPHeaderField: "Content-Type")
            request.setValue(String(prepared.3), forHTTPHeaderField: "Content-Length")
            request.setValue("Bearer " + token, forHTTPHeaderField: "Authorization")
            request.setValue(prepared.1, forHTTPHeaderField: "X-Archive-SHA256")
            transferProgress = 0
            let result: (Data, Int)
            if let transport { result = try await transport(request, archive) }
            else {
                let config = URLSessionConfiguration.ephemeral
                config.httpCookieStorage = nil
                config.urlCredentialStorage = nil
                config.urlCache = nil
                config.timeoutIntervalForResource = 180
                let delegate = SessionUploadRedirectGuard { [weak self] fraction in
                    Task { @MainActor [weak self] in
                        guard let self, self.uploadingID == id, self.transferProgress != nil else { return }
                        self.transferProgress = max(self.transferProgress ?? 0, fraction)
                    }
                }
                let session = URLSession(configuration: config, delegate: delegate, delegateQueue: nil)
                defer { session.invalidateAndCancel() }
                let (data, response) = try await session.upload(for: request, fromFile: archive)
                result = (data, (response as? HTTPURLResponse)?.statusCode ?? 0)
            }
            try Task.checkCancellation()
            try SessionUploadReceipt.validate(result.0, status: result.1, id: id, digest: prepared.1, frames: prepared.2)
            try index.set(id, fingerprint: prepared.0, state: .accepted, archiveSHA256: prepared.1)
            return true
        } catch {
            if let fingerprint { try? index.set(id, fingerprint: fingerprint, state: .error) }
            throw error
        }
    }
}
#endif
