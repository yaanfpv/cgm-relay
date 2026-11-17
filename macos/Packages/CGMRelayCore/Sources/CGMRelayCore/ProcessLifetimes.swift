import Foundation

/// ProcessLifetimes is the one owner of when the engine and the logout child
/// count as running. A process whose end was not confirmed counts as running
/// until the app quits: no later report, setting or call releases it, so
/// nothing that would use what that process holds (the Tailscale folder, the
/// keep-awake hold, a second process) is allowed by an end nobody saw.
@MainActor
public final class ProcessLifetimes {
    /// Lifetime is where one process stands. Only a confirmed end is ended;
    /// notConfirmed is final for the life of the object.
    public enum Lifetime: Sendable, Equatable {
        case none
        case running
        /// confirming is an engine that was asked to stop and whose end is
        /// still being waited for.
        case confirming
        case ended
        case notConfirmed
    }

    public private(set) var engine: Lifetime = .none
    public private(set) var leaveChild: Lifetime = .none
    private var engineUsesKeptFolder = true

    /// onChange is called after every change to what the answers below say.
    public var onChange: (() -> Void)?

    public init() {}

    /// engineStarted records an engine that is starting or restarting.
    /// usingKeptFolder is whether it was configured to use the kept Tailscale
    /// folder; an engine whose end is not confirmed holds it whatever it was.
    public func engineStarted(usingKeptFolder: Bool = true) {
        guard engine != .notConfirmed else { return }
        set(engine: .running, usingKeptFolder: usingKeptFolder)
    }

    /// engineStopRequested records that the engine was asked to stop and its
    /// end is being waited for.
    public func engineStopRequested() {
        guard engine == .running else { return }
        set(engine: .confirming, usingKeptFolder: engineUsesKeptFolder)
    }

    /// engineEnded records how the wait for the engine's end came out.
    public func engineEnded(confirmed: Bool) {
        guard engine != .notConfirmed else { return }
        set(engine: confirmed ? .ended : .notConfirmed, usingKeptFolder: engineUsesKeptFolder)
    }

    public func leaveChildStarted() {
        guard leaveChild != .notConfirmed else { return }
        set(leaveChild: .running)
    }

    public func leaveChildEnded(confirmed: Bool) {
        guard leaveChild != .notConfirmed else { return }
        set(leaveChild: confirmed ? .ended : .notConfirmed)
    }

    private var engineHoldsFolder: Bool {
        switch engine {
        case .notConfirmed: return true
        case .running, .confirming: return engineUsesKeptFolder
        case .none, .ended: return false
        }
    }

    private var leaveChildHoldsFolder: Bool {
        leaveChild == .running || leaveChild == .notConfirmed
    }

    /// holdsTailscaleFolder is whether a process that is or may be running
    /// uses the kept Tailscale folder.
    public var holdsTailscaleFolder: Bool { engineHoldsFolder || leaveChildHoldsFolder }

    /// engineUnsettled is whether an engine may still be running that nothing
    /// has confirmed gone: its end was not confirmed, or is still being waited
    /// for. Every answer that lets something go reads it.
    private var engineUnsettled: Bool { engine == .notConfirmed || engine == .confirming }

    /// builtInChoiceBlocked is whether Use Built-In Tailscale must wait: a
    /// leave child is, or may be, running on the folder, or an engine's end
    /// was not confirmed or is still being waited for.
    public var builtInChoiceBlocked: Bool { leaveChildHoldsFolder || engineUnsettled }

    /// mayStartLeaveChild is whether a leave child may be launched on the kept
    /// folder.
    public var mayStartLeaveChild: Bool { !holdsTailscaleFolder && engine != .confirming }

    /// keepAwakeMayBeReleased is whether no engine may still be running, so
    /// the keep-awake hold may let go.
    public var keepAwakeMayBeReleased: Bool { !engineUnsettled }

    /// mayReleaseBoundAddress is whether no engine may still be running, so
    /// the address it was started on may be dropped.
    public var mayReleaseBoundAddress: Bool { !engineUnsettled }

    /// mayStartEngine is whether an engine may be started: no earlier engine
    /// may still be running, and one that would use the kept folder waits for
    /// a leave child that is, or may be, running on it.
    public func mayStartEngine(onKeptFolder: Bool) -> Bool {
        !engineUnsettled && !(onKeptFolder && leaveChildHoldsFolder)
    }

    /// engineStateReported records what the supervisor reported: a start is a
    /// running engine, and every failure but engineStatusUnknown is a
    /// confirmed end. A stopped report records nothing; the end a stop waits
    /// for is recorded by engineEnded when the wait comes out.
    public func engineStateReported(_ state: EngineSupervisor.RunState, usingKeptFolder: Bool) {
        switch state {
        case .starting:
            engineStarted(usingKeptFolder: usingKeptFolder)
        case .failed(let reason):
            engineEnded(confirmed: reason != .engineStatusUnknown)
        case .stopped, .running, .waitingToRestart:
            break
        }
    }

    private func set(engine next: Lifetime, usingKeptFolder: Bool) {
        let changed = engine != next || engineUsesKeptFolder != usingKeptFolder
        engine = next
        engineUsesKeptFolder = usingKeptFolder
        if changed { onChange?() }
    }

    private func set(leaveChild next: Lifetime) {
        guard leaveChild != next else { return }
        leaveChild = next
        onChange?()
    }
}
