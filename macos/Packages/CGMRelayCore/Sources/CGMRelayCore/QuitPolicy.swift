import Foundation

/// QuitPolicy decides whether a request to quit the app really ends it. A
/// quit that arrives as the quit Apple event from outside the app (the
/// Dock's Quit, another app's request) only closes the windows and keeps
/// the relay running, so the relay is not stopped by a click that looks
/// like closing a window. Every quit the person asks for inside the app,
/// the session ending and the updater replacing the app really quit.
public enum QuitPolicy {
    /// systemReasons are the reasons the system's quit event carries when
    /// the session is ending: log out, restart or shut down, each with or
    /// without its confirmation dialog.
    public static let systemReasons: Set<UInt32> = [
        fourCharCode("logo"), fourCharCode("rlgo"),
        fourCharCode("rest"), fourCharCode("rrst"),
        fourCharCode("shut"), fourCharCode("rsdn"),
    ]

    /// shouldTerminate is false only for a quit Apple event from outside
    /// the app that carries no session-ending reason and did not come from
    /// the updater. A quit with no Apple event behind it came from inside
    /// the app (the app menu, Command-Q, the panel, the right-click menu,
    /// code calling terminate); the session ending is known from the reason
    /// its quit event carries, or from the system's power-off notice; the
    /// updater asks with a plain quit event because it cannot replace the
    /// app while it runs.
    public static func shouldTerminate(quitEventPresent: Bool, eventReason: UInt32?, sessionEnding: Bool, fromUpdater: Bool = false) -> Bool {
        if sessionEnding || fromUpdater || !quitEventPresent { return true }
        guard let eventReason else { return false }
        return systemReasons.contains(eventReason)
    }

    private static func fourCharCode(_ text: String) -> UInt32 {
        text.utf8.reduce(0) { ($0 << 8) | UInt32($1) }
    }
}
