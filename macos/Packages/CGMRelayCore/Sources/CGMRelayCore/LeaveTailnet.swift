import Foundation

/// LeaveTrigger is a way out of the built-in Tailscale route.
public enum LeaveTrigger: Sendable, Equatable {
    case chooseOwnTailscale
    case chooseThisMacOnly
}

/// LeaveStep is one step of leaving the built-in route, in the order it runs.
public enum LeaveStep: Sendable, Equatable {
    /// leave has the engine log this Mac out of the person's Tailscale account
    /// and waits for its answer.
    case leave
    /// stopEngine stops the engine. No way out of the built-in route has it
    /// today; the engine stops only after a leave.
    case stopEngine
    /// applyChoice makes the change the person asked for: the new route.
    case applyChoice
}

/// LeaveTailnetSequence is the order of steps for each way out of the built-in
/// route. The leave comes first because the node that logs out lives in the
/// engine, so the engine must still be running; nothing is left when the route
/// was not on.
public enum LeaveTailnetSequence {
    public static func steps(for trigger: LeaveTrigger, builtInOn: Bool) -> [LeaveStep] {
        let leave: [LeaveStep] = builtInOn ? [.leave] : []
        switch trigger {
        case .chooseOwnTailscale, .chooseThisMacOnly:
            return leave + [.applyChoice]
        }
    }
}

/// LeaveTailnetOutcome is how a leave ended, as far as this Mac knows.
public enum LeaveTailnetOutcome: Sendable, Equatable {
    /// removed means this Mac's Tailscale sign-in is gone and its folder with it.
    case removed
    /// notYetRemoved means the logout did not reach Tailscale, so the folder and
    /// key were kept and this Mac may still be listed on the account.
    case notYetRemoved

    /// record remembers the outcome, so the next launch knows whether to retry.
    public static func record(_ outcome: LeaveTailnetOutcome, into settings: inout AppSettings) {
        settings.pendingLeaveRetry = outcome == .notYetRemoved
    }

    /// shouldRetryLeave is whether this launch must try the leave again. It
    /// holds even though the built-in route is off by now.
    public static func shouldRetryLeave(settings: AppSettings) -> Bool {
        settings.pendingLeaveRetry
    }

    /// attachesKeptFolder is whether the engine is given the folder a failed
    /// leave kept, so its node can log out again. Only while a retry is running
    /// and the built-in route is off: any other start, restart included, runs
    /// without the node, so the public address does not come back.
    public static func attachesKeptFolder(settings: AppSettings, retryRunning: Bool) -> Bool {
        retryRunning && settings.pendingLeaveRetry && !settings.useBuiltInTailscale
    }
}
