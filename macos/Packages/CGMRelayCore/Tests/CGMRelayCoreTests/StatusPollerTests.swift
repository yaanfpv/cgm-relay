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

    // MARK: - A check begun before a stop or a discard never lands after it

    @Test("a fetch still in flight when stop is called is dropped: no status written, none delivered")
    func stopDropsTheInFlightFetch() async throws {
        let fetcher = FakeStatusFetcher(results: [.success(EngineStatus(running: true, lastReadingMgDl: 100))])
        let observed = ObservedUpdates<EngineStatus?>()
        let poller = StatusPoller(fetcher: fetcher, clock: FakeVirtualClock(), interval: .seconds(30)) { status in
            observed.append(status)
        }

        fetcher.holdNextFetch()
        let check = Task { await poller.pollNow() }
        #expect(await waitUntil { fetcher.heldCount == 1 })

        await poller.stop()
        fetcher.releaseHeld()
        await check.value

        #expect(await poller.latestStatus == nil, "a status fetched before the stop must not be written after it")
        #expect(!observed.values.contains { $0 != nil }, "a status fetched before the stop must not be delivered after it")
    }

    @Test("stop still reports nil exactly once when nothing was in flight")
    func stopReportsNilOnce() async throws {
        let fetcher = FakeStatusFetcher(results: [.success(EngineStatus(running: true, lastReadingMgDl: 100))])
        let observed = ObservedUpdates<EngineStatus?>()
        let poller = StatusPoller(fetcher: fetcher, clock: FakeVirtualClock(), interval: .seconds(30)) { status in
            observed.append(status)
        }

        await poller.pollNow()
        await poller.stop()

        #expect(observed.values.count == 2)
        #expect(observed.values[0]?.lastReadingMgDl == 100)
        #expect(observed.values[1] == nil)
    }

    @Test("stop then start before the old fetch lands: the old result is dropped and the new one is kept")
    func oldFetchLosesToTheRestartedLoop() async throws {
        let fetcher = FakeStatusFetcher(results: [
            .success(EngineStatus(running: true, lastReadingMgDl: 100)),
            .success(EngineStatus(running: true, lastReadingMgDl: 200)),
        ])
        let observed = ObservedUpdates<EngineStatus?>()
        let poller = StatusPoller(fetcher: fetcher, clock: FakeVirtualClock(), interval: .seconds(30)) { status in
            observed.append(status)
        }

        fetcher.holdNextFetch()
        let check = Task { await poller.pollNow() }
        #expect(await waitUntil { fetcher.heldCount == 1 })

        await poller.stop()
        await poller.start()
        #expect(await waitUntil { await poller.latestStatus?.lastReadingMgDl == 200 })

        fetcher.releaseHeld()
        await check.value

        #expect(await poller.latestStatus?.lastReadingMgDl == 200, "the old fetch must not overwrite the newer one")
        #expect(!Self.readings(observed).contains(100), "the old result must never be delivered")
        #expect(Self.readings(observed).contains(200), "the newer result must be delivered")

        await poller.stop()
    }

    @Test("discardPending drops the in-flight fetch, leaves the loop running, and the next fetch is kept")
    func discardPendingDropsOnlyTheOldFetch() async throws {
        let fetcher = FakeStatusFetcher(results: [
            .success(EngineStatus(running: true, lastReadingMgDl: 100)),
            .success(EngineStatus(running: true, lastReadingMgDl: 200)),
        ])
        let observed = ObservedUpdates<EngineStatus?>()
        let poller = StatusPoller(fetcher: fetcher, clock: FakeVirtualClock(), interval: .seconds(30)) { status in
            observed.append(status)
        }

        fetcher.holdNextFetch()
        let check = Task { await poller.pollNow() }
        #expect(await waitUntil { fetcher.heldCount == 1 })

        await poller.discardPending()
        await poller.start()
        #expect(await waitUntil { await poller.latestStatus?.lastReadingMgDl == 200 })

        fetcher.releaseHeld()
        await check.value

        #expect(await poller.latestStatus?.lastReadingMgDl == 200, "the discarded fetch must not overwrite the newer one")
        #expect(!Self.readings(observed).contains(100), "the discarded result must never be delivered")
        #expect(Self.readings(observed).contains(200), "the newer result must be delivered")

        await poller.stop()
    }

    @Test("discardPending does not stop the loop: it keeps polling on its interval")
    func discardPendingKeepsTheLoopRunning() async throws {
        let fetcher = FakeStatusFetcher(results: [
            .success(EngineStatus(running: true, lastReadingMgDl: 100)),
            .success(EngineStatus(running: true, lastReadingMgDl: 110)),
        ])
        let clock = FakeVirtualClock()
        let poller = StatusPoller(fetcher: fetcher, clock: clock, interval: .seconds(30))

        await poller.start()
        #expect(await waitUntil { fetcher.callCount == 1 })
        #expect(await waitUntil { await poller.latestStatus?.lastReadingMgDl == 100 })

        await poller.discardPending()
        await clock.advance(by: .seconds(30))

        #expect(await waitUntil { await poller.latestStatus?.lastReadingMgDl == 110 })
        await poller.stop()
    }

    @Test("a discarded fetch's status is not written even when nothing else fetches afterwards")
    func discardPendingLeavesNoStatusBehind() async throws {
        let fetcher = FakeStatusFetcher(results: [.success(EngineStatus(running: true, lastReadingMgDl: 100))])
        let observed = ObservedUpdates<EngineStatus?>()
        let poller = StatusPoller(fetcher: fetcher, clock: FakeVirtualClock(), interval: .seconds(30)) { status in
            observed.append(status)
        }

        fetcher.holdNextFetch()
        let check = Task { await poller.pollNow() }
        #expect(await waitUntil { fetcher.heldCount == 1 })

        await poller.discardPending()
        fetcher.releaseHeld()
        await check.value

        #expect(await poller.latestStatus == nil)
        #expect(observed.values.isEmpty, "a discarded fetch must produce no update at all")
    }

    @Test("a fetch that throws CancellationError produces no write and no update")
    func cancelledFetchIsDropped() async throws {
        let fetcher = FakeStatusFetcher(results: [.failure(CancellationError())])
        let observed = ObservedUpdates<EngineStatus?>()
        let poller = StatusPoller(fetcher: fetcher, clock: FakeVirtualClock(), interval: .seconds(30)) { status in
            observed.append(status)
        }

        await poller.pollNow()

        #expect(fetcher.callCount == 1)
        #expect(await poller.latestStatus == nil)
        #expect(observed.values.isEmpty, "a cancelled check is not a failed check and must not be reported as one")
    }

    @Test("a cancelled fetch leaves the status a good check already wrote")
    func cancelledFetchKeepsThePriorStatus() async throws {
        let fetcher = FakeStatusFetcher(results: [
            .success(EngineStatus(running: true, lastReadingMgDl: 100)),
            .failure(CancellationError()),
        ])
        let observed = ObservedUpdates<EngineStatus?>()
        let poller = StatusPoller(fetcher: fetcher, clock: FakeVirtualClock(), interval: .seconds(30)) { status in
            observed.append(status)
        }

        await poller.pollNow()
        await poller.pollNow()

        #expect(fetcher.callCount == 2)
        #expect(await poller.latestStatus?.lastReadingMgDl == 100, "a cancelled check must not clear the status")
        #expect(observed.values.count == 1, "a cancelled check must not deliver an update")
    }

    // MARK: - AppModel discards before it clears

    @Test("startEngine discards pending checks before it clears the built-in status")
    func startEngineDiscardsBeforeClearing() throws {
        let source = AppModelSource.stripped(try Self.appModelText())
        #expect(StartEngineOrder.violation(in: source) == nil, Comment(rawValue: StartEngineOrder.violation(in: source) ?? ""))
    }

    @Test("the startEngine order check is red when the discard is missing, late, or not awaited")
    func startEngineOrderCheckHasTeeth() {
        let clear = "latestStatus?.builtIn = nil"
        let discard = "await statusPoller.discardPending()"
        func source(_ body: String) -> String { "private func startEngine() async {\n\(body)\n}\n" }
        #expect(StartEngineOrder.violation(in: source("\(discard)\n\(clear)")) == nil)
        #expect(StartEngineOrder.violation(in: source("\(clear)\nrefresh()")) != nil, "no call")
        #expect(StartEngineOrder.violation(in: source("\(clear)\n\(discard)")) != nil, "call after the clear")
        #expect(StartEngineOrder.violation(in: source("statusPoller.discardPending()\n\(clear)")) != nil, "call not awaited")
        #expect(StartEngineOrder.violation(in: source("\(discard)\nrefresh()")) != nil, "no clear to precede")
    }

    private static func readings(_ observed: ObservedUpdates<EngineStatus?>) -> [Int] {
        observed.values.compactMap { (status: EngineStatus?) -> Int? in status?.lastReadingMgDl }
    }

    private static func appModelText() throws -> String {
        var url = URL(fileURLWithPath: #filePath)
        for _ in 0..<5 { url.deleteLastPathComponent() }
        url.appendPathComponent("App/Sources/AppModel.swift")
        return try String(contentsOf: url, encoding: .utf8)
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

/// StartEngineOrder reads startEngine's body (comments and string contents
/// already stripped) because the app has no test target: the awaited
/// discardPending call must come before the line that clears the built-in
/// status, so a check begun earlier cannot restore the old node's status.
private enum StartEngineOrder {
    static func violation(in source: String) -> String? {
        guard let declaration = source.range(of: #"func\s+startEngine\s*\("#, options: .regularExpression),
              let open = source[declaration.upperBound...].firstIndex(of: "{"),
              let close = AppModelSource.closing(source, from: open)
        else { return "startEngine was not found" }
        let body = String(source[open...close])
        guard let discard = body.range(of: #"await\s+(?:self\.)?statusPoller\.discardPending\(\)"#, options: .regularExpression) else {
            return "startEngine does not await statusPoller.discardPending()"
        }
        guard let clear = body.range(of: #"latestStatus\??\.builtIn\s*=\s*nil"#, options: .regularExpression) else {
            return "startEngine no longer clears latestStatus.builtIn, so there is nothing to order against"
        }
        return discard.lowerBound < clear.lowerBound ? nil : "discardPending() comes after the built-in status is cleared"
    }
}
