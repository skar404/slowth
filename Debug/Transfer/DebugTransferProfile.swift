#if DEBUG
import Foundation
import CryptoKit

enum DebugTransferError: LocalizedError {
    case invalidProfile, invalidLink, missingCredentials, invalidSnapshot, verification, http(Int), busy
    var errorDescription: String? {
        switch self {
        case .invalidProfile: return "Check the connection name, endpoint and transport settings."
        case .invalidLink: return "This is not a valid Slowth transfer link (version 1)."
        case .missingCredentials: return "Save the S3 credentials again in Connections."
        case .invalidSnapshot: return "The recording snapshot is missing, changed or invalid. Local originals remain."
        case .verification: return "The receiver did not confirm these exact files. Retry the transfer."
        case .http(let code): return "Transfer failed (HTTP \(code)). Check the connection and retry."
        case .busy: return "A transfer operation is already running."
        }
    }
}

struct DebugTransferSecret: Codable, Equatable, Sendable {
    var accessKeyID: String
    var secretAccessKey: String
    var sessionToken: String?
    func validate() throws {
        for value in [accessKeyID, secretAccessKey] + (sessionToken.map { [$0] } ?? []) {
            guard !value.isEmpty, value.utf8.count <= 4096,
                  value.unicodeScalars.allSatisfy({ $0.value >= 33 && $0.value <= 126 }) else {
                throw DebugTransferError.missingCredentials
            }
        }
    }
}

struct DebugTransferProfile: Codable, Identifiable, Equatable, Sendable {
    enum Transport: String, Codable, CaseIterable { case http, s3 }
    var id = UUID()
    var name: String
    var transport: Transport
    var endpoint: String
    var region = ""
    var bucket = ""
    var prefix = ""

    var destination: String {
        transport == .http ? endpoint : "\(endpoint)/\(bucket)" + (prefix.isEmpty ? "" : "/\(prefix)")
    }
    /// Destination identity deliberately excludes UI name and credentials.
    var destinationID: String {
        DebugTransferDigest.hex(Data([transport.rawValue, endpoint, region, bucket, prefix].joined(separator: "\n").utf8))
    }
    func validated() throws -> Self {
        var result = self
        result.name = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !result.name.isEmpty, result.name.count <= 80,
              !result.name.unicodeScalars.contains(where: CharacterSet.controlCharacters.contains),
              var url = URLComponents(string: endpoint.trimmingCharacters(in: .whitespacesAndNewlines)),
              let scheme = url.scheme?.lowercased(), let host = url.host?.lowercased(), !host.isEmpty,
              url.user == nil, url.password == nil, url.query == nil, url.fragment == nil,
              url.port.map({ (1...65535).contains($0) }) ?? true else { throw DebugTransferError.invalidProfile }
        guard scheme == "https" || (transport == .http && scheme == "http" && Self.isLocalHost(host)) else {
            throw DebugTransferError.invalidProfile
        }
        guard !url.path.split(separator: "/").contains(where: { $0 == "." || $0 == ".." }),
              !url.path.contains("\\"), !url.path.unicodeScalars.contains(where: CharacterSet.controlCharacters.contains) else {
            throw DebugTransferError.invalidProfile
        }
        url.scheme = scheme; url.host = host
        if url.port == (scheme == "https" ? 443 : 80) { url.port = nil }
        while url.path.hasSuffix("/") { url.path.removeLast() }
        guard let normalized = url.url else { throw DebugTransferError.invalidProfile }
        result.endpoint = normalized.absoluteString
        if transport == .s3 {
            guard region.range(of: "^[a-z0-9-]{1,64}$", options: .regularExpression) != nil,
                  bucket.range(of: "^[a-z0-9][a-z0-9.-]{1,61}[a-z0-9]$", options: .regularExpression) != nil,
                  !bucket.contains(".."), prefix.utf8.count <= 256,
                  !prefix.contains("\\"), !prefix.unicodeScalars.contains(where: CharacterSet.controlCharacters.contains),
                  !prefix.split(separator: "/").contains(where: { $0 == "." || $0 == ".." }) else {
                throw DebugTransferError.invalidProfile
            }
            result.prefix = prefix.trimmingCharacters(in: CharacterSet(charactersIn: "/"))
        } else { result.region = ""; result.bucket = ""; result.prefix = "" }
        return result
    }
    static func isLocalHost(_ value: String) -> Bool {
        let host = value.trimmingCharacters(in: CharacterSet(charactersIn: "[]")).lowercased()
        if host == "localhost" || host == "::1" || host.hasSuffix(".local") { return true }
        if host.contains(":"), host.hasPrefix("fc") || host.hasPrefix("fd") || host.hasPrefix("fe80:") { return true }
        let parts = host.split(separator: ".", omittingEmptySubsequences: false)
        let numbers = parts.compactMap { Int($0) }
        guard parts.count == 4, numbers.count == 4,
              zip(parts, numbers).allSatisfy({ String($1) == $0 && (0...255).contains($1) }) else { return false }
        return numbers[0] == 10 || numbers[0] == 127 ||
            (numbers[0] == 192 && numbers[1] == 168) ||
            (numbers[0] == 172 && (16...31).contains(numbers[1])) ||
            (numbers[0] == 100 && (64...127).contains(numbers[1])) ||
            (numbers[0] == 169 && numbers[1] == 254)
    }
}

/// Only the import draft contains secrets. Persistent profiles never contain them.
struct DebugTransferLink: Codable, Identifiable {
    var id: UUID { profile.id }
    let version: Int
    var profile: DebugTransferProfile
    var credentials: DebugTransferSecret?
    static func parse(_ url: URL) throws -> Self {
        guard url.absoluteString.utf8.count <= 12288, let c = URLComponents(url: url, resolvingAgainstBaseURL: false),
              c.scheme == "slowth", c.host == "debug-transfer", c.path.isEmpty,
              c.user == nil, c.password == nil, c.port == nil, c.query == nil,
              let fragment = c.fragment, fragment.hasPrefix("config=") else { throw DebugTransferError.invalidLink }
        let value = String(fragment.dropFirst(7))
        guard value.range(of: "^[A-Za-z0-9_-]+$", options: .regularExpression) != nil else { throw DebugTransferError.invalidLink }
        var base64 = value.replacingOccurrences(of: "-", with: "+").replacingOccurrences(of: "_", with: "/")
        base64 += String(repeating: "=", count: (4 - base64.count % 4) % 4)
        do {
            guard let data = Data(base64Encoded: base64) else { throw DebugTransferError.invalidLink }
            var link = try JSONDecoder().decode(Self.self, from: data)
            guard link.version == 1 else { throw DebugTransferError.invalidLink }
            link.profile = try link.profile.validated()
            // Imported UUIDs cannot select or replace an existing Keychain entry.
            link.profile.id = UUID()
            if link.profile.transport == .s3 {
                guard let credentials = link.credentials else { throw DebugTransferError.missingCredentials }
                try credentials.validate()
            } else if link.credentials != nil { throw DebugTransferError.invalidLink }
            return link
        } catch { throw DebugTransferError.invalidLink }
    }
}

enum DebugTransferDigest {
    static func hex(_ data: Data) -> String { SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined() }
    static func file(_ url: URL) throws -> (sha256: String, md5: String, size: Int64) {
        let handle = try FileHandle(forReadingFrom: url)
        defer { try? handle.close() }
        var sha = SHA256(); var md5 = Insecure.MD5(); var size: Int64 = 0
        while let chunk = try handle.read(upToCount: 1_048_576), !chunk.isEmpty {
            try Task.checkCancellation()
            sha.update(data: chunk); md5.update(data: chunk); size += Int64(chunk.count)
        }
        return (sha.finalize().map { String(format: "%02x", $0) }.joined(), Data(md5.finalize()).base64EncodedString(), size)
    }
}
#endif
