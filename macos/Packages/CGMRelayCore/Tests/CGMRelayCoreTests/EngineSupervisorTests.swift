import Testing
import Foundation
@testable import CGMRelayCore

@Suite("EngineSupervisor")
struct EngineSupervisorTests {
    static let engineURL = URL(fileURLWithPath: "/usr/bin/true")

    @Test("start launches exactly one process with the config-stdin contract")
    func startLaunchesWithContractArguments() async throws {
        let launcher = FakeProcessLauncher()
        let clock = FakeVirtualClock()
        let supervisor = EngineSupervisor(engineURL: Self.engineURL, launcher: launcher, clock: clock)
        let config = EngineConfiguration.fixture()

        await supervisor.start(configuration: config)

        #expect(launcher.launchCount == 1)
        let record = launcher.launchRecords()[0]
        #expect(record.arguments == ["serve", "--config-stdin"])
        // The encoder's own key order is not guaranteed stable across
        // separate calls, so the stdin bytes are decoded back and
        // compared as a value, never compared as raw bytes.
        let decoded = try JSONDecoder().decode(EngineConfiguration.self, from: record.standardInputData)
        #expect(decoded == config)
        #expect(await supervisor.state == .running)
    }

    @Test("start is a no-op while already running")
    func startWhileRunningIsANoOp() async throws {
        let launcher = FakeProcessLauncher()
        let clock = FakeVirtualClock()
        let supervisor = EngineSupervisor(engineURL: Self.engineURL, launcher: launcher, clock: clock)
        await supervisor.start(configuration: .fixture())
        await supervisor.start(configuration: .fixture())
        #expect(launcher.launchCount == 1)
    }

    @Test("an unexpected exit is followed by a restart after the first backoff delay")
    func restartsAfterBackoffDelay() async throws {
        let launcher = FakeProcessLauncher()
        let clock = FakeVirtualClock()
        let supervisor = EngineSupervisor(engineURL: Self.engineURL, launcher: launcher, clock: clock)
        await supervisor.start(configuration: .fixture())

        launcher.finishLaunch(at: 0, exitCode: 1)
        #expect(await waitUntil { await clock.sleepRequests.count == 1 })
        #expect(await clock.sleepRequests == [.seconds(2)])
        #expect(launcher.launchCount == 1, "must not restart before the backoff delay elapses")

        await clock.advance(by: .seconds(2))
        #expect(await waitUntil { launcher.launchCount == 2 })
        #expect(await supervisor.state == .running)
    }

    @Test("repeated quick failures escalate through the full backoff schedule and then hold")
    func escalatesThroughBackoffSchedule() async throws {
        let schedule: [Duration] = [.seconds(2), .seconds(5), .seconds(15), .seconds(60)]
        let launcher = FakeProcessLauncher()
        let clock = FakeVirtualClock()
        let supervisor = EngineSupervisor(
            engineURL: Self.engineURL,
            launcher: launcher,
            clock: clock,
            backoffSchedule: schedule,
            stableRunThreshold: .seconds(600)
        )
        await supervisor.start(configuration: .fixture())

        for (index, delay) in schedule.enumerated() {
            launcher.finishLaunch(at: index, exitCode: 1)
            #expect(await waitUntil { await clock.sleepRequests.count == index + 1 })
            #expect(await clock.sleepRequests.last == delay)
            await clock.advance(by: delay)
            #expect(await waitUntil { launcher.launchCount == index + 2 })
        }

        // One more failure past the end of the schedule holds at the last delay.
        launcher.finishLaunch(at: schedule.count, exitCode: 1)
        #expect(await waitUntil { await clock.sleepRequests.count == schedule.count + 1 })
        #expect(await clock.sleepRequests.last == schedule.last)

        // Drain the still-pending backoff wait so nothing outlives the test.
        await supervisor.stop()
        await clock.advance(by: schedule.last ?? .zero)
        try await Task.sleep(for: .milliseconds(20))
    }

    @Test("a run longer than the stable threshold resets the backoff attempt counter")
    func stableRunResetsBackoff() async throws {
        let launcher = FakeProcessLauncher()
        let clock = FakeVirtualClock()
        let supervisor = EngineSupervisor(
            engineURL: Self.engineURL,
            launcher: launcher,
            clock: clock,
            backoffSchedule: [.seconds(2), .seconds(5), .seconds(15), .seconds(60)],
            stableRunThreshold: .seconds(60)
        )
        await supervisor.start(configuration: .fixture())

        // First failure: escalates the attempt counter to use the 2s delay.
        launcher.finishLaunch(at: 0, exitCode: 1)
        #expect(await waitUntil { await clock.sleepRequests.count == 1 })
        #expect(await clock.sleepRequests == [.seconds(2)])
        await clock.advance(by: .seconds(2))
        #expect(await waitUntil { launcher.launchCount == 2 })

        // This run lasts past the stable threshold before it exits.
        await clock.advance(by: .seconds(90))
        launcher.finishLaunch(at: 1, exitCode: 1)

        #expect(await waitUntil { await clock.sleepRequests.count == 2 })
        #expect(await clock.sleepRequests.last == .seconds(2), "the reset attempt counter should reuse the first delay, not escalate")

        await supervisor.stop()
        await clock.advance(by: .seconds(2))
        try await Task.sleep(for: .milliseconds(20))
    }

    @Test("onStateChange fires for every state transition")
    func onStateChangeFiresForEveryTransition() async throws {
        let launcher = FakeProcessLauncher()
        let clock = FakeVirtualClock()
        let observed = ObservedUpdates<EngineSupervisor.RunState>()
        let supervisor = EngineSupervisor(
            engineURL: Self.engineURL,
            launcher: launcher,
            clock: clock
        ) { state in
            observed.append(state)
        }

        await supervisor.start(configuration: .fixture())
        await supervisor.stop()

        #expect(observed.values == [.starting, .running, .stopped])
    }

    @Test("stop terminates the running process and leaves it stopped")
    func stopTerminatesRunningProcess() async throws {
        let launcher = FakeProcessLauncher()
        let clock = FakeVirtualClock()
        let supervisor = EngineSupervisor(engineURL: Self.engineURL, launcher: launcher, clock: clock)
        await supervisor.start(configuration: .fixture())

        await supervisor.stop()

        #expect(launcher.wasTerminated(at: 0))
        #expect(await supervisor.state == .stopped)
    }

    @Test("an exit reported after stop does not trigger a restart")
    func exitAfterStopDoesNotRestart() async throws {
        let launcher = FakeProcessLauncher()
        let clock = FakeVirtualClock()
        let supervisor = EngineSupervisor(engineURL: Self.engineURL, launcher: launcher, clock: clock)
        await supervisor.start(configuration: .fixture())
        await supervisor.stop()

        // The OS still calls the termination handler asynchronously, after
        // stop() has already run -- this must never schedule a restart.
        launcher.finishLaunch(at: 0, exitCode: -15)
        try await Task.sleep(for: .milliseconds(30))

        #expect(launcher.launchCount == 1)
        #expect(await supervisor.state == .stopped)
    }

    @Test("stop during a backoff wait cancels the pending restart")
    func stopDuringBackoffCancelsRestart() async throws {
        let launcher = FakeProcessLauncher()
        let clock = FakeVirtualClock()
        let supervisor = EngineSupervisor(engineURL: Self.engineURL, launcher: launcher, clock: clock)
        await supervisor.start(configuration: .fixture())

        launcher.finishLaunch(at: 0, exitCode: 1)
        #expect(await waitUntil { await clock.sleepRequests.count == 1 })

        await supervisor.stop()
        #expect(await supervisor.state == .stopped)

        // Advance the clock so the abandoned wait resolves and can prove
        // it does nothing, rather than leaving it running forever.
        await clock.advance(by: .seconds(120))
        try await Task.sleep(for: .milliseconds(30))

        #expect(launcher.launchCount == 1, "must never spawn a process superseded by stop()")
        #expect(await supervisor.state == .stopped)
    }

    @Test("an exit with the store key mismatch code fails permanently, with no restart ever scheduled")
    func storeKeyMismatchExitFailsPermanentlyWithNoRestart() async throws {
        let launcher = FakeProcessLauncher()
        let clock = FakeVirtualClock()
        let supervisor = EngineSupervisor(engineURL: Self.engineURL, launcher: launcher, clock: clock)
        await supervisor.start(configuration: .fixture())

        launcher.finishLaunch(at: 0, exitCode: EngineSupervisor.storeKeyMismatchExitCode)
        #expect(await waitUntil { await supervisor.state == .failed(.storeKeyMismatch) })

        // Give any wrongly-scheduled restart every chance to fire.
        await clock.advance(by: .seconds(120))
        try await Task.sleep(for: .milliseconds(30))

        #expect(await clock.sleepRequests.isEmpty, "a permanent failure must never enter the backoff wait at all")
        #expect(launcher.launchCount == 1, "must never restart after a store key mismatch")
        #expect(await supervisor.state == .failed(.storeKeyMismatch))
    }

    @Test("an exit with the store in-use code fails permanently, with no restart ever scheduled")
    func storeInUseExitFailsPermanentlyWithNoRestart() async throws {
        let launcher = FakeProcessLauncher()
        let clock = FakeVirtualClock()
        let supervisor = EngineSupervisor(engineURL: Self.engineURL, launcher: launcher, clock: clock)
        await supervisor.start(configuration: .fixture())

        launcher.finishLaunch(at: 0, exitCode: EngineSupervisor.storeInUseExitCode)
        #expect(await waitUntil { await supervisor.state == .failed(.storeInUse) })

        await clock.advance(by: .seconds(120))
        try await Task.sleep(for: .milliseconds(30))

        #expect(await clock.sleepRequests.isEmpty, "a permanent failure must never enter the backoff wait at all")
        #expect(launcher.launchCount == 1, "must never restart after another copy is found holding the database")
        #expect(await supervisor.state == .failed(.storeInUse))
    }

    @Test("an exit with the store damaged code fails permanently, with no restart ever scheduled")
    func storeDamagedExitFailsPermanentlyWithNoRestart() async throws {
        let launcher = FakeProcessLauncher()
        let clock = FakeVirtualClock()
        let supervisor = EngineSupervisor(engineURL: Self.engineURL, launcher: launcher, clock: clock)
        await supervisor.start(configuration: .fixture())

        launcher.finishLaunch(at: 0, exitCode: EngineSupervisor.storeDamagedExitCode)
        #expect(await waitUntil { await supervisor.state == .failed(.storeDamaged) })

        await clock.advance(by: .seconds(120))
        try await Task.sleep(for: .milliseconds(30))

        #expect(await clock.sleepRequests.isEmpty, "a permanent failure must never enter the backoff wait at all")
        #expect(launcher.launchCount == 1, "must never restart against a database that cannot be read at all")
        #expect(await supervisor.state == .failed(.storeDamaged))
    }

    @Test("clearFailure resets a failed supervisor to stopped, and a fresh start begins a clean backoff schedule")
    func clearFailureAllowsAFreshStart() async throws {
        let launcher = FakeProcessLauncher()
        let clock = FakeVirtualClock()
        let supervisor = EngineSupervisor(engineURL: Self.engineURL, launcher: launcher, clock: clock)
        await supervisor.start(configuration: .fixture())
        launcher.finishLaunch(at: 0, exitCode: EngineSupervisor.storeKeyMismatchExitCode)
        #expect(await waitUntil { await supervisor.state == .failed(.storeKeyMismatch) })

        await supervisor.clearFailure()
        #expect(await supervisor.state == .stopped)

        await supervisor.start(configuration: .fixture())
        #expect(launcher.launchCount == 2)
        #expect(await supervisor.state == .running)

        launcher.finishLaunch(at: 1, exitCode: 1)
        #expect(await waitUntil { await clock.sleepRequests.count == 1 })
        #expect(await clock.sleepRequests == [.seconds(2)], "the fresh start after recovery must not inherit any prior attempt count")

        await supervisor.stop()
        await clock.advance(by: .seconds(2))
        try await Task.sleep(for: .milliseconds(20))
    }

    @Test("fail moves a stopped supervisor straight to a permanent failure, with no process ever launched")
    func failSetsPermanentFailureWithoutLaunching() async throws {
        let launcher = FakeProcessLauncher()
        let clock = FakeVirtualClock()
        let supervisor = EngineSupervisor(engineURL: Self.engineURL, launcher: launcher, clock: clock)

        await supervisor.fail(.configurationUnreadable)

        #expect(await supervisor.state == .failed(.configurationUnreadable))
        #expect(launcher.launchCount == 0)
    }

    @Test("fail is a no-op while the engine is already running")
    func failIsANoOpWhileRunning() async throws {
        let launcher = FakeProcessLauncher()
        let clock = FakeVirtualClock()
        let supervisor = EngineSupervisor(engineURL: Self.engineURL, launcher: launcher, clock: clock)
        await supervisor.start(configuration: .fixture())

        await supervisor.fail(.configurationUnreadable)

        #expect(await supervisor.state == .running, "fail must never override a state other than stopped")
    }

    @Test("clearFailure is a no-op while not currently failed")
    func clearFailureIsANoOpWhenNotFailed() async throws {
        let launcher = FakeProcessLauncher()
        let clock = FakeVirtualClock()
        let supervisor = EngineSupervisor(engineURL: Self.engineURL, launcher: launcher, clock: clock)
        await supervisor.start(configuration: .fixture())

        await supervisor.clearFailure()

        #expect(await supervisor.state == .running, "clearFailure must never disturb a state other than failed")
    }

    @Test("start after stop begins a fresh backoff schedule")
    func startAfterStopBeginsFreshSchedule() async throws {
        let launcher = FakeProcessLauncher()
        let clock = FakeVirtualClock()
        let supervisor = EngineSupervisor(engineURL: Self.engineURL, launcher: launcher, clock: clock)
        await supervisor.start(configuration: .fixture())
        await supervisor.stop()

        await supervisor.start(configuration: .fixture())
        #expect(launcher.launchCount == 2)
        #expect(await supervisor.state == .running)

        launcher.finishLaunch(at: 1, exitCode: 1)
        #expect(await waitUntil { await clock.sleepRequests.count == 1 })
        #expect(await clock.sleepRequests == [.seconds(2)], "a fresh start must not inherit the previous run's attempt count")

        await supervisor.stop()
        await clock.advance(by: .seconds(2))
        try await Task.sleep(for: .milliseconds(20))
    }

    @Test("stopAndWait waits for the engine to exit and kills one that ignores the request", arguments: [(true, false), (false, true)])
    func stopAndWaitEndsTheEngine(_ testCase: (exits: Bool, killed: Bool)) async throws {
        let launcher = FakeProcessLauncher()
        launcher.processesIgnoreTerminate = !testCase.exits
        let supervisor = EngineSupervisor(engineURL: Self.engineURL, launcher: launcher, clock: FakeVirtualClock())
        await supervisor.start(configuration: .fixture())

        await supervisor.stopAndWait(timeout: .seconds(1))

        #expect(launcher.wasTerminated(at: 0))
        #expect(launcher.wasKilled(at: 0) == testCase.killed)
        #expect(await supervisor.state == .stopped)
    }

    /// armedSecret is the secret a request would carry right now, nil while
    /// none is armed.
    private func armedSecret(_ secret: LocalStatusSecret) -> String? {
        var request = URLRequest(url: URL(string: "http://127.0.0.1:1/status")!)
        guard secret.authorize(&request) else { return nil }
        return request.value(forHTTPHeaderField: LocalStatusSecret.headerName)
    }

    private func stdinSecret(_ launcher: FakeProcessLauncher, launch index: Int) throws -> String {
        let decoded = try JSONDecoder().decode(EngineConfiguration.self, from: launcher.launchRecords()[index].standardInputData)
        return try #require(decoded.statusSecret)
    }

    @Test("every spawn, a crash restart included, gets its own status secret, armed only when that process reports ready")
    func eachSpawnGetsItsOwnSecretArmedOnReady() async throws {
        let secret = LocalStatusSecret(randomBytes: CountingRandomBytesGenerator())
        let launcher = FakeProcessLauncher()
        let clock = FakeVirtualClock()
        let supervisor = EngineSupervisor(engineURL: Self.engineURL, launcher: launcher, clock: clock, statusSecret: secret)

        await supervisor.start(configuration: .fixture())
        let first = try stdinSecret(launcher, launch: 0)
        #expect(!secret.isArmed, "a launched engine has not proved it owns the port yet")

        launcher.reportReady(at: 0)
        #expect(await waitUntil { secret.isArmed })
        #expect(armedSecret(secret) == first)

        launcher.finishLaunch(at: 0, exitCode: 1)
        #expect(await waitUntil { await clock.sleepRequests.count == 1 })
        #expect(!secret.isArmed, "an exited engine's secret must not be presented to whatever takes its port")

        await clock.advance(by: .seconds(2))
        #expect(await waitUntil { launcher.launchCount == 2 })
        let second = try stdinSecret(launcher, launch: 1)
        #expect(second != first, "a restarted engine must not reuse the previous process's secret")
        #expect(!secret.isArmed)

        launcher.reportReady(at: 1)
        #expect(await waitUntil { secret.isArmed })
        #expect(armedSecret(secret) == second)
    }

    @Test("a ready report from a superseded process arms nothing")
    func staleReadyArmsNothing() async throws {
        let secret = LocalStatusSecret(randomBytes: CountingRandomBytesGenerator())
        let launcher = FakeProcessLauncher()
        let supervisor = EngineSupervisor(engineURL: Self.engineURL, launcher: launcher, clock: FakeVirtualClock(), statusSecret: secret)

        await supervisor.start(configuration: .fixture())
        await supervisor.stop()
        launcher.reportReady(at: 0)
        try await Task.sleep(for: .milliseconds(50))
        #expect(!secret.isArmed, "a ready from a stopped run")

        await supervisor.start(configuration: .fixture())
        launcher.reportReady(at: 0)
        try await Task.sleep(for: .milliseconds(50))
        #expect(!secret.isArmed, "a ready from an earlier run, while a newer one is still pending")

        launcher.reportReady(at: 1)
        #expect(await waitUntil { secret.isArmed })
        #expect(armedSecret(secret) == (try stdinSecret(launcher, launch: 1)))
    }

    @Test("an exit or a stop clears an armed secret", arguments: ["exit", "stop"])
    func endingTheEngineClearsTheSecret(_ how: String) async throws {
        let secret = LocalStatusSecret(randomBytes: CountingRandomBytesGenerator())
        let launcher = FakeProcessLauncher()
        let supervisor = EngineSupervisor(engineURL: Self.engineURL, launcher: launcher, clock: FakeVirtualClock(), statusSecret: secret)
        await supervisor.start(configuration: .fixture())
        launcher.reportReady(at: 0)
        #expect(await waitUntil { secret.isArmed })

        if how == "exit" {
            launcher.finishLaunch(at: 0, exitCode: EngineSupervisor.storeDamagedExitCode)
        } else {
            await supervisor.stop()
        }

        #expect(await waitUntil { !secret.isArmed })
    }

    @Test("fail clears whatever secret is held")
    func failClearsTheSecret() async throws {
        let secret = LocalStatusSecret(randomBytes: CountingRandomBytesGenerator())
        let supervisor = EngineSupervisor(engineURL: Self.engineURL, launcher: FakeProcessLauncher(), clock: FakeVirtualClock(), statusSecret: secret)
        secret.arm(try secret.renew())
        #expect(secret.isArmed)

        await supervisor.fail(.configurationUnreadable)

        #expect(!secret.isArmed)
    }
}
