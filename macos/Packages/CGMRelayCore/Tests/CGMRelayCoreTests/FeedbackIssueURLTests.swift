import Testing
import Foundation
@testable import CGMRelayCore

@Suite("FeedbackIssueURL")
struct FeedbackIssueURLTests {
    private func fields(_ url: URL) -> [String: String] {
        let items = URLComponents(url: url, resolvingAgainstBaseURL: false)?.queryItems ?? []
        return Dictionary(uniqueKeysWithValues: items.map { ($0.name, $0.value ?? "") })
    }

    static let cases: [(kind: FeedbackIssueURL.Kind, template: String)] = [
        (.bug, "bug_report.yml"),
        (.feature, "feature_request.yml"),
    ]

    @Test("each link opens its own issue form on the project's repository, filling exactly the version, build, macOS version and chip by the form's field ids", arguments: cases)
    func carriesOnlyThoseFacts(_ testCase: (kind: FeedbackIssueURL.Kind, template: String)) {
        let url = FeedbackIssueURL.make(kind: testCase.kind, appVersion: "0.1.0", buildNumber: "7", macOSVersion: "27.0.1", chip: "Apple silicon")
        #expect(url.absoluteString.hasPrefix("https://github.com/yaanfpv/cgm-relay/issues/new?"))
        #expect(fields(url) == [
            "template": testCase.template,
            "app_version": "0.1.0",
            "build": "7",
            "macos_version": "27.0.1",
            "chip": "Apple silicon",
        ])
    }
}
