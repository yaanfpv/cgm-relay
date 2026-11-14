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

    public init(
        state: String? = nil,
        loginURL: String? = nil,
        approveURL: String? = nil,
        funnelURL: String? = nil,
        publicHost: String? = nil,
        error: String? = nil
    ) {
        self.state = state
        self.loginURL = loginURL
        self.approveURL = approveURL
        self.funnelURL = funnelURL
        self.publicHost = publicHost
        self.error = error
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
    case ready(host: String)
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
            return .ready(host: host)
        case "error":
            let message = status.error ?? ""
            return .failed(message.isEmpty ? "Tailscale stopped with an error." : message)
        default:
            return .failed("Tailscale reported a state this version of CGM Relay does not know.")
        }
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
        if case .ready(let host) = self { return "https://\(host)" }
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
        case .failed(let message): return message
        case .ready: return ""
        }
    }
}
