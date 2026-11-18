import Foundation

/// SettingsOpenStep is what follows a request to open Settings once the app
/// has looked for the window.
public enum SettingsOpenStep: Equatable, Sendable {
    /// done: the window is on screen.
    case done
    /// retry: request the open once more.
    case retry
    /// gaveUp: stop; nothing else is requested.
    case gaveUp
}

/// SettingsOpenPolicy decides what follows a request to open Settings: the
/// open is requested once more when its window is not on screen after the
/// first attempt, and never after the second.
public enum SettingsOpenPolicy {
    /// maxAttempts is how many times one open is requested.
    public static let maxAttempts = 2

    /// next is the step after attempt number `attempt`, counted from 1. An
    /// attempt outside 1...maxAttempts gives up.
    public static func next(attempt: Int, windowOnScreen: Bool) -> SettingsOpenStep {
        guard (1...maxAttempts).contains(attempt) else { return .gaveUp }
        if windowOnScreen { return .done }
        return attempt < maxAttempts ? .retry : .gaveUp
    }
}
