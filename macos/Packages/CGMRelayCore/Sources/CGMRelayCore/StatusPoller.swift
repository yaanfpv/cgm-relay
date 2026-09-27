import Foundation

/// StatusPoller fetches the engine's status on a slow timer, plus once
/// on demand, and keeps only the latest result. It never runs a
/// per-frame or animation-driven timer: the loop sleeps for the full
/// interval between fetches, so the app costs essentially nothing at
/// idle.
public actor StatusPoller {
    /// defaultInterval is how often the loop started by start() fetches a
    /// fresh status.
    public static let defaultInterval: Duration = .seconds(30)

    private let fetcher: any StatusFetcher
    private let clock: any VirtualClock
    private let interval: Duration
    /// onUpdate is called after every fetch attempt, successful or not,
    /// with the new latestStatus -- so a caller (the menu bar UI) can
    /// react to a fresh reading as soon as it arrives, rather than
    /// polling this actor's own state on some second timer of its own.
    private let onUpdate: @Sendable (EngineStatus?) -> Void

    public private(set) var latestStatus: EngineStatus?
    private var loopTask: Task<Void, Never>?

    public init(
        fetcher: any StatusFetcher,
        clock: any VirtualClock = SystemVirtualClock(),
        interval: Duration = StatusPoller.defaultInterval,
        onUpdate: @escaping @Sendable (EngineStatus?) -> Void = { _ in }
    ) {
        self.fetcher = fetcher
        self.clock = clock
        self.interval = interval
        self.onUpdate = onUpdate
    }

    /// start fetches a status immediately and then every `interval`
    /// thereafter, until stop() is called. Calling it again while already
    /// running does nothing.
    public func start() {
        guard loopTask == nil else { return }
        loopTask = Task { [weak self] in
            guard let self else { return }
            while !Task.isCancelled {
                await self.pollOnce()
                do {
                    try await self.sleepInterval()
                } catch {
                    return
                }
            }
        }
    }

    public func stop() {
        loopTask?.cancel()
        loopTask = nil
        latestStatus = nil
        onUpdate(nil)
    }

    /// pollNow fetches the status immediately, outside the slow timer --
    /// used when the menu opens, so a person never sees a reading that is
    /// only stale because the timer has not fired since it changed.
    public func pollNow() async {
        await pollOnce()
    }

    private func sleepInterval() async throws {
        try await clock.sleep(for: interval)
    }

    private func pollOnce() async {
        do {
            latestStatus = try await fetcher.fetchStatus()
        } catch {
            latestStatus = nil
        }
        onUpdate(latestStatus)
    }
}
