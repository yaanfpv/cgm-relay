import Foundation

/// BuiltInStatus is what the engine's status reports about its built-in
/// Tailscale node, from the `ts_*` fields. Every field is a plain string as
/// sent; BuiltInRouteState decides what each means and which URLs may be
/// opened.
public struct BuiltInStatus: Equatable, Sendable {
    public var state: String?
    public var loginURL: String?
    public var approveURL: String?
    public var funnelURL: String?
    public var publicHost: String?
    public var error: String?
    /// checkedAt is when the public address last answered a test.
    public var checkedAt: Date?
    /// notAnsweringSince is when it stopped answering.
    public var notAnsweringSince: Date?
    /// counts are the engine's counts for diagnostics, by name.
    public var counts: [String: Int]?
    /// publishingSince is when the address began to be served, while it has
    /// not answered yet.
    public var publishingSince: Date?
    /// tailscaleError is the last text Tailscale gave, kept for the person,
    /// and errorClass its class, which is all diagnostics carry.
    public var tailscaleError: String?
    public var errorClass: String?
    /// keyExpiry is when the node's key expires.
    public var keyExpiry: Date?
    /// signInAgainURL is the page of a sign-in the engine started while the
    /// node runs.
    public var signInAgainURL: String?

    public init(
        state: String? = nil,
        loginURL: String? = nil,
        approveURL: String? = nil,
        funnelURL: String? = nil,
        publicHost: String? = nil,
        error: String? = nil,
        checkedAt: Date? = nil,
        notAnsweringSince: Date? = nil,
        counts: [String: Int]? = nil,
        publishingSince: Date? = nil,
        tailscaleError: String? = nil,
        errorClass: String? = nil,
        keyExpiry: Date? = nil,
        signInAgainURL: String? = nil
    ) {
        self.state = state
        self.loginURL = loginURL
        self.approveURL = approveURL
        self.funnelURL = funnelURL
        self.publicHost = publicHost
        self.error = error
        self.checkedAt = checkedAt
        self.notAnsweringSince = notAnsweringSince
        self.counts = counts
        self.publishingSince = publishingSince
        self.tailscaleError = tailscaleError
        self.errorClass = errorClass
        self.keyExpiry = keyExpiry
        self.signInAgainURL = signInAgainURL
    }
}

/// BuiltInRouteState is where the built-in Tailscale route is in its
/// setup, as the app shows it: one state per status row.
public enum BuiltInRouteState: Equatable, Sendable {
    case starting
    case signIn(URL)
    case approve(URL)
    case enableFunnel(URL)
    case settingUp(host: String)
    /// publishing is a listening node whose new public address has not
    /// answered yet, which can take minutes and is not a failure.
    case publishing(host: String, since: Date?)
    /// notReachable is the same wait after the engine's window for it.
    case notReachable(host: String)
    case ready(host: String, checkedAt: Date? = nil)
    /// notAnswering is a public address that stopped answering while this
    /// Mac's network is fine; the engine is reconnecting it.
    case notAnswering(host: String, since: Date?)
    /// waitingForInternet is a test that could not be made, or that says
    /// nothing about the address, because this Mac or the node is offline.
    case waitingForInternet(host: String)
    /// stopped is the route while the engine is not running: there is no
    /// address to give, whatever the last report said.
    case stopped
    case failed(String)

    /// from maps the engine's report to a state. No report yet is starting;
    /// a state this version does not know, or a step whose URL the app would
    /// not open, is a failure the person can retry, never a blank wait.
    public static func from(_ status: BuiltInStatus?) -> BuiltInRouteState {
        guard let status, let state = status.state else { return .starting }
        switch state {
        case "starting":
            return .starting
        case "needs-login":
            guard let url = openable(status.loginURL) else { return .failed(unopenableMessage) }
            return .signIn(url)
        case "needs-approval":
            guard let url = openable(status.approveURL) else { return .failed(unopenableMessage) }
            return .approve(url)
        case "needs-funnel":
            guard let url = openable(status.funnelURL) else { return .failed(unopenableMessage) }
            return .enableFunnel(url)
        case "setting-up":
            return .settingUp(host: status.publicHost ?? "")
        case "running":
            guard let host = status.publicHost, !host.isEmpty else { return .failed("Tailscale is connected but gave no address.") }
            return .ready(host: host, checkedAt: status.checkedAt)
        case "publishing":
            return .publishing(host: status.publicHost ?? "", since: status.publishingSince)
        case "not-reachable":
            return .notReachable(host: status.publicHost ?? "")
        case "not-answering":
            return .notAnswering(host: status.publicHost ?? "", since: status.notAnsweringSince)
        case "waiting-for-internet":
            return .waitingForInternet(host: status.publicHost ?? "")
        case "error":
            let message = status.error ?? ""
            return .failed(message.isEmpty ? "Tailscale stopped with an error." : message)
        default:
            return .failed("Tailscale reported a state this version of CGM Relay does not know.")
        }
    }

    /// resolve is the route the app shows: the engine's report only while the
    /// engine is running. A stopped engine, or one waiting to restart, has no
    /// address, and a start that has not reported yet has nothing to show but
    /// that it is starting, whatever an earlier report said.
    public static func resolve(engineState: EngineSupervisor.RunState, status: BuiltInStatus?) -> BuiltInRouteState {
        switch engineState {
        case .stopped, .waitingToRestart: return .stopped
        case .starting: return .starting
        case .failed: return .failed("CGM Relay couldn't start. Try Again.")
        case .running: return from(status)
        }
    }

    /// expiredAt is this state with a Ready whose last test is older than
    /// maxAge at now turned into setting up: a report that stopped arriving
    /// must not keep saying the address answers.
    public func expiredAt(_ now: Date, maxAge: TimeInterval = 6 * 60) -> BuiltInRouteState {
        if case .ready(let host, let checkedAt?) = self, now.timeIntervalSince(checkedAt) > maxAge {
            return .settingUp(host: host)
        }
        return self
    }

    private static let unopenableMessage = "Tailscale gave a page address CGM Relay will not open."

    /// openable is the URL when raw is an https address on tailscale.com or
    /// one of its subdomains, and nil for anything else. It is the only gate
    /// before the app opens a page the engine named.
    public static func openable(_ raw: String?) -> URL? {
        guard
            let raw, !raw.isEmpty,
            let url = URL(string: raw),
            url.scheme == "https",
            url.user == nil, url.password == nil,
            let host = url.host?.lowercased(),
            host == "tailscale.com" || host.hasSuffix(".tailscale.com")
        else {
            return nil
        }
        return url
    }

    /// address is the https address a follower is given, only once ready.
    public var address: String? {
        if case .ready(let host, _) = self { return "https://\(host)" }
        return nil
    }

    /// reason is the one plain sentence for why no address exists yet.
    public var notReadyReason: String {
        switch self {
        case .starting: return "Starting Tailscale…"
        case .signIn: return "Sign in to Tailscale to get your address."
        case .approve: return "Approve this Mac in Tailscale to get your address."
        case .enableFunnel: return "Turn on your public address in Tailscale."
        case .settingUp: return "Setting up your address…"
        case .publishing: return Self.publishingText
        case .notReachable: return "Your address isn't reachable yet"
        case .notAnswering: return "Your address isn't answering. Reconnecting…"
        case .waitingForInternet: return "Waiting for the internet to check your address."
        case .stopped: return "Your address is stopped. It works again once CGM Relay is running."
        case .failed(let message): return message
        case .ready: return ""
        }
    }

    /// settingsStatusText is the one line Settings shows for the route, with
    /// times in timeZone.
    public func settingsStatusText(timeZone: TimeZone, now: Date = Date()) -> String {
        switch self {
        case .publishing(_, let since?):
            let minutes = max(0, Int(now.timeIntervalSince(since) / 60))
            let elapsed = minutes < 1 ? "less than 1 min so far" : "\(minutes) min so far"
            return "\(Self.publishingText) (\(elapsed))"
        case .ready(_, let checkedAt?): return "Ready · checked \(Self.clock(checkedAt, timeZone))"
        case .ready: return "Ready"
        case .notAnswering(_, let since?): return "Not answering since \(Self.clock(since, timeZone)), reconnecting…"
        case .notAnswering: return "Not answering, reconnecting…"
        case .waitingForInternet: return "Waiting for the internet"
        case .stopped: return "Address stopped"
        default: return notReadyReason
        }
    }

    private static let publishingText = "Publishing your address… This can take up to 10 minutes"

    /// showsTryAgain is whether Settings offers Try Again for the state.
    public var showsTryAgain: Bool {
        switch self {
        case .notReachable, .notAnswering: return true
        default: return false
        }
    }

    /// tailscaleErrorText is the last text Tailscale gave, on the states that
    /// show setup or the address, and nil on any other or when it is blank.
    public static func tailscaleErrorText(from status: BuiltInStatus?) -> String? {
        guard
            let status,
            let state = status.state,
            ["needs-funnel", "publishing", "setting-up", "not-reachable", "not-answering"].contains(state),
            let text = status.tailscaleError?.trimmingCharacters(in: .whitespacesAndNewlines),
            !text.isEmpty
        else { return nil }
        return text
    }

    private static func clock(_ date: Date, _ timeZone: TimeZone) -> String {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = timeZone
        formatter.dateFormat = "HH:mm"
        return formatter.string(from: date)
    }
}

/// BuiltInKeyExpiry is the warning that the node's Tailscale sign-in is about
/// to expire, and the way to sign in again before it does. The key's expiry is
/// never turned off by the app.
public struct BuiltInKeyExpiry: Equatable, Sendable {
    /// warningWindow is how long before expiry the warning shows.
    public static let warningWindow: TimeInterval = 14 * 24 * 60 * 60
    public static let signInAgainTitle = "Sign In Again"

    public let expiresAt: Date

    /// notice is the warning for status at now: only within warningWindow of
    /// the expiry, and never after it, when the sign-in state applies.
    public static func notice(for status: BuiltInStatus?, now: Date) -> BuiltInKeyExpiry? {
        guard let expiry = status?.keyExpiry else { return nil }
        let left = expiry.timeIntervalSince(now)
        guard left > 0, left <= warningWindow else { return nil }
        return BuiltInKeyExpiry(expiresAt: expiry)
    }

    public func text(timeZone: TimeZone) -> String {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = timeZone
        formatter.dateFormat = "d MMM yyyy"
        return "Tailscale sign-in expires on \(formatter.string(from: expiresAt))"
    }

    /// signInAgainURL is the page the engine named for a sign-in it started,
    /// only when it is an https page on Tailscale.
    public static func signInAgainURL(from status: BuiltInStatus?) -> URL? {
        BuiltInRouteState.openable(status?.signInAgainURL)
    }
}
