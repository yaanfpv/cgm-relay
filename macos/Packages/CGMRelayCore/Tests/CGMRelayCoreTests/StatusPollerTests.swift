import Testing
import Foundation
@testable import CGMRelayCore

@Suite("StatusPoller")
struct StatusPollerTests {
    @Test("start fetches immediately, before the first interval elapses")
    func fetchesImmediatelyOnStart() async throws {
        let fetcher = FakeStatusFetcher(results: [.success(EngineStatus(running: true, lastReadingMgDl: 100))])
        let clock = FakeVirtualClock()
        let poller = StatusPoller(fetcher: fetcher, clock: clock, interval: .seconds(30))

        await poller.start()

        #expect(await waitUntil { fetcher.callCount == 1 })
        #expect(await poller.latestStatus?.lastReadingMgDl == 100)

        await poller.stop()
    }

    @Test("does not fetch again before the interval elapses")
    func doesNotFetchEarly() async throws {
        let fetcher = FakeStatusFetcher(results: [
            .success(EngineStatus(running: true, lastReadingMgDl: 100)),
            .success(EngineStatus(running: true, lastReadingMgDl: 110)),
        ])
        let clock = FakeVirtualClock()
        let poller = StatusPoller(fetcher: fetcher, clock: clock, interval: .seconds(30))

        await poller.start()
        #expect(await waitUntil { fetcher.callCount == 1 })

        await clock.advance(by: .seconds(10))
        try await Task.sleep(for: .milliseconds(20))
        #expect(fetcher.callCount == 1, "must wait the full interval before fetching again")

        await clock.advance(by: .seconds(20))
        #expect(await waitUntil { fetcher.callCount == 2 })
        #expect(await poller.latestStatus?.lastReadingMgDl == 110)

        await poller.stop()
    }

    @Test("pollNow fetches immediately, independent of the timer")
    func pollNowFetchesImmediately() async throws {
        let fetcher = FakeStatusFetcher(results: [
            .success(EngineStatus(running: true, lastReadingMgDl: 100)),
            .success(EngineStatus(running: true, lastReadingMgDl: 130)),
        ])
        let clock = FakeVirtualClock()
        let poller = StatusPoller(fetcher: fetcher, clock: clock, interval: .seconds(30))

        await poller.start()
        #expect(await waitUntil { fetcher.callCount == 1 })

        await poller.pollNow()
        #expect(fetcher.callCount == 2)
        #expect(await poller.latestStatus?.lastReadingMgDl == 130)

        await poller.stop()
    }

    @Test("a fetch failure clears the latest status rather than leaving a stale one")
    func failureClearsStatus() async throws {
        let fetcher = FakeStatusFetcher(results: [
            .success(EngineStatus(running: true, lastReadingMgDl: 100)),
            .failure(StatusFetchError.unexpectedResponse),
        ])
        let clock = FakeVirtualClock()
        let poller = StatusPoller(fetcher: fetcher, clock: clock, interval: .seconds(30))

        await poller.start()
        #expect(await waitUntil { fetcher.callCount == 1 })

        await poller.pollNow()
        #expect(await poller.latestStatus == nil)

        await poller.stop()
    }

    @Test("onUpdate fires after every poll attempt, successful or not")
    func onUpdateFiresOnEveryAttempt() async throws {
        let fetcher = FakeStatusFetcher(results: [
            .success(EngineStatus(running: true, lastReadingMgDl: 100)),
            .failure(StatusFetchError.unexpectedResponse),
        ])
        let clock = FakeVirtualClock()
        let observed = ObservedUpdates<EngineStatus?>()
        let poller = StatusPoller(fetcher: fetcher, clock: clock, interval: .seconds(30)) { status in
            observed.append(status)
        }

        await poller.start()
        #expect(await waitUntil { fetcher.callCount == 1 })
        await poller.pollNow()

        #expect(observed.values.count == 2)
        #expect(observed.values[0]?.lastReadingMgDl == 100)
        #expect(observed.values[1] == nil)

        await poller.stop()
    }

    @Test("stop ends the loop and clears the latest status")
    func stopEndsLoop() async throws {
        let fetcher = FakeStatusFetcher(results: [.success(EngineStatus(running: true, lastReadingMgDl: 100))])
        let clock = FakeVirtualClock()
        let poller = StatusPoller(fetcher: fetcher, clock: clock, interval: .seconds(30))

        await poller.start()
        #expect(await waitUntil { fetcher.callCount == 1 })

        await poller.stop()
        #expect(await poller.latestStatus == nil)

        await clock.advance(by: .seconds(60))
        try await Task.sleep(for: .milliseconds(30))
        #expect(fetcher.callCount == 1, "the loop must not keep polling after stop")
    }
}
