#if DEBUG
import Foundation
import Combine

private final class SessionUploadRedirectGuard: NSObject, URLSessionTaskDelegate {
    func urlSession(_ session: URLSession, task: URLSessionTask,
                    willPerformHTTPRedirection response: HTTPURLResponse, newRequest request: URLRequest,
                    completionHandler: @escaping (URLRequest?) -> Void) { completionHandler(nil) }
}

@MainActor final class SessionUploader: ObservableObject {
    static let endpoint = URL(string: "https://quick-draws:8443/api/native/import-session")!
    let index: SessionUploadIndex
    @Published private(set) var isUploading = false
    @Published private(set) var uploadingID: UUID?
    @Published private(set) var revision = 0
    init(indexURL: URL) throws { index = try SessionUploadIndex(url: indexURL) }

    typealias Transport = (URLRequest, URL) async throws -> (Data, Int)
    func send(_ directory: URL, id: UUID, token: String, permitted: () -> Bool,
              maximumBytes: Int = SessionUploadIdentity.maximumBytes, transport: Transport? = nil) async throws {
        guard !isUploading else { throw SessionUploadError.busy }
        guard permitted(), token.range(of: "^[A-Za-z0-9_-]{43,128}$", options: .regularExpression) != nil else {
            throw SessionUploadError.permission
        }
        isUploading = true
        uploadingID = id
        defer { isUploading = false; uploadingID = nil; revision += 1 }
        let archive = FileManager.default.temporaryDirectory.appendingPathComponent("slowth-upload-\(UUID()).zip")
        defer { try? FileManager.default.removeItem(at: archive) }
        var fingerprint: String?
        do {
            let initial = Task.detached(priority: .utility) { try SessionUploadIdentity.fingerprint(directory) }
            let initialFingerprint = try await withTaskCancellationHandler(operation: { try await initial.value },
                                                                            onCancel: { initial.cancel() })
            fingerprint = initialFingerprint
            try Task.checkCancellation()
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
            var request = URLRequest(url: Self.endpoint)
            request.httpMethod = "POST"
            request.timeoutInterval = 120
            request.setValue("application/zip", forHTTPHeaderField: "Content-Type")
            request.setValue(String(prepared.3), forHTTPHeaderField: "Content-Length")
            request.setValue("Bearer " + token, forHTTPHeaderField: "Authorization")
            request.setValue(prepared.1, forHTTPHeaderField: "X-Archive-SHA256")
            let result: (Data, Int)
            if let transport { result = try await transport(request, archive) }
            else {
                let config = URLSessionConfiguration.ephemeral
                config.httpCookieStorage = nil
                config.urlCredentialStorage = nil
                config.urlCache = nil
                config.timeoutIntervalForResource = 180
                let session = URLSession(configuration: config, delegate: SessionUploadRedirectGuard(), delegateQueue: nil)
                defer { session.invalidateAndCancel() }
                let (data, response) = try await session.upload(for: request, fromFile: archive)
                result = (data, (response as? HTTPURLResponse)?.statusCode ?? 0)
            }
            try Task.checkCancellation()
            try SessionUploadReceipt.validate(result.0, status: result.1, id: id, digest: prepared.1, frames: prepared.2)
            try index.set(id, fingerprint: prepared.0, state: .accepted, archiveSHA256: prepared.1)
        } catch {
            if let fingerprint { try? index.set(id, fingerprint: fingerprint, state: .error) }
            throw error
        }
    }
}
#endif
