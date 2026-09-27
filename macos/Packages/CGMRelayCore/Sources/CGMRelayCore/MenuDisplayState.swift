import Foundation

/// StatusDot is the colour the menu bar shows at a glance: green for
/// flowing readings, amber for a stale one, red for a stopped engine or a
/// sign-in failure, grey while the account is not yet configured.
public enum StatusDot: Sendable, Equatable {
    case green, amber, red, grey
}

/// MenuDisplayState is everything the menu's popover shows, computed once
/// from the engine's last known status and the app's own knowledge of
/// whether the engine process is currently running. It carries no UI
/// framework dependency: `make` is a pure function of its inputs, so the
/// mapping is tested directly against fixtures rather than through the
/// SwiftUI view that renders it.
public struct MenuDisplayState: Sendable, Equatable {
    public var dot: StatusDot
    public var statusLine: String
    public var readingLine: String
    public var lastPolledLine: String

    /// freshWindow is how recent a reading has to be to still count as
    /// flowing (green) rather than stale (amber): five minutes.
    public static let freshWindow: TimeInterval = 5 * 60

    public init(dot: StatusDot, statusLine: String, readingLine: String, lastPolledLine: String) {
        self.dot = dot
        self.statusLine = statusLine
        self.readingLine = readingLine
        self.lastPolledLine = lastPolledLine
    }

    /// make computes the display state a person should see right now.
    ///
    /// - credentialsConfigured: whether a LibreLinkUp email and password
    ///   are on file; the engine is never started without both, so this
    ///   takes priority over every other input.
    /// - engineState: the supervisor's own knowledge of the engine child
    ///   process, independent of `status` (which, once fetched, always
    ///   reports `running: true`). Every case is rendered distinctly so
    ///   the menu never says "Stopped" while a start or a restart is
    ///   actually pending.
    /// - status: the engine's last successfully fetched `/status`
    ///   response, or nil if none has been fetched yet.
    /// - now: the instant to measure every age against.
    public static func make(
        credentialsConfigured: Bool,
        engineState: EngineSupervisor.RunState,
        status: EngineStatus?,
        now: Date
    ) -> MenuDisplayState {
        guard credentialsConfigured else {
            return MenuDisplayState(
                dot: .grey,
                statusLine: "Setup needed",
                readingLine: "No reading yet",
                lastPolledLine: ""
            )
        }

        switch engineState {
        case .stopped:
            return MenuDisplayState(
                dot: .red,
                statusLine: "Stopped",
                readingLine: readingLine(for: status, now: now),
                lastPolledLine: lastPolledLine(for: status, now: now)
            )

        case .starting:
            return MenuDisplayState(
                dot: .amber,
                statusLine: "Starting…",
                readingLine: readingLine(for: status, now: now),
                lastPolledLine: lastPolledLine(for: status, now: now)
            )

        case .waitingToRestart:
            return MenuDisplayState(
                dot: .red,
                statusLine: "Restarting…",
                readingLine: readingLine(for: status, now: now),
                lastPolledLine: lastPolledLine(for: status, now: now)
            )

        case .failed(let reason):
            return MenuDisplayState(
                dot: .red,
                statusLine: statusLine(for: reason),
                readingLine: detailLine(for: reason),
                lastPolledLine: ""
            )

        case .running:
            guard let status else {
                return MenuDisplayState(
                    dot: .amber,
                    statusLine: "Connecting…",
                    readingLine: "No reading yet",
                    lastPolledLine: ""
                )
            }

            if status.signInFailing {
                return MenuDisplayState(
                    dot: .red,
                    statusLine: "Sign-in failing. Check your LibreLinkUp email and password in Settings.",
                    readingLine: readingLine(for: status, now: now),
                    lastPolledLine: lastPolledLine(for: status, now: now)
                )
            }

            guard let readingTime = status.lastReadingTime else {
                return MenuDisplayState(
                    dot: .amber,
                    statusLine: "Waiting for a reading",
                    readingLine: "No reading yet",
                    lastPolledLine: lastPolledLine(for: status, now: now)
                )
            }

            let age = now.timeIntervalSince(readingTime)
            let isFresh = age >= 0 && age <= freshWindow
            return MenuDisplayState(
                dot: isFresh ? .green : .amber,
                statusLine: isFresh ? "Reading is current" : "Reading is stale",
                readingLine: readingLine(for: status, now: now),
                lastPolledLine: lastPolledLine(for: status, now: now)
            )
        }
    }

    /// statusLine renders a permanent failure's headline, in the person's
    /// own terms: never "engine", "store", "key mismatch", or an exit
    /// status.
    private static func statusLine(for reason: EngineSupervisor.FailureReason) -> String {
        switch reason {
        case .storeKeyMismatch:
            return "Saved readings can't be opened"
        case .storeInUse:
            return "CGM Relay is already running"
        case .storeDamaged:
            return "Saved readings can't be read"
        case .configurationUnreadable:
            return "Can't read your saved settings"
        case .recoveryMoveFailed:
            return "Couldn't move the saved readings aside"
        }
    }

    /// detailLine renders a permanent failure's explanation, shown where
    /// the current reading would otherwise go.
    private static func detailLine(for reason: EngineSupervisor.FailureReason) -> String {
        switch reason {
        case .storeKeyMismatch:
            return "They were saved with a key this Mac no longer has."
        case .storeInUse:
            return "Another copy is using your saved readings. Quit this one."
        case .storeDamaged:
            return "The file is damaged."
        case .configurationUnreadable:
            return "Try again. If it keeps happening, quit and reopen CGM Relay."
        case .recoveryMoveFailed:
            return "Check that CGM Relay can write to its own folder, then try Start Fresh again."
        }
    }

    private static func readingLine(for status: EngineStatus?, now: Date) -> String {
        guard let status, let readingTime = status.lastReadingTime else { return "No reading yet" }
        guard let mgDl = status.lastReadingMgDl else { return "Reading unavailable" }
        return "\(mgDl) mg/dL (\(relativeAgeText(from: readingTime, to: now)))"
    }

    private static func lastPolledLine(for status: EngineStatus?, now: Date) -> String {
        guard let status, let latest = status.clients?.values.max() else {
            return "No follower app has polled yet"
        }
        return "Last polled \(relativeAgeText(from: latest, to: now))"
    }

    /// relativeAgeText renders a short, deterministic age string such as
    /// "3 min ago". A hand-rolled formatter is used deliberately, in place
    /// of RelativeDateTimeFormatter, because that formatter's abbreviated
    /// output is locale- and OS-version-dependent and would make the exact
    /// wording this type promises drift out from under its own tests.
    static func relativeAgeText(from date: Date, to now: Date) -> String {
        let seconds = now.timeIntervalSince(date)
        guard seconds >= 0 else { return "just now" }
        switch seconds {
        case ..<60:
            return "just now"
        case ..<3600:
            return "\(Int(seconds / 60)) min ago"
        case ..<86400:
            return "\(Int(seconds / 3600)) hr ago"
        default:
            return "\(Int(seconds / 86400)) d ago"
        }
    }
}
