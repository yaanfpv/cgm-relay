import Foundation

/// DiagnosticsReport builds the plain-text report the About pane's Copy
/// Diagnostics button puts on the clipboard. Its own parameter list is
/// the safety boundary: it takes no LibreLinkUp email, no token, no store
/// key, no bind address, and no current glucose reading, so no future
/// caller can accidentally hand one through -- and where an engine detail
/// might otherwise carry one (lastError, which the poller keeps to a
/// fixed set of secret-free phrases like "sign-in failed" today), this
/// builder still does nothing to strip it: that phrase's own safety
/// belongs to whoever writes it, not to this formatter.
public enum DiagnosticsReport {
    public static func build(
        appVersion: String,
        buildNumber: String,
        macOSVersion: String,
        engineState: EngineSupervisor.RunState,
        lastError: String?,
        reach: NetworkReach,
        port: Int,
        retentionDays: Int,
        units: GlucoseUnit,
        noReadingAlertEnabled: Bool,
        noReadingAlertMinutes: Int,
        signInFailingAlertEnabled: Bool,
        followerAges: [(client: String, age: String)],
        routeCounts: [String: Int] = [:],
        routeErrorClass: String? = nil,
        builtIn: BuiltInRouteState? = nil
    ) -> String {
        var lines: [String] = [
            "CGM Relay \(appVersion) (\(buildNumber))",
            "macOS \(macOSVersion)",
            "Engine: \(describe(engineState))",
            "Last error: \(lastError ?? "none")",
            "Reach: \(builtIn.map(describe) ?? describe(reach))",
            "Port: \(port)",
            "Retention: \(retentionDays) day\(retentionDays == 1 ? "" : "s")",
            "Units: \(units == .mgDl ? "mg/dL" : "mmol/L")",
            "No-reading alert: \(noReadingAlertEnabled ? "on, after \(noReadingAlertMinutes) min" : "off")",
            "Sign-in alert: \(signInFailingAlertEnabled ? "on" : "off")",
        ]

        if followerAges.isEmpty {
            lines.append("Followers: none yet")
        } else {
            lines.append("Followers:")
            for follower in followerAges {
                lines.append("  \(follower.client): last seen \(follower.age)")
            }
        }

        let counted = countNames.compactMap { name in
            routeCounts[name].map { "\(name) \(max($0, 0))" }
        }
        if !counted.isEmpty {
            lines.append("Address checks: \(counted.joined(separator: ", "))")
        }
        if let routeErrorClass, errorClasses.contains(routeErrorClass) {
            lines.append("Address error class: \(routeErrorClass)")
        }

        return lines.joined(separator: "\n")
    }

    /// countNames are the only names the engine counts under (its Tailscale
    /// log lines and its failure classes). A count under any other name is
    /// dropped, so a report can never carry an address or a host the engine
    /// did not mean as a count.
    private static let errorClasses = ["listen_failed", "https_disabled", "node_attribute_missing"]

    private static let countNames = [
        "ingress_denied", "handshake", "control_reconnect",
        "dropped_during_tls", "tls_failure", "server_error", "name_not_published",
        "dns_failure", "no_route", "connect_refused", "connect_timeout",
        "tailnet_address", "node_offline", "node_unhealthy", "status_read_failed",
    ]

    private static func describe(_ state: EngineSupervisor.RunState) -> String {
        switch state {
        case .stopped: return "stopped"
        case .starting: return "starting"
        case .running: return "running"
        case .waitingToRestart: return "waiting to restart"
        case .failed(let reason): return "failed (\(describe(reason)))"
        }
    }

    private static func describe(_ reason: EngineSupervisor.FailureReason) -> String {
        switch reason {
        case .storeKeyMismatch: return "saved readings can't be opened"
        case .storeInUse: return "already running elsewhere"
        case .storeDamaged: return "saved readings can't be read"
        case .configurationUnreadable: return "saved settings can't be read"
        case .portInUse: return "port in use by another app"
        case .httpsOnStatusPort: return "Tailscale HTTPS on the status port"
        case .recoveryMoveFailed: return "recovery move failed"
        }
    }

    /// describe names the built-in public address and where it is, never its
    /// host or a failure message.
    private static func describe(_ route: BuiltInRouteState) -> String {
        let state: String
        switch route {
        case .ready: state = "ready"
        case .starting: state = "starting"
        case .signIn: state = "waiting for sign-in"
        case .approve: state = "waiting for approval"
        case .enableFunnel: state = "waiting for Funnel to be turned on"
        case .settingUp: state = "setting up"
        case .publishing: state = "publishing"
        case .notReachable: state = "not reachable"
        case .notAnswering: state = "not answering"
        case .waitingForInternet: state = "waiting for the internet"
        case .stopped: state = "stopped"
        case .failed: state = "failed"
        }
        return "public address (built-in), \(state)"
    }

    private static func describe(_ reach: NetworkReach) -> String {
        switch reach {
        case .thisMacOnly: return "This Mac only"
        case .myTailnet: return "My tailnet"
        }
    }
}
