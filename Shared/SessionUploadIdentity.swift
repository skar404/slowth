#if DEBUG
import Foundation
import CryptoKit

enum SessionUploadIdentity {
    static let maximumBytes = 260 * 1024 * 1024
    static func hash(_ file: URL) throws -> String {
        let handle = try FileHandle(forReadingFrom: file)
        defer { try? handle.close() }
        var hash = SHA256()
        while let chunk = try handle.read(upToCount: 1024 * 1024), !chunk.isEmpty {
            try Task.checkCancellation()
            hash.update(data: chunk)
        }
        return hash.finalize().map { String(format: "%02x", $0) }.joined()
    }

    /// Raw manifest + raw sidecar + ordered filename/pixel digests, not ZIP timestamps.
    static func fingerprint(_ directory: URL) throws -> String {
        let manifestURL = directory.appendingPathComponent("session.json")
        let manifestData = try Data(contentsOf: manifestURL)
        let manifest = try JSONDecoder().decode(SessionCapture.Manifest.self, from: manifestData)
        let manifestHash = SHA256.hash(data: manifestData).map { String(format: "%02x", $0) }.joined()
        var parts = ["slowth-snapshot-v1", manifestHash]
        let nameURL = directory.appendingPathComponent(SessionCaptureName.filename)
        parts.append(FileManager.default.fileExists(atPath: nameURL.path) ? try hash(nameURL) : "absent")
        for frame in manifest.frames {
            guard frame.filename == URL(fileURLWithPath: frame.filename).lastPathComponent,
                  frame.filename.hasPrefix("frame_"), frame.filename.hasSuffix(".jpg") else {
                throw CocoaError(.fileReadCorruptFile)
            }
            parts += [frame.filename, try hash(directory.appendingPathComponent(frame.filename))]
        }
        return SHA256.hash(data: Data(parts.joined(separator: "\n").utf8)).map { String(format: "%02x", $0) }.joined()
    }
}
#endif
