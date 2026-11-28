import Foundation

/// Build-time identity, not an on-device cryptographic verification result.
enum BuildProvenance {
    private static let repository = "skar404/slowth"
    static let repositoryURL = URL(string: "https://github.com/\(repository)")!

    struct Evidence {
        let commit: String
        let runURL: URL

        var shortCommit: String { String(commit.prefix(12)) }
        var commitURL: URL { repositoryURL.appendingPathComponent("commit").appendingPathComponent(commit) }
    }

    static let current: Evidence? = {
        guard let resource = Bundle.main.url(forResource: "BuildIdentity", withExtension: "json"),
              let data = try? Data(contentsOf: resource),
              let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let commit = object["commit"] as? String,
              commit.count == 40, commit.allSatisfy({ $0.isASCII && $0.isHexDigit }),
              let version = object["marketing_version"] as? String,
              version == Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String,
              let build = object["build_number"] as? String,
              build == Bundle.main.object(forInfoDictionaryKey: "CFBundleVersion") as? String,
              object["repository"] as? String == repository,
              let rawURL = object["run_url"] as? String,
              let url = URL(string: rawURL), url.scheme == "https", url.host == "github.com",
              url.path.hasPrefix("/\(repository)/actions/runs/"),
              url.user == nil, url.password == nil else { return nil }
        return Evidence(commit: commit, runURL: url)
    }()
}
