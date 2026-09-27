import Foundation

/// VirtualClock abstracts elapsed time and sleeping, the same way the
/// engine's own `internal/poller.Clock` abstracts `time.Now` and its
/// timers, so a test can drive backoff and polling schedules without a
/// real wait. Production code uses SystemVirtualClock; tests use a fake
/// that advances time under their own control.
public protocol VirtualClock: Sendable {
    /// now returns how much time has elapsed on this clock since it was
    /// created, monotonically increasing.
    func now() async -> Duration
    /// sleep suspends the caller for exactly `duration` on this clock's
    /// own scale.
    func sleep(for duration: Duration) async throws
}

/// SystemVirtualClock is the production VirtualClock, backed by a real
/// ContinuousClock.
public struct SystemVirtualClock: VirtualClock {
    private let clock = ContinuousClock()
    private let start: ContinuousClock.Instant

    public init() {
        start = ContinuousClock.now
    }

    public func now() async -> Duration {
        clock.now - start
    }

    public func sleep(for duration: Duration) async throws {
        try await Task.sleep(for: duration, clock: clock)
    }
}
