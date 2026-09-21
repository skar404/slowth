#if DEBUG
import Foundation

enum SessionUploadState: String, Codable {
    case notSent, uploading, accepted, error

    var isSentPresentation: Bool { self == .accepted }
}

@MainActor final class SessionUploadIndex {
    struct Entry: Codable {
        let fingerprint: String
        var state: SessionUploadState
        var archiveSHA256: String?
    }
    private let url: URL
    private(set) var entries: [String: Entry]
    init(url: URL) throws {
        self.url = url
        if FileManager.default.fileExists(atPath: url.path) {
            entries = try JSONDecoder().decode([String: Entry].self, from: Data(contentsOf: url))
        } else { entries = [:] }
        for key in entries.keys where entries[key]?.state == .uploading { entries[key]?.state = .error }
        try persist(entries)
    }
    func status(_ id: UUID, fingerprint: String) -> SessionUploadState {
        guard let entry = entries[id.uuidString], entry.fingerprint == fingerprint else { return .notSent }
        return entry.state
    }
    func set(_ id: UUID, fingerprint: String, state: SessionUploadState, archiveSHA256: String? = nil) throws {
        var updated = entries
        updated[id.uuidString] = Entry(fingerprint: fingerprint, state: state, archiveSHA256: archiveSHA256)
        do { try persist(updated) }
        catch {
            // A failed terminal write must not leave the running UI stuck in uploading.
            // The persisted uploading record becomes error when reopened. Never fake acceptance.
            if state == .error { entries = updated }
            throw error
        }
        entries = updated
    }
    private func persist(_ value: [String: Entry]) throws {
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try JSONEncoder().encode(value).write(to: url, options: .atomic)
    }
}

struct SessionUploadReceipt: Decodable {
    let accepted: Bool
    let receiptVersion: Int
    let archiveSHA256: String
    let sessionID: UUID
    let added: Int
    let duplicates: Int
    static func validate(_ data: Data, status: Int, id: UUID, digest: String, frames: Int) throws {
        guard status == 200, data.count <= 65536 else { throw SessionUploadError.http(status) }
        let receipt = try JSONDecoder().decode(Self.self, from: data)
        guard receipt.accepted, receipt.receiptVersion == 1, receipt.sessionID == id,
              receipt.archiveSHA256 == digest, receipt.added >= 0, receipt.duplicates >= 0,
              (receipt.added == frames && receipt.duplicates == 0) ||
              (receipt.added == 0 && receipt.duplicates == frames) else { throw SessionUploadError.receipt }
    }
}

enum SessionUploadError: LocalizedError {
    case http(Int), receipt, permission, busy, size
    var errorDescription: String? {
        switch self {
        case .http(409): return "This recording UUID already has a different snapshot on the server. Nothing was overwritten. Review it in the labeler; do not change the UUID to bypass this conflict."
        case .http(401): return "Authentication failed. Configure the private labeler credential again."
        case .http(let status): return "Upload was not accepted (HTTP \(status)). Retry manually."
        case .receipt: return "Invalid acceptance receipt. Acceptance is unknown; retry manually."
        case .permission: return "Unlock Debug and configure the private labeler credential first."
        case .busy: return "Another upload is in progress."
        case .size: return "Snapshot exceeds 260 MiB or is empty. Use local export instead."
        }
    }
}
#endif
