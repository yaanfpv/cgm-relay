import Foundation

/// PendingUpdate is what the app knows about a newer version while it is
/// waiting on the person: found but not yet installed, or downloaded and
/// ready to install by restarting. Every place that offers the update (the
/// menu bar item, the panel, the menus, About, Settings) words it from here.
public enum PendingUpdate: Sendable, Equatable {
    case none
    case available(version: String)
    case readyToRestart(version: String)

    public static let checkTitle = "Check for Updates…"

    /// menuTitle is the one entry that checks for, shows or installs an
    /// update, so the same action reads right wherever it appears.
    public var menuTitle: String {
        switch self {
        case .none: return Self.checkTitle
        case .available(let version): return "Update Available (\(version))…"
        case .readyToRestart: return "Restart to Update"
        }
    }

    /// statusLine says the state in a sentence, or is nil when there is
    /// nothing waiting.
    public var statusLine: String? {
        switch self {
        case .none: return nil
        case .available(let version): return "Version \(version) is available."
        case .readyToRestart(let version): return "Version \(version) is ready. It installs when CGM Relay next quits."
        }
    }

    /// accessibilityNote is what the menu bar item adds to its spoken label
    /// so an update is noticed without sight of the mark.
    public var accessibilityNote: String? {
        switch self {
        case .none: return nil
        case .available(let version): return "Update \(version) available"
        case .readyToRestart(let version): return "Update \(version) ready, restart to install"
        }
    }
}

/// UpdateLinks are the addresses the app's update surfaces point at.
public enum UpdateLinks {
    /// changelog is the project's changelog on GitHub, which is where
    /// "What's New" leads.
    public static let changelog = URL(string: "\(FeedbackIssueURL.repository)/blob/main/CHANGELOG.md")!
}
