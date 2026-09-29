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
        followerAges: [(client: String, age: String)]
    ) -> String {
        var lines: [String] = [
            "CGM Relay \(appVersion) (\(buildNumber))",
            "macOS \(macOSVersion)",
            "Engine: \(describe(engineState))",
            "Last error: \(lastError ?? "none")",
            "Reach: \(describe(reach))",
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

        return lines.joined(separator: "\n")
    }

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
        case .recoveryMoveFailed: return "recovery move failed"
        }
    }

    private static func describe(_ reach: NetworkReach) -> String {
        switch reach {
        case .thisMacOnly: return "This Mac only"
        case .myTailnet: return "My tailnet"
        case .myLocalNetwork: return "My local network"
        }
    }
}
