import Foundation

/// StatusDot is the colour the panel shows at a glance: green for flowing
/// readings; amber for a stale reading, or while the engine starts,
/// connects or waits for its first reading; red for a stopped, restarting
/// or failed engine, or a sign-in failure; grey while the account is not
/// yet configured.
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
    /// readingValue, readingUnit and readingAge are the same current
    /// reading readingLine already renders as one string ("142 mg/dL (2
    /// min ago)"), split into the pieces the menu panel lays out
    /// separately: readingValue and readingUnit are the hero's own large
    /// numeral and small unit, and readingAge is that reading's age,
    /// which the view folds into the one secondary line beside
    /// shortStatus (via statusAge below) rather than showing on a line of
    /// its own. Built by ReadingText from the exact same GlucoseUnit
    /// primitives readingLine itself is built from, so the two can never
    /// disagree. All three are nil exactly when readingLine falls back to
    /// a plain sentence with no reading in it ("No reading yet", "Reading
    /// unavailable", or a permanent failure's own explanation).
    public var readingValue: String?
    public var readingUnit: String?
    public var readingAge: String?
    /// readingTrendArrow is the arrow for the reading's trend, nil when the
    /// reading has none or there is no reading.
    public var readingTrendArrow: String?
    /// shortStatus is statusLine's own text for every state except the
    /// two whose full wording already restates the age that now sits
    /// beside it on the same secondary line ("Reading is current" /
    /// "Reading is stale" shorten to "Current" / "Stale") and sign-in
    /// failing, whose full statusLine carries an instruction that belongs
    /// in statusDetail instead, not repeated here. The view reads this
    /// field directly, never by matching against statusLine's text.
    public var shortStatus: String
    /// statusAge is the reading's own age, worded for the one secondary
    /// line it shares with shortStatus, or nil when there is no reading
    /// to date at all (no credentials, connecting, waiting for a first
    /// reading, or a permanent failure). For the two states whose short
    /// status already names the reading as its subject ("Current",
    /// "Stale") this is the bare age ("just now"); for every other state
    /// that still has a reading on file (stopped, starting, restarting,
    /// sign-in failing) the short status names the ENGINE, not the
    /// reading, so the age says whose age it is ("last reading 2 min
    /// ago") rather than reading as how long the engine has been in that
    /// state.
    public var statusAge: String?
    /// statusDetail is a longer explanation that belongs on its own line
    /// in the panel, never appended to shortStatus: nil for every state
    /// except sign-in failing, where it carries the instruction.
    public var statusDetail: String?

    /// hasProblem is true when the state is one a person should be told
    /// about: every red state (stopped, restarting, failed, sign-in
    /// failing) and every amber state with a reading on file (stale, or
    /// starting again). Current readings, no reading yet and an account not
    /// yet set up are not problems.
    public var hasProblem: Bool {
        switch dot {
        case .red: return true
        case .amber: return readingValue != nil
        case .green, .grey: return false
        }
    }

    /// showsStatusLine is whether the panel has a state to report: every
    /// state except an account not yet set up, where the panel's own
    /// "Finish setup…" says the same thing.
    public var showsStatusLine: Bool { dot != .grey }

    /// freshWindow is how recent a reading has to be to still count as
    /// flowing (green) rather than stale (amber): five minutes.
    public static let freshWindow: TimeInterval = 5 * 60

    public init(
        dot: StatusDot,
        statusLine: String,
        readingLine: String,
        lastPolledLine: String,
        readingValue: String? = nil,
        readingUnit: String? = nil,
        readingAge: String? = nil,
        readingTrendArrow: String? = nil,
        shortStatus: String? = nil,
        statusAge: String? = nil,
        statusDetail: String? = nil
    ) {
        self.dot = dot
        self.statusLine = statusLine
        self.readingLine = readingLine
        self.lastPolledLine = lastPolledLine
        self.readingValue = readingValue
        self.readingUnit = readingUnit
        self.readingAge = readingAge
        self.readingTrendArrow = readingTrendArrow
        // shortStatus defaults to statusLine itself so every existing
        // caller that never mentions it (in particular this type's own
        // tests, which predate the field) keeps the one status string it
        // already passed, rather than silently ending up with an empty
        // one.
        self.shortStatus = shortStatus ?? statusLine
        self.statusAge = statusAge
        self.statusDetail = statusDetail
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
    /// - units: which unit readingLine renders mgDl in. Defaults to
    ///   mg/dL so every existing caller keeps its current behaviour.
    /// - port: the follower port the engine was asked to listen on, named
    ///   in the explanation when another app already holds it.
    /// - certificateNotice: a sentence about the local network certificate
    ///   to show on the detail line when no other detail is there.
    public static func make(
        credentialsConfigured: Bool,
        engineState: EngineSupervisor.RunState,
        status: EngineStatus?,
        now: Date,
        units: GlucoseUnit = .mgDl,
        port: Int? = nil,
        certificateNotice: String? = nil
    ) -> MenuDisplayState {
        var state = makeWithoutNotice(
            credentialsConfigured: credentialsConfigured,
            engineState: engineState,
            status: status,
            now: now,
            units: units,
            port: port
        )
        if let certificateNotice, state.showsStatusLine, state.statusDetail == nil {
            state.statusDetail = certificateNotice
        }
        return state
    }

    private static func makeWithoutNotice(
        credentialsConfigured: Bool,
        engineState: EngineSupervisor.RunState,
        status: EngineStatus?,
        now: Date,
        units: GlucoseUnit,
        port: Int?
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
            let reading = ReadingText.make(for: status, now: now, units: units)
            return MenuDisplayState(
                dot: .red,
                statusLine: "Stopped",
                readingLine: reading.line,
                lastPolledLine: lastPolledLine(for: status, now: now),
                readingValue: reading.value,
                readingUnit: reading.unit,
                readingAge: reading.age,
                readingTrendArrow: reading.trendArrow,
                statusAge: agedReadingLine(reading.age)
            )

        case .starting:
            let reading = ReadingText.make(for: status, now: now, units: units)
            return MenuDisplayState(
                dot: .amber,
                statusLine: "Starting…",
                readingLine: reading.line,
                lastPolledLine: lastPolledLine(for: status, now: now),
                readingValue: reading.value,
                readingUnit: reading.unit,
                readingAge: reading.age,
                readingTrendArrow: reading.trendArrow,
                statusAge: agedReadingLine(reading.age)
            )

        case .waitingToRestart:
            let reading = ReadingText.make(for: status, now: now, units: units)
            return MenuDisplayState(
                dot: .red,
                statusLine: "Restarting…",
                readingLine: reading.line,
                lastPolledLine: lastPolledLine(for: status, now: now),
                readingValue: reading.value,
                readingUnit: reading.unit,
                readingAge: reading.age,
                readingTrendArrow: reading.trendArrow,
                statusAge: agedReadingLine(reading.age)
            )

        case .failed(let reason):
            return MenuDisplayState(
                dot: .red,
                statusLine: statusLine(for: reason),
                readingLine: detailLine(for: reason, port: port),
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
                let reading = ReadingText.make(for: status, now: now, units: units)
                return MenuDisplayState(
                    dot: .red,
                    statusLine: "Sign-in failing. Check your LibreLinkUp email and password in Settings.",
                    readingLine: reading.line,
                    lastPolledLine: lastPolledLine(for: status, now: now),
                    readingValue: reading.value,
                    readingUnit: reading.unit,
                    readingAge: reading.age,
                    readingTrendArrow: reading.trendArrow,
                    shortStatus: "Sign-in failing",
                    statusAge: agedReadingLine(reading.age),
                    statusDetail: "Check your LibreLinkUp email and password in Settings."
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
            let reading = ReadingText.make(for: status, now: now, units: units)
            return MenuDisplayState(
                dot: isFresh ? .green : .amber,
                statusLine: isFresh ? "Reading is current" : "Reading is stale",
                readingLine: reading.line,
                lastPolledLine: lastPolledLine(for: status, now: now),
                readingValue: reading.value,
                readingUnit: reading.unit,
                readingAge: reading.age,
                readingTrendArrow: reading.trendArrow,
                shortStatus: isFresh ? "Current" : "Stale",
                // The bare age, not agedReadingLine's "last reading …"
                // prefix: shortStatus already names the reading as its
                // own subject here ("Current", "Stale"), so "just now" on
                // its own reads unambiguously.
                statusAge: reading.age
            )
        }
    }

    /// agedReadingLine words a reading's own age for the one secondary
    /// line it shares with a shortStatus that names the ENGINE rather
    /// than the reading itself (Stopped, Starting…, Restarting…,
    /// Sign-in failing): "last reading 2 min ago" rather than a bare "2
    /// min ago", which beside one of those statuses reads as how long
    /// the engine has been in that state instead of the reading's own
    /// age. Returns nil unchanged when there is no age to word at all.
    private static func agedReadingLine(_ age: String?) -> String? {
        guard let age else { return nil }
        return "last reading \(age)"
    }

    /// statusLine renders a permanent failure's headline, in the person's
    /// own terms: never "engine", "store", "key mismatch", or an exit
    /// status, and no longer than every other state's shortStatus (this
    /// becomes shortStatus too, unchanged, since a permanent failure's
    /// headline already is the short form).
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
        case .portInUse:
            return "Port is in use"
        case .httpsOnStatusPort:
            return "Tailscale HTTPS port clash"
        case .recoveryMoveFailed:
            // Names the action the person took (Start Fresh, the button
            // whose confirmation triggers this recovery path) rather than
            // the internal step that failed partway through it, kept as
            // short as every other status; detailLine below carries the
            // fuller explanation and the retry instruction.
            return "Couldn't start fresh"
        }
    }

    /// detailLine renders a permanent failure's explanation, shown where
    /// the current reading would otherwise go.
    private static func detailLine(for reason: EngineSupervisor.FailureReason, port: Int?) -> String {
        switch reason {
        case .storeKeyMismatch:
            return "They were saved with a key this Mac no longer has."
        case .storeInUse:
            return "Another copy is using your saved readings. Quit this one."
        case .storeDamaged:
            return "The file is damaged."
        case .configurationUnreadable:
            return "Try again. If it keeps happening, quit and reopen CGM Relay."
        case .portInUse:
            let named = port.map { "Port \($0) is in use by another app." } ?? "The port is in use by another app."
            return "\(named) Choose another in Settings, under Advanced."
        case .httpsOnStatusPort:
            return "Tailscale HTTPS is set on the port CGM Relay keeps for itself. Turn Tailscale HTTPS off in Settings, under Advanced, with Tailscale running, and CGM Relay moves to a free port."
        case .recoveryMoveFailed:
            return "Check that CGM Relay can write to its own folder, then try Start Fresh again."
        }
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
    public static func relativeAgeText(from date: Date, to now: Date) -> String {
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

/// ReadingText is the one mapping from an EngineStatus's raw reading to
/// every display form MenuDisplayState hands out: the combined line
/// readingLine has always rendered ("142 mg/dL (2 min ago)"), and the
/// value/unit/age split a view wants to lay out as separate pieces.
/// Building both from this one type, rather than building the line and
/// then re-parsing it back apart, is what keeps them unable to disagree
/// about when a reading exists.
private struct ReadingText {
    let line: String
    let value: String?
    let unit: String?
    let age: String?
    let trendArrow: String?

    static func make(for status: EngineStatus?, now: Date, units: GlucoseUnit) -> ReadingText {
        guard let status, let readingTime = status.lastReadingTime else {
            return ReadingText(line: "No reading yet", value: nil, unit: nil, age: nil, trendArrow: nil)
        }
        guard let mgDl = status.lastReadingMgDl else {
            return ReadingText(line: "Reading unavailable", value: nil, unit: nil, age: nil, trendArrow: nil)
        }
        let value = units.formatValue(mgDl: mgDl)
        let unit = units.label
        let age = MenuDisplayState.relativeAgeText(from: readingTime, to: now)
        return ReadingText(
            line: "\(value) \(unit) (\(age))",
            value: value,
            unit: unit,
            age: age,
            trendArrow: TrendArrow.symbol(forDirection: status.lastReadingTrend)
        )
    }
}
