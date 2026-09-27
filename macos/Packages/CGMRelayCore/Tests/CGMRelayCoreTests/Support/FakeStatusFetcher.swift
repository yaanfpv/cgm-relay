import CGMRelayCore
import Foundation

/// FakeStatusFetcher hands back a scripted result -- a status or an
/// error -- each time it is called, and counts how many times it was.
final class FakeStatusFetcher: StatusFetcher, @unchecked Sendable {
    private let lock = NSLock()
    private var results: [Result<EngineStatus, Error>]
    private var _callCount = 0

    init(results: [Result<EngineStatus, Error>]) {
        self.results = results
    }

    var callCount: Int {
        lock.withLock { _callCount }
    }

    func fetchStatus() async throws -> EngineStatus {
        let result = lock.withLock {
            let index = min(_callCount, results.count - 1)
            _callCount += 1
            return results[index]
        }
        return try result.get()
    }
}
