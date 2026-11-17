import CGMRelayCore
import Foundation

/// FakeStatusFetcher hands back a scripted result -- a status or an
/// error -- each time it is called, and counts how many times it was.
///
/// holdNextFetch() makes the next call wait, after its result is chosen,
/// until releaseHeld() lets every held call return, so a test can leave a
/// fetch in flight and finish it when it chooses. heldCount says how many
/// calls are waiting right now.
final class FakeStatusFetcher: StatusFetcher, @unchecked Sendable {
    private let lock = NSLock()
    private var results: [Result<EngineStatus, Error>]
    private var _callCount = 0
    private var holdNext = false
    private var waiters: [CheckedContinuation<Void, Never>] = []

    init(results: [Result<EngineStatus, Error>]) {
        self.results = results
    }

    var callCount: Int {
        lock.withLock { _callCount }
    }

    var heldCount: Int {
        lock.withLock { waiters.count }
    }

    func holdNextFetch() {
        lock.withLock { holdNext = true }
    }

    func releaseHeld() {
        let released = lock.withLock {
            let held = waiters
            waiters = []
            return held
        }
        for waiter in released { waiter.resume() }
    }

    func fetchStatus() async throws -> EngineStatus {
        let (result, hold) = lock.withLock {
            let index = min(_callCount, results.count - 1)
            _callCount += 1
            let hold = holdNext
            holdNext = false
            return (results[index], hold)
        }
        if hold {
            await withCheckedContinuation { continuation in
                lock.withLock { waiters.append(continuation) }
            }
        }
        return try result.get()
    }
}
