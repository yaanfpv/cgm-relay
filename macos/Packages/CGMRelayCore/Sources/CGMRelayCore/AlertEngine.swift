import Foundation

/// AlertKind names the two alerts the Alerts pane can turn on.
public enum AlertKind: Sendable, Equatable {
    case noReading
    case signInFailing
}

/// AlertEngine decides when each alert fires, from nothing but the status
/// updates AppModel already receives every poll and a clock: fed by the
/// same VirtualClock EngineSupervisor and StatusPoller already use, so it
/// is driven by FakeVirtualClock in tests with no timer, no real wait, and
/// no UNUserNotificationCenter anywhere near it. Each alert fires once per
/// episode -- the no-reading alert again only once a new reading has
/// arrived and the gap has reopened; the sign-in alert again only once
/// sign-in has recovered and then failed again -- which is why this needs
/// to remember state between calls rather than being a pure function of
/// one status alone.
public actor AlertEngine {
    private let clock: any VirtualClock

    private var noReadingEnabled = false
    private var noReadingThreshold: Duration = .seconds(20 * 60)
    private var lastKnownReadingTime: Date?
    private var gapStartedAt: Duration?
    private var noReadingAlertFired = false

    private var signInFailingEnabled = false
    private var signInFailingAlertFired = false

    /// pausedForEngineStop is true only while the person has deliberately
    /// stopped the engine (AppModel.stop/signOut, never a crash): nothing
    /// is polling while it should run, so no reading is expected to
    /// arrive, and time spent here must never count toward the no-reading
    /// gap or fire the alert on its own.
    private var pausedForEngineStop = false

    public init(clock: any VirtualClock = SystemVirtualClock()) {
        self.clock = clock
    }

    /// setNoReadingAlert turns the no-reading alert on or off and sets its
    /// threshold. Toggling enabled (either direction) clears every bit of
    /// this alert's own remembered state, so turning it back on always
    /// starts counting a fresh gap rather than immediately firing for a
    /// gap that opened while it was off.
    public func setNoReadingAlert(enabled: Bool, minutes: Int) {
        noReadingThreshold = .seconds(minutes * 60)
        if enabled != noReadingEnabled {
            gapStartedAt = nil
            lastKnownReadingTime = nil
            noReadingAlertFired = false
        }
        noReadingEnabled = enabled
    }

    /// setSignInFailingAlert turns the sign-in alert on or off. Toggling
    /// it clears whether this episode already fired, for the same reason
    /// setNoReadingAlert does.
    public func setSignInFailingAlert(enabled: Bool) {
        if enabled != signInFailingEnabled {
            signInFailingAlertFired = false
        }
        signInFailingEnabled = enabled
    }

    /// pauseForEngineStop suspends the no-reading gap the moment the
    /// person deliberately stops the engine: it clears whatever gap was
    /// already open, exactly like toggling the alert off and back on,
    /// since nothing that happens while nothing is running is evidence of
    /// a real gap. A crash or a failed poll never calls this -- only an
    /// explicit stop -- which is what keeps this alert honest about the
    /// difference between "nothing is running" and "something is wrong."
    public func pauseForEngineStop() {
        pausedForEngineStop = true
        gapStartedAt = nil
        lastKnownReadingTime = nil
        noReadingAlertFired = false
    }

    /// resumeAfterEngineStart lifts the pause: the very next status
    /// update starts counting a fresh gap from that moment, never from
    /// however long the engine happened to be stopped for.
    public func resumeAfterEngineStart() {
        pausedForEngineStop = false
    }

    /// handleStatusUpdate is called on every status update AppModel
    /// receives, whether or not anything in it changed, and returns every
    /// alert that newly fired because of this particular call.
    public func handleStatusUpdate(_ status: EngineStatus?) async -> [AlertKind] {
        var fired: [AlertKind] = []
        let now = await clock.now()

        if noReadingEnabled, !pausedForEngineStop {
            if gapStartedAt == nil {
                gapStartedAt = now
            }
            if let currentReadingTime = status?.lastReadingTime, currentReadingTime != lastKnownReadingTime {
                lastKnownReadingTime = currentReadingTime
                gapStartedAt = now
                noReadingAlertFired = false
            }
            if let gapStartedAt, !noReadingAlertFired, now - gapStartedAt >= noReadingThreshold {
                noReadingAlertFired = true
                fired.append(.noReading)
            }
        }

        if signInFailingEnabled {
            let failing = status?.signInFailing ?? false
            if failing {
                if !signInFailingAlertFired {
                    signInFailingAlertFired = true
                    fired.append(.signInFailing)
                }
            } else {
                signInFailingAlertFired = false
            }
        }

        return fired
    }
}
