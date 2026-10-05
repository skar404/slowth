import Foundation

/// Build-time identity, not an on-device cryptographic verification result.
enum BuildProvenance {
    struct Evidence {
        let shortCommit: String
        let runURL: URL
    }

    static let current: Evidence? = {
        guard let resource = Bundle.main.url(forResource: "BuildIdentity", withExtension: "json"),
              let data = try? Data(contentsOf: resource),
              let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let commit = object["commit"] as? String,
              commit.count == 40, commit.allSatisfy({ $0.isHexDigit }),
              object["marketing_version"] as? String == Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String,
              object["build_number"] as? String == Bundle.main.object(forInfoDictionaryKey: "CFBundleVersion") as? String,
              object["repository"] as? String == "skar404/slowth",
              let rawURL = object["run_url"] as? String,
              let url = URL(string: rawURL), url.scheme == "https", url.host == "github.com",
              url.path.hasPrefix("/skar404/slowth/actions/runs/"),
              url.user == nil, url.password == nil else { return nil }
        return Evidence(shortCommit: String(commit.prefix(12)), runURL: url)
    }()
}
