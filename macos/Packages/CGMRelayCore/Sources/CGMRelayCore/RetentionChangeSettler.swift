import Foundation

/// RetentionChangeSettler turns a burst of stepper clicks into one decision:
/// each proposed value restarts a short wait, and only the final value is
/// handed on, once the clicks stop or when the person's focus leaves the row.
/// It has no UI, so a test drives it with a VirtualClock.
@MainActor
public final class RetentionChangeSettler {
    public static let settleDelay: Duration = .seconds(1)

    /// onSettled receives the final value of a burst, once.
    public var onSettled: (Int) -> Void

    private let clock: any VirtualClock
    private var timer: Task<Void, Never>?

    /// pendingValue is the latest proposed value not yet handed on.
    public private(set) var pendingValue: Int?

    public init(clock: any VirtualClock = SystemVirtualClock(), onSettled: @escaping (Int) -> Void = { _ in }) {
        self.clock = clock
        self.onSettled = onSettled
    }

    /// propose records value as the latest and restarts the wait.
    public func propose(_ value: Int) {
        pendingValue = value
        timer?.cancel()
        timer = Task { [clock] in
            do {
                try await clock.sleep(for: Self.settleDelay)
            } catch {
                return
            }
            guard !Task.isCancelled else { return }
            settle()
        }
    }

    /// flush hands on the pending value now, if there is one.
    public func flush() {
        settle()
    }

    /// cancel drops the pending value without handing it on.
    public func cancel() {
        timer?.cancel()
        timer = nil
        pendingValue = nil
    }

    private func settle() {
        timer?.cancel()
        timer = nil
        guard let value = pendingValue else { return }
        pendingValue = nil
        onSettled(value)
    }
}
