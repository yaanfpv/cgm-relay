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

    @Test("an exit with the port in use code fails permanently, with no restart loop")
    func portInUseExitFailsPermanentlyWithNoRestart() async throws {
        let launcher = FakeProcessLauncher()
        let clock = FakeVirtualClock()
        let supervisor = EngineSupervisor(engineURL: Self.engineURL, launcher: launcher, clock: clock)
        await supervisor.start(configuration: .fixture())

        launcher.finishLaunch(at: 0, exitCode: EngineSupervisor.portInUseExitCode)
        #expect(await waitUntil { await supervisor.state == .failed(.portInUse) })

        await clock.advance(by: .seconds(120))
        try await Task.sleep(for: .milliseconds(30))

        #expect(await clock.sleepRequests.isEmpty, "a port another app holds must never enter the backoff wait")
        #expect(launcher.launchCount == 1)
        #expect(await supervisor.state == .failed(.portInUse))
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

    @Test("status unknown fails permanently: no backoff, no second engine through any restart path, and the state says why")
    func statusUnknownExitStartsNoSecondEngine() async throws {
        let launcher = FakeProcessLauncher()
        let clock = FakeVirtualClock()
        let supervisor = EngineSupervisor(engineURL: Self.engineURL, launcher: launcher, clock: clock)
        await supervisor.start(configuration: .fixture())

        launcher.finishLaunch(at: 0, exitCode: ProcessExitCode.statusUnknown)
        #expect(await waitUntil { await supervisor.state == .failed(.engineStatusUnknown) })

        // The backoff path: time passes and nothing is scheduled or started.
        await clock.advance(by: .seconds(120))
        try await Task.sleep(for: .milliseconds(30))
        #expect(await clock.sleepRequests.isEmpty, "an engine that may still run must never enter the backoff wait")
        #expect(launcher.launchCount == 1, "must never start a second engine while the first may still run")

        // The caller's own start path: a failed supervisor ignores it.
        await supervisor.start(configuration: .fixture())
        #expect(launcher.launchCount == 1, "start must not launch while the engine's status is unknown")
        #expect(await supervisor.state == .failed(.engineStatusUnknown))

        // stop leaves the failure as it is, so a later start launches nothing.
        await supervisor.stop()
        #expect(await supervisor.state == .failed(.engineStatusUnknown), "stop must not clear a status-unknown failure")
        await supervisor.start(configuration: .fixture())
        #expect(launcher.launchCount == 1, "start after stop must not launch while the engine's status is unknown")
        #expect(await supervisor.state == .failed(.engineStatusUnknown))
    }

    @Test("the engine's own exit codes still map as before: store and port codes fail permanently, any other code restarts with backoff")
    func exitCodesStillMapAsBefore() async throws {
        let permanent: [(Int32, EngineSupervisor.FailureReason)] = [
            (EngineSupervisor.storeKeyMismatchExitCode, .storeKeyMismatch),
            (EngineSupervisor.storeInUseExitCode, .storeInUse),
            (EngineSupervisor.storeDamagedExitCode, .storeDamaged),
            (EngineSupervisor.portInUseExitCode, .portInUse),
        ]
        for (code, reason) in permanent {
            let launcher = FakeProcessLauncher()
            let clock = FakeVirtualClock()
            let supervisor = EngineSupervisor(engineURL: Self.engineURL, launcher: launcher, clock: clock)
            await supervisor.start(configuration: .fixture())
            launcher.finishLaunch(at: 0, exitCode: code)
            #expect(await waitUntil { await supervisor.state == .failed(reason) }, "exit code \(code)")
            #expect(launcher.launchCount == 1)
        }
        // 255 is what the holder reports when the reap finds the child
        // already gone: an ordinary crash, restarted.
        for code in [Int32(1), ChildSpawner.exitCodeWhenUnknown, -9] {
            let launcher = FakeProcessLauncher()
            let clock = FakeVirtualClock()
            let supervisor = EngineSupervisor(engineURL: Self.engineURL, launcher: launcher, clock: clock)
            await supervisor.start(configuration: .fixture())
            launcher.finishLaunch(at: 0, exitCode: code)
            #expect(await waitUntil { await clock.sleepRequests.count == 1 }, "exit code \(code)")
            await clock.advance(by: .seconds(2))
            #expect(await waitUntil { launcher.launchCount == 2 }, "exit code \(code)")
        }
    }

    @Test("stopAndWait returns false and fails with status unknown when the ended engine is never confirmed reaped, and starts nothing")
    func stopAndWaitWithAnEngineThatIsNeverReapedReturnsFalse() async throws {
        let launcher = FakeProcessLauncher()
        launcher.processesIgnoreTerminate = true // its waitUntilExit never turns true
        let clock = FakeVirtualClock()
        let supervisor = EngineSupervisor(engineURL: Self.engineURL, launcher: launcher, clock: clock)
        await supervisor.start(configuration: .fixture())

        let confirmed: Bool? = await StoppedChildSupport.withinAsync { await supervisor.stopAndWait(timeout: .zero) }
        try #require(confirmed != nil, "stopAndWait did not return")
        #expect(confirmed == false)
        #expect(launcher.wasKilled(at: 0))
        #expect(await supervisor.state == .failed(.engineStatusUnknown))

        await clock.advance(by: .seconds(120))
        try await Task.sleep(for: .milliseconds(30))
        await supervisor.start(configuration: .fixture())
        #expect(launcher.launchCount == 1, "no second engine while the first may still run")
        #expect(await supervisor.state == .failed(.engineStatusUnknown))
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

        let confirmed = await supervisor.stopAndWait(timeout: .seconds(1))

        #expect(launcher.wasTerminated(at: 0))
        #expect(launcher.wasKilled(at: 0) == testCase.killed)
        // The fake process that ignores terminate is never reaped after the
        // kill either, so its end cannot be confirmed: stopAndWait says so,
        // and the supervisor refuses to start another engine.
        #expect(confirmed == testCase.exits)
        #expect(await supervisor.state == (testCase.exits ? .stopped : .failed(.engineStatusUnknown)))
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

    // MARK: A stopped engine

    /// RecordingRealLauncher launches real children and keeps the one process
    /// and every exit it reported, so a test can stop that child by its pid.
    private final class RecordingRealLauncher: ProcessLauncher, @unchecked Sendable {
        private let inner = RealProcessLauncher(engineLog: { _ in })
        private let lock = NSLock()
        private var launched: (any RunningProcess)?
        private var codes: [Int32] = []
        let ready = DispatchSemaphore(value: 0)
        let exited = DispatchSemaphore(value: 0)

        var process: (any RunningProcess)? { lock.withLock { launched } }
        var exitCodes: [Int32] { lock.withLock { codes } }

        /// endEngineIfLeftRunning kills the child this test started if no
        /// exit was reported, through the handle the launch returned, then
        /// waits for the report. Once an exit was reported there is nothing
        /// left to end or wait for.
        func endEngineIfLeftRunning() {
            guard exitCodes.isEmpty else { return }
            process?.kill()
            _ = exited.wait(timeout: .now() + .milliseconds(Int(TestChild.hangCeilingMilliseconds)))
        }

        func launch(
            executableURL: URL,
            arguments: [String],
            standardInputData: Data,
            onReady: @escaping @Sendable () -> Void,
            onExit: @escaping @Sendable (Int32) -> Void
        ) throws -> any RunningProcess {
            let process = try inner.launch(
                executableURL: executableURL,
                arguments: arguments,
                standardInputData: standardInputData,
                onReady: { [self] in
                    ready.signal()
                    onReady()
                },
                onExit: { [self] code in
                    lock.withLock { codes.append(code) }
                    exited.signal()
                    onExit(code)
                }
            )
            lock.withLock { launched = process }
            return process
        }
    }

    @Test("stopAndWait ends an engine that something else stopped, even one that ignores the request to exit")
    func stopAndWaitEndsAStoppedEngine() async throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("engine-stopped-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        let engine = dir.appendingPathComponent("engine")
        try """
        #!/usr/bin/perl
        $SIG{TERM} = 'IGNORE';
        $| = 1;
        print "ready\n";
        kill 'STOP', $$;
        while (1) { sleep 30 }
        """.write(to: engine, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: engine.path)

        let launcher = RecordingRealLauncher()
        let supervisor = EngineSupervisor(engineURL: engine, launcher: launcher, clock: FakeVirtualClock())
        await supervisor.start(configuration: .fixture())
        let process = try #require(launcher.process)
        let pid = process.processIdentifier
        defer {
            // Only reached with the child still alive when the test failed.
            launcher.endEngineIfLeftRunning()
        }
        let isReady = await StoppedChildSupport.withinBlocking {
            launcher.ready.wait(timeout: .now() + .milliseconds(Int(TestChild.hangCeilingMilliseconds))) == .success
        }
        try #require(isReady == true, "engine pid \(pid) never reported ready")

        // The engine stopped itself after its ready line: the same state as a
        // stop sent from outside, with no signal sent by this test.
        try #require(StoppedChildSupport.waitUntilStopped(pid: pid), "engine pid \(pid) never showed as stopped")

        let returned: Void? = await StoppedChildSupport.withinAsync { await supervisor.stopAndWait(timeout: .seconds(1)) }
        try #require(returned != nil, "stopAndWait did not return for the stopped engine pid \(pid)")

        let reaped = await StoppedChildSupport.withinBlocking {
            launcher.exited.wait(timeout: .now() + .milliseconds(Int(TestChild.hangCeilingMilliseconds))) == .success
        }
        try #require(reaped == true, "stopped engine pid \(pid) was never reported as ended")
        #expect(launcher.exitCodes == [-SIGKILL])
        #expect(StoppedChildSupport.isGone(pid: pid))
        #expect(await supervisor.state == .stopped)
    }

    /// ReapCase names one way the engine is running when it is stopped.
    struct ReapCase: Sendable, CustomTestStringConvertible {
        let label: String
        let stopsItself: Bool
        var testDescription: String { label }
    }

    @Test(
        "stopAndWait returns only once the engine it ended has been reaped: at the instant of return its exit is reported and its number no longer names it",
        arguments: [
            ReapCase(label: "an engine that ignores the request to exit", stopsItself: false),
            ReapCase(label: "an engine that something stopped", stopsItself: true),
        ]
    )
    func stopAndWaitReturnsOnlyAfterTheReap(_ testCase: ReapCase) async throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("engine-reap-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        let engine = dir.appendingPathComponent("engine")
        try """
        #!/usr/bin/perl
        $SIG{TERM} = 'IGNORE';
        $| = 1;
        print "ready\n";
        \(testCase.stopsItself ? "kill 'STOP', $$;" : "")
        while (1) { sleep 30 }
        """.write(to: engine, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: engine.path)

        // Each round is a fresh engine: a stop that returned before the reap
        // is a race the holder thread usually loses only narrowly.
        for round in 1...10 {
            let launcher = RecordingRealLauncher()
            let supervisor = EngineSupervisor(engineURL: engine, launcher: launcher, clock: FakeVirtualClock())
            await supervisor.start(configuration: .fixture())
            defer { launcher.endEngineIfLeftRunning() }
            let process = try #require(launcher.process)
            let pid = process.processIdentifier
            let isReady = await StoppedChildSupport.withinBlocking {
                launcher.ready.wait(timeout: .now() + .milliseconds(Int(TestChild.hangCeilingMilliseconds))) == .success
            }
            try #require(isReady == true, "round \(round): engine pid \(pid) never reported ready")
            if testCase.stopsItself {
                try #require(StoppedChildSupport.waitUntilStopped(pid: pid), "round \(round): engine pid \(pid) never showed as stopped")
            }
            // Nothing has ended or reaped this engine, so the number is still its own.
            let recorded = try #require(StoppedChildSupport.record(pid: pid), "round \(round): no record of the running engine pid \(pid)")

            // A zero timeout leaves no time for the engine to exit on its own,
            // so the stop has to end it by force.
            let returned: Bool? = await StoppedChildSupport.withinAsync { await supervisor.stopAndWait(timeout: .zero) }
            try #require(returned != nil, "round \(round): stopAndWait did not return for engine pid \(pid)")
            #expect(returned == true, "round \(round): stopAndWait did not confirm the engine ended")

            // Read at the instant of return, with no wait for any report.
            let reported = launcher.exitCodes
            let stillNamed = StoppedChildSupport.namesRecorded(recorded)
            #expect(reported == [-SIGKILL], "round \(round): stopAndWait returned before the engine's exit was reported (reported \(reported))")
            #expect(!stillNamed, "round \(round): stopAndWait returned while pid \(pid) still named the engine")
        }
    }
}
