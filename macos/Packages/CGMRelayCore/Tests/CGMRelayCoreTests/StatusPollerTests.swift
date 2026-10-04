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

    @Test("the URLSession fetcher sends nothing until the secret is armed, then presents it on /status")
    func fetcherSendsTheSecretHeaderOnlyOnceArmed() async throws {
        let url = URL(string: "http://127.0.0.1:1/status-\(UUID().uuidString)")!
        let seen = LockedBox<[String?]>([])
        StubURLProtocol.register(url: url) { request in
            seen.update { $0.append(request.value(forHTTPHeaderField: LocalStatusSecret.headerName)) }
            return (200, Data(#"{"running":true,"sign_in_failing":false}"#.utf8))
        }
        let secret = LocalStatusSecret(randomBytes: FakeRandomBytesGenerator())
        let fetcher = URLSessionStatusFetcher(
            statusURL: url,
            secret: secret,
            session: LoopbackURLSession.make(protocolClasses: [StubURLProtocol.self])
        )

        await #expect(throws: StatusFetchError.notReady) { try await fetcher.fetchStatus() }
        let launchSecret = try secret.renew()
        await #expect(throws: StatusFetchError.notReady) { try await fetcher.fetchStatus() }
        #expect(seen.value.isEmpty, "no request may leave while the secret is not armed")

        secret.arm(launchSecret)
        _ = try await fetcher.fetchStatus()

        #expect(seen.value == [launchSecret])
    }

    @Test("the URLSession pairing minter sends nothing until the secret is armed, then presents it when minting")
    func minterSendsTheSecretHeaderOnlyOnceArmed() async throws {
        let url = URL(string: "http://127.0.0.1:1/pairing-\(UUID().uuidString)")!
        let seen = LockedBox<[String?]>([])
        StubURLProtocol.register(url: url) { request in
            seen.update { $0.append(request.value(forHTTPHeaderField: LocalStatusSecret.headerName)) }
            return (200, Data(#"{"code":"abc","expires_at":"2026-06-01T12:10:00Z"}"#.utf8))
        }
        let secret = LocalStatusSecret(randomBytes: FakeRandomBytesGenerator())
        let launchSecret = try secret.renew()
        let minter = URLSessionPairingCodeMinter(
            pairingURL: url,
            secret: secret,
            session: LoopbackURLSession.make(protocolClasses: [StubURLProtocol.self])
        )

        await #expect(throws: PairingCodeMintingError.notReady) { try await minter.mint(apps: []) }
        #expect(seen.value.isEmpty, "no request may leave while the secret is not armed")

        secret.arm(launchSecret)
        let code = try await minter.mint(apps: [])

        #expect(code.code == "abc")
        #expect(seen.value == [launchSecret])
    }

    @Test("a redirect is never followed, so the secret never reaches a second endpoint")
    func redirectsAreNotFollowed() async throws {
        let start = URL(string: "http://127.0.0.1:1/status-\(UUID().uuidString)")!
        let target = URL(string: "http://127.0.0.1:2/elsewhere-\(UUID().uuidString)")!
        let targetRequests = LockedBox<Int>(0)
        StubURLProtocol.registerRedirect(from: start, to: target)
        StubURLProtocol.register(url: target) { _ in
            targetRequests.update { $0 += 1 }
            return (200, Data(#"{"running":true,"sign_in_failing":false}"#.utf8))
        }
        let secret = LocalStatusSecret(randomBytes: FakeRandomBytesGenerator())
        secret.arm(try secret.renew())
        let fetcher = URLSessionStatusFetcher(
            statusURL: start,
            secret: secret,
            session: LoopbackURLSession.make(protocolClasses: [StubURLProtocol.self])
        )

        await #expect(throws: StatusFetchError.unexpectedResponse) { try await fetcher.fetchStatus() }
        try await Task.sleep(for: .milliseconds(50))

        #expect(targetRequests.value == 0, "the redirect target must never be requested")
    }

    @Test("the loopback session bypasses every system proxy")
    func loopbackSessionHasNoProxy() {
        let configuration = LoopbackURLSession.make().configuration
        #expect(configuration.connectionProxyDictionary?.isEmpty == true)
    }
}

/// LockedBox is a value a stubbed request handler, which runs off the test's
/// own task, can append to safely.
private final class LockedBox<Value: Sendable>: @unchecked Sendable {
    private let lock = NSLock()
    private var stored: Value

    init(_ value: Value) { stored = value }

    var value: Value { lock.withLock { stored } }

    func update(_ change: (inout Value) -> Void) {
        lock.withLock { change(&stored) }
    }
}
