import Foundation

/// FeedbackIssueURL builds the address that opens a new GitHub issue on one
/// of the repository's issue forms, with only the facts a maintainer needs
/// to reproduce a problem filled in: the app version and build, the macOS
/// version and the chip. Its signature is the guarantee that nothing else
/// (a reading, an account, an address, a token, a path) can reach the
/// address.
public enum FeedbackIssueURL {
    public enum Kind: Sendable {
        case bug, feature

        /// template is the file name of the issue form under
        /// .github/ISSUE_TEMPLATE.
        var template: String {
            switch self {
            case .bug: return "bug_report.yml"
            case .feature: return "feature_request.yml"
            }
        }
    }

    public static let repository = "https://github.com/yaanfpv/cgm-relay"

    /// make names the form and fills its version, build, macOS and chip
    /// fields by their ids in the form.
    public static func make(kind: Kind, appVersion: String, buildNumber: String, macOSVersion: String, chip: String) -> URL {
        var components = URLComponents(string: "\(repository)/issues/new")!
        components.queryItems = [
            URLQueryItem(name: "template", value: kind.template),
            URLQueryItem(name: "app_version", value: appVersion),
            URLQueryItem(name: "build", value: buildNumber),
            URLQueryItem(name: "macos_version", value: macOSVersion),
            URLQueryItem(name: "chip", value: chip),
        ]
        return components.url!
    }
}
