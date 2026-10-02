import AppKit
import CGMRelayCore
import Foundation

/// FeedbackLinks opens a new GitHub issue for a bug or a feature request,
/// carrying only what FeedbackIssueURL allows.
enum FeedbackLinks {
    static func open(_ kind: FeedbackIssueURL.Kind) {
        NSWorkspace.shared.open(url(for: kind))
    }

    static func url(for kind: FeedbackIssueURL.Kind) -> URL {
        let info = Bundle.main.infoDictionary
        let version = ProcessInfo.processInfo.operatingSystemVersion
        return FeedbackIssueURL.make(
            kind: kind,
            appVersion: info?["CFBundleShortVersionString"] as? String ?? "unknown",
            buildNumber: info?["CFBundleVersion"] as? String ?? "unknown",
            macOSVersion: "\(version.majorVersion).\(version.minorVersion).\(version.patchVersion)",
            chip: chip
        )
    }

    /// chip is the Mac's own processor, not the architecture this process
    /// runs as: a universal app under Rosetta still reports Apple silicon.
    private static var chip: String {
        var isARM: Int32 = 0
        var size = MemoryLayout<Int32>.size
        let known = sysctlbyname("hw.optional.arm64", &isARM, &size, nil, 0) == 0
        return known && isARM == 1 ? "Apple silicon" : "Intel"
    }
}
