import WebKit

@available(iOS 18.4, *)
@MainActor
enum WebAppTrackingProtection {
    private enum CompilationError: Error { case missingList }

    static func compile() async throws -> WKContentRuleList {
        guard let url = Bundle.main.url(forResource: "WebAppMetricRules", withExtension: "json") else {
            throw CocoaError(.fileNoSuchFile)
        }
        let json = try String(contentsOf: url, encoding: .utf8)
        guard let list = try await WKContentRuleListStore.default().compileContentRuleList(
            forIdentifier: "slowth.web-apps.trackers", encodedContentRuleList: json)
        else { throw CompilationError.missingList }
        return list
    }
}
