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
    /// key were kept and this Mac's key may still be working.
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

    /// fromLeaveChild is the outcome of the `cgm-relay leave-tailnet` child by
    /// its exit code: only 0 (logged out, folder removed) is removed. Exit 3
    /// (kept for retry), 2 (bad request), a crash, a signal death and a
    /// timeout all leave the folder, so the leave stays pending.
    public static func fromLeaveChild(exitCode: Int32) -> LeaveTailnetOutcome {
        exitCode == 0 ? .removed : .notYetRemoved
    }

    /// loggingOutNotice is what the route area says while a leave child runs.
    public static let loggingOutNotice = "Logging this Mac out of Tailscale\u{2026}"

    /// builtInChoiceBlockedReason is why Use Built-In Tailscale cannot be
    /// chosen right now, nil when it can. The child works on the folder the
    /// built-in route would use, so the choice waits for it to end. The
    /// private choices are never blocked.
    public static func builtInChoiceBlockedReason(leaveChildRunning: Bool) -> String? {
        leaveChildRunning ? loggingOutNotice : nil
    }

    /// shouldRunLeaveChild is whether the leave child runs now: a leave is
    /// pending, the built-in route is off, and the engine is not holding the
    /// folder. It needs no LibreLinkUp sign-in, since the child reads none.
    public static func shouldRunLeaveChild(settings: AppSettings, engineHoldsFolder: Bool) -> Bool {
        settings.pendingLeaveRetry && !settings.useBuiltInTailscale && !engineHoldsFolder
    }
}
