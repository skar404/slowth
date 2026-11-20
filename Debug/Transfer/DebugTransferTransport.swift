#if DEBUG
import Foundation

struct DebugTransferResponse {
    let status: Int
    let headers: [String: String]
    let data: Data
    init(status: Int, headers: [String: String] = [:], data: Data = Data()) {
        self.status = status
        self.headers = Dictionary(headers.map { ($0.key.lowercased(), $0.value) }, uniquingKeysWith: { _, new in new })
        self.data = data
    }
}

private final class DebugTransferDelegate: NSObject, URLSessionTaskDelegate {
    private let lock = NSLock()
    private var callback: @Sendable (Double) -> Void = { _ in }
    func progress(_ callback: @escaping @Sendable (Double) -> Void) {
        lock.lock(); self.callback = callback; lock.unlock()
    }
    func urlSession(_ session: URLSession, task: URLSessionTask, didSendBodyData bytesSent: Int64,
                    totalBytesSent: Int64, totalBytesExpectedToSend: Int64) {
        guard totalBytesExpectedToSend > 0 else { return }
        lock.lock(); let callback = callback; lock.unlock()
        callback(min(1, Double(totalBytesSent) / Double(totalBytesExpectedToSend)))
    }
    func urlSession(_ session: URLSession, task: URLSessionTask,
                    willPerformHTTPRedirection response: HTTPURLResponse, newRequest request: URLRequest,
                    completionHandler: @escaping (URLRequest?) -> Void) { completionHandler(nil) }
}

/// One connection pool per queued snapshot. No cookies, implicit credentials or redirects.
final class DebugTransferNetwork {
    private let delegate = DebugTransferDelegate()
    private let session: URLSession
    init() {
        let config = URLSessionConfiguration.ephemeral
        config.httpCookieStorage = nil; config.urlCredentialStorage = nil; config.urlCache = nil
        config.timeoutIntervalForResource = 600
        session = URLSession(configuration: config, delegate: delegate, delegateQueue: nil)
    }
    deinit { session.invalidateAndCancel() }
    func execute(_ request: URLRequest, file: URL?, progress: @escaping @Sendable (Double) -> Void) async throws -> DebugTransferResponse {
        delegate.progress(progress)
        let data: Data; let response: URLResponse
        if let file { (data, response) = try await session.upload(for: request, fromFile: file) }
        else { (data, response) = try await session.data(for: request) }
        guard let http = response as? HTTPURLResponse else { throw DebugTransferError.verification }
        let headers = Dictionary(http.allHeaderFields.map { (String(describing: $0.key).lowercased(), String(describing: $0.value)) }, uniquingKeysWith: { _, new in new })
        return DebugTransferResponse(status: http.statusCode, headers: headers, data: data)
    }
}

enum DebugTransferTransport {
    typealias Execute = (URLRequest, URL?, @escaping @Sendable (Double) -> Void) async throws -> DebugTransferResponse
    struct Progress: Sendable {
        let completed: Int
        let total: Int
        let fraction: Double
    }
    static func send(snapshot: DebugTransferSnapshot, directory: URL, profile input: DebugTransferProfile,
                     secret: DebugTransferSecret?, execute: Execute,
                     progress: @escaping @Sendable (Progress) -> Void) async throws {
        let profile = try input.validated()
        if profile.transport == .s3 {
            guard let secret else { throw DebugTransferError.missingCredentials }
            try secret.validate()
        }
        // Validate the durable snapshot immediately before sending it.
        let validation = Task.detached(priority: .utility) { try snapshot.validate(at: directory) }
        try await withTaskCancellationHandler(operation: { try await validation.value }, onCancel: { validation.cancel() })
        let markerURL = directory.appendingPathComponent("COMPLETE.json")
        let digest = try DebugTransferDigest.file(markerURL)
        let marker = DebugTransferFile(name: "COMPLETE.json", size: digest.size, sha256: digest.sha256, md5: digest.md5, contentType: "application/json")
        let files = snapshot.inventory.files + [marker]
        let totalBytes = max(1, files.reduce(Int64(0)) { $0 + $1.size })
        var verifiedBytes: Int64 = 0
        for (index, file) in files.enumerated() {
            try Task.checkCancellation()
            let isMarker = file.name == "COMPLETE.json"
            let url: URL
            if profile.transport == .s3 {
                url = try DebugS3Signer.objectURL(profile: profile, key: snapshot.objectPrefix + "/" + file.name)
            } else {
                guard let base = URL(string: profile.endpoint) else { throw DebugTransferError.invalidProfile }
                let route = "v1/recordings/" + snapshot.objectPrefix + (isMarker ? "/complete" : "/files/" + file.name)
                url = base.appendingPathComponent(route)
            }
            func request(_ method: String) throws -> URLRequest {
                var request = URLRequest(url: url)
                request.httpMethod = method; request.timeoutInterval = 120
                if method == "PUT" {
                    request.setValue(file.contentType, forHTTPHeaderField: "Content-Type")
                    request.setValue(String(file.size), forHTTPHeaderField: "Content-Length")
                    request.setValue(file.md5, forHTTPHeaderField: "Content-MD5")
                    request.setValue(file.sha256, forHTTPHeaderField: profile.transport == .s3 ? "x-amz-meta-sha256" : "X-Content-SHA256")
                }
                if profile.transport == .s3, let secret {
                    return try DebugS3Signer.sign(request, region: profile.region, secret: secret,
                        payloadHash: method == "PUT" ? file.sha256 : DebugTransferDigest.hex(Data()))
                }
                return request
            }
            func matches(_ response: DebugTransferResponse) -> Bool {
                response.status == 200 && Int64(response.headers["content-length"] ?? "") == file.size &&
                    response.headers[profile.transport == .s3 ? "x-amz-meta-sha256" : "x-content-sha256"] == file.sha256
            }
            let head = try await execute(request("HEAD"), nil, { _ in })
            if head.status == 200 {
                guard matches(head) else { throw DebugTransferError.verification }
            } else {
                guard head.status == 404 else { throw DebugTransferError.http(head.status) }
                let baseBytes = verifiedBytes
                let response = try await execute(request("PUT"), directory.appendingPathComponent(file.name)) { fraction in
                    progress(.init(completed: index, total: files.count,
                        fraction: min(0.99, (Double(baseBytes) + Double(file.size) * fraction) / Double(totalBytes))))
                }
                guard (200...299).contains(response.status) else { throw DebugTransferError.http(response.status) }
                if profile.transport == .http, isMarker {
                    struct Receipt: Decodable { let accepted: Bool; let snapshotID: String }
                    guard response.data.count <= 65536,
                          let receipt = try? JSONDecoder().decode(Receipt.self, from: response.data),
                          receipt.accepted, receipt.snapshotID == snapshot.id else { throw DebugTransferError.verification }
                }
                let verification = try await execute(request("HEAD"), nil, { _ in })
                guard matches(verification) else { throw DebugTransferError.verification }
            }
            verifiedBytes += file.size
            progress(.init(completed: index + 1, total: files.count, fraction: Double(verifiedBytes) / Double(totalBytes)))
        }
    }
}
#endif
