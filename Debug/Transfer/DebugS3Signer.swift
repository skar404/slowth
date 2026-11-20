#if DEBUG
import Foundation
import CryptoKit

enum DebugS3Signer {
    static func encode(_ path: String) -> String {
        path.utf8.map { byte in
            if (65...90).contains(byte) || (97...122).contains(byte) || (48...57).contains(byte) || [45, 46, 95, 126, 47].contains(byte) {
                return String(UnicodeScalar(byte))
            }
            return String(format: "%%%02X", byte)
        }.joined()
    }
    static func objectURL(profile: DebugTransferProfile, key: String) throws -> URL {
        guard var c = URLComponents(string: profile.endpoint) else { throw DebugTransferError.invalidProfile }
        let path = c.path + "/" + profile.bucket + "/" + (profile.prefix.isEmpty ? "" : profile.prefix + "/") + key
        c.percentEncodedPath = encode(path)
        guard let url = c.url else { throw DebugTransferError.invalidProfile }
        return url
    }
    static func sign(_ request: URLRequest, region: String, secret: DebugTransferSecret,
                     payloadHash: String, date: Date = Date()) throws -> URLRequest {
        try secret.validate()
        guard let url = request.url, let c = URLComponents(url: url, resolvingAgainstBaseURL: false),
              let host = c.host, c.query == nil else { throw DebugTransferError.invalidProfile }
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX"); formatter.timeZone = TimeZone(secondsFromGMT: 0)
        formatter.dateFormat = "yyyyMMdd'T'HHmmss'Z'"
        let stamp = formatter.string(from: date); let day = String(stamp.prefix(8))
        var result = request
        result.setValue(host + (c.port.map { ":\($0)" } ?? ""), forHTTPHeaderField: "Host")
        result.setValue(stamp, forHTTPHeaderField: "x-amz-date")
        result.setValue(payloadHash, forHTTPHeaderField: "x-amz-content-sha256")
        if let token = secret.sessionToken { result.setValue(token, forHTTPHeaderField: "x-amz-security-token") }
        let headers = (result.allHTTPHeaderFields ?? [:]).map { key, value in
            (key.lowercased(), value.split(whereSeparator: { $0.isWhitespace }).joined(separator: " "))
        }.filter { $0.0 != "authorization" }.sorted { $0.0 < $1.0 }
        let names = headers.map(\.0).joined(separator: ";")
        let canonical = [result.httpMethod ?? "GET", c.percentEncodedPath.isEmpty ? "/" : c.percentEncodedPath, "",
                         headers.map { "\($0.0):\($0.1)\n" }.joined(), names, payloadHash].joined(separator: "\n")
        let scope = "\(day)/\(region)/s3/aws4_request"
        let toSign = ["AWS4-HMAC-SHA256", stamp, scope, DebugTransferDigest.hex(Data(canonical.utf8))].joined(separator: "\n")
        func hmac(_ key: Data, _ value: String) -> Data {
            Data(HMAC<SHA256>.authenticationCode(for: Data(value.utf8), using: SymmetricKey(data: key)))
        }
        let key = hmac(hmac(hmac(hmac(Data(("AWS4" + secret.secretAccessKey).utf8), day), region), "s3"), "aws4_request")
        let signature = hmac(key, toSign).map { String(format: "%02x", $0) }.joined()
        result.setValue("AWS4-HMAC-SHA256 Credential=\(secret.accessKeyID)/\(scope), SignedHeaders=\(names), Signature=\(signature)", forHTTPHeaderField: "Authorization")
        return result
    }
}
#endif
