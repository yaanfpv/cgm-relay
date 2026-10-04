import Foundation

/// EngineSupervisor starts the engine as a child process, restarts it
/// with backoff if it exits on its own, and guarantees no child is left
/// running once stopped. It is an actor because every field below is
/// mutated from both the caller's own calls (start, stop) and from the
/// child process's own termination handler, which fires on an arbitrary
/// thread.
public actor EngineSupervisor {
    /// RunState is the supervisor's own view of the engine, independent of
    /// anything the engine's /status endpoint reports.
    public enum RunState: Sendable, Equatable {
        case stopped
        case starting
        case running
        case waitingToRestart(attempt: Int, delay: Duration)
        /// failed is a state the supervisor never restarts out of on its
        /// own: FailureReason says why the failure is permanent rather
        /// than a transient crash. clearFailure() is the only way out.
        case failed(FailureReason)
    }

    /// FailureReason names a permanent failure: one the supervisor never
    /// restarts out of on its own, whether it was recognised from the
    /// engine's own exit code (storeKeyMismatch, storeInUse, storeDamaged)
    /// or discovered by the caller before a process was ever started
    /// (every other case, set through fail(_:) below).
    public enum FailureReason: Sendable, Equatable {
        /// storeKeyMismatch is the outcome of the engine exiting with
        /// storeKeyMismatchExitCode: the on-disk reading database was
        /// sealed with a key this Mac's Keychain no longer has, which
        /// happens after a Keychain reset, a restored backup, or a move to
        /// a new Mac. Restarting can never fix it on its own.
        case storeKeyMismatch
        /// storeInUse is the outcome of the engine exiting with
        /// storeInUseExitCode: another process -- another copy of this
        /// app, most likely -- already holds the reading database open.
        /// Restarting will keep losing the same race, though the other
        /// copy quitting can resolve it without either process changing
        /// anything, which is why this is retried on menu open like
        /// configurationUnreadable rather than only offered as a manual
        /// recovery.
        case storeInUse
        /// storeDamaged is the outcome of the engine exiting with
        /// storeDamagedExitCode: the reading database exists but SQLite
        /// cannot read it as a database at all. Restarting can never fix
        /// it on its own.
        case storeDamaged
        /// configurationUnreadable is the outcome of the caller's own
        /// attempt to assemble the engine's stdin configuration failing:
        /// a Keychain read threw, or a value the app generates for itself
        /// on first launch (the bearer token, the store's encryption key)
        /// is missing. Distinct from "Setup needed", which only reflects
        /// whether an email and password are on file.
        case configurationUnreadable
        /// recoveryMoveFailed is the outcome of Start Fresh's own attempt
        /// to move the previous database aside failing (a permissions
        /// problem, most likely). The engine is never started against a
        /// fresh database while the old one might still be sitting at the
        /// same path.
        case recoveryMoveFailed
    }

    /// storeKeyMismatchExitCode is the process exit status
    /// `cgm-relay serve --config-stdin` returns when the saved readings
    /// cannot be opened with the configured key
    /// (cmd/cgm-relay/main.go's own exitCodeStoreKeyMismatch constant;
    /// the two must always agree). Any other exit code is treated as an
    /// ordinary crash and restarted with backoff as before.
    public static let storeKeyMismatchExitCode: Int32 = 3

    /// storeInUseExitCode is the process exit status
    /// `cgm-relay serve --config-stdin` returns when another process
    /// already holds the saved readings open
    /// (cmd/cgm-relay/main.go's own exitCodeStoreInUse constant; the two
    /// must always agree).
    public static let storeInUseExitCode: Int32 = 4

    /// storeDamagedExitCode is the process exit status
    /// `cgm-relay serve --config-stdin` returns when the saved readings
    /// file cannot be read as a database at all
    /// (cmd/cgm-relay/main.go's own exitCodeStoreDamaged constant; the two
    /// must always agree).
    public static let storeDamagedExitCode: Int32 = 5

    /// defaultBackoffSchedule is the delay before each successive restart
    /// attempt, holding at its last value once exhausted: 2 s, 5 s, 15 s,
    /// then 60 s for every attempt after that.
    public static let defaultBackoffSchedule: [Duration] = [.seconds(2), .seconds(5), .seconds(15), .seconds(60)]

    /// defaultStableRunThreshold is how long the engine has to run
    /// without exiting before a later crash is treated as a fresh
    /// incident rather than a continuation of the last one, so a single
    /// transient crash long after startup does not inherit an already
    /// escalated backoff delay.
    public static let defaultStableRunThreshold: Duration = .seconds(60)

    private let engineURL: URL
    private let launcher: any ProcessLauncher
    private let clock: any VirtualClock
    private let backoffSchedule: [Duration]
    private let stableRunThreshold: Duration
    /// statusSecret, when set, is renewed for every spawn and armed only
    /// once that spawn's engine reports it is listening, so it is never
    /// presented to whatever else might hold the status port before then.
    private let statusSecret: LocalStatusSecret?
    /// onStateChange is called every time state changes, so a caller (the
    /// menu bar UI) can react immediately -- for example to show red the
    /// moment the engine crashes -- rather than only finding out at the
    /// next status poll.
    private let onStateChange: @Sendable (RunState) -> Void

    public private(set) var state: RunState = .stopped

    /// generation is bumped by every start(), stop(), fail() and
    /// clearFailure(), and captured by every in-flight
    /// spawn/backoff/exit-handling step. A step whose
    /// captured generation no longer matches the current one belongs to a
    /// run that has already been superseded or stopped, and does nothing
    /// -- this is what stop() relies on to guarantee no restart happens
    /// after it returns, without needing to cancel the backoff wait
    /// itself.
    private var generation = 0
    private var attempt = 0
    private var current: (any RunningProcess)?

    public init(
        engineURL: URL,
        launcher: any ProcessLauncher,
        clock: any VirtualClock = SystemVirtualClock(),
        backoffSchedule: [Duration] = EngineSupervisor.defaultBackoffSchedule,
        stableRunThreshold: Duration = EngineSupervisor.defaultStableRunThreshold,
        statusSecret: LocalStatusSecret? = nil,
        onStateChange: @escaping @Sendable (RunState) -> Void = { _ in }
    ) {
        self.engineURL = engineURL
        self.launcher = launcher
        self.clock = clock
        self.backoffSchedule = backoffSchedule
        self.stableRunThreshold = stableRunThreshold
        self.statusSecret = statusSecret
        self.onStateChange = onStateChange
    }

    private func setState(_ newState: RunState) {
        state = newState
        onStateChange(newState)
    }

    /// start begins supervising the engine with configuration. A call
    /// while the engine is already starting, running, or waiting to
    /// restart does nothing: start/Stop is a two-state toggle from the
    /// caller's point of view.
    public func start(configuration: EngineConfiguration) async {
        guard state == .stopped else { return }
        generation += 1
        attempt = 0
        await spawn(configuration: configuration, generation: generation)
    }

    /// stop terminates the engine if it is currently running, and
    /// prevents any restart already in flight (backoff, or a spawn racing
    /// this call) from starting a new one. It returns once the current
    /// process, if any, has been asked to exit; it does not wait for the
    /// exit to complete, since the caller only needs to know no *new*
    /// process will be started.
    public func stop() {
        generation += 1
        statusSecret?.clear()
        setState(.stopped)
        current?.terminate()
        current = nil
    }

    /// stopAndWait stops the engine like stop(), then waits for its process
    /// to be gone, killing it if it is still running after timeout, so the
    /// caller can end its own process knowing no engine outlives it.
    public func stopAndWait(timeout: Duration) async {
        let process = current
        stop()
        guard let process else { return }
        if await !process.waitUntilExit(timeout: timeout) {
            process.kill()
        }
    }

    private func spawn(configuration: EngineConfiguration, generation: Int) async {
        guard generation == self.generation else { return }
        statusSecret?.clear()
        setState(.starting)

        let startedAt = await clock.now()
        guard generation == self.generation else { return }
        // No suspension point separates the renewal below from the launch,
        // so the secret handed to this process is still the pending one when
        // it reports ready.
        let spawnSecret: String?
        let data: Data
        do {
            spawnSecret = try statusSecret?.renew()
            data = try (spawnSecret.map { configuration.withStatusSecret($0) } ?? configuration).encodedForStandardInput()
        } catch {
            statusSecret?.clear()
            await scheduleRestart(configuration: configuration, generation: generation)
            return
        }

        do {
            let process = try launcher.launch(
                executableURL: engineURL,
                arguments: ["serve", "--config-stdin"],
                standardInputData: data,
                onReady: { [weak self] in
                    guard let self, let spawnSecret else { return }
                    Task { await self.handleReady(generation: generation, secret: spawnSecret) }
                }
            ) { [weak self] exitCode in
                guard let self else { return }
                Task { await self.handleExit(generation: generation, configuration: configuration, startedAt: startedAt, exitCode: exitCode) }
            }
            guard generation == self.generation else {
                // stop() ran while launch() was in flight; undo the spawn
                // it could not have cancelled.
                process.terminate()
                return
            }
            current = process
            setState(.running)
        } catch {
            statusSecret?.clear()
            await scheduleRestart(configuration: configuration, generation: generation)
        }
    }

    /// handleReady arms the secret of the spawn that reported ready, unless
    /// that spawn has since been superseded or stopped.
    private func handleReady(generation: Int, secret: String) {
        guard generation == self.generation else { return }
        statusSecret?.arm(secret)
    }

    /// handleExit reacts to the child process ending on its own. Three
    /// exit codes are recognised as permanent (storeKeyMismatchExitCode,
    /// storeInUseExitCode, storeDamagedExitCode): those exits earn no
    /// restart at all, since the engine has already said running it again
    /// will not help. Every other exit code is "unexpected" and earns a
    /// restart, whatever code it carried; the engine's own /status
    /// endpoint, once it is back up, is where a sign-in or configuration
    /// problem actually surfaces.
    private func handleExit(
        generation: Int,
        configuration: EngineConfiguration,
        startedAt: Duration,
        exitCode: Int32
    ) async {
        guard generation == self.generation else { return }
        current = nil
        statusSecret?.clear()

        switch exitCode {
        case EngineSupervisor.storeKeyMismatchExitCode:
            setState(.failed(.storeKeyMismatch))
            return
        case EngineSupervisor.storeInUseExitCode:
            setState(.failed(.storeInUse))
            return
        case EngineSupervisor.storeDamagedExitCode:
            setState(.failed(.storeDamaged))
            return
        default:
            break
        }

        let ranFor = await clock.now() - startedAt
        guard generation == self.generation else { return }
        if ranFor >= stableRunThreshold {
            attempt = 0
        }
        await scheduleRestart(configuration: configuration, generation: generation)
    }

    /// fail moves the supervisor straight to a permanent failure the
    /// caller discovered on its own, before any process was ever started
    /// for this attempt -- a saved configuration that could not be read,
    /// or a recovery step that failed. A no-op unless state is currently
    /// .stopped, mirroring clearFailure()'s own guard: this only ever
    /// replaces an idle supervisor's state, never one already starting,
    /// running, or waiting to restart.
    public func fail(_ reason: FailureReason) {
        guard state == .stopped else { return }
        generation += 1
        statusSecret?.clear()
        setState(.failed(reason))
    }

    /// clearFailure resets a permanently-failed supervisor back to
    /// `.stopped`, so a fresh start() can run as part of a recovery
    /// (moving the unreadable database aside, or trying the launch
    /// again). A no-op unless state is currently `.failed`, so a
    /// caller can call it unconditionally before every recovery attempt.
    public func clearFailure() {
        guard case .failed = state else { return }
        generation += 1
        attempt = 0
        setState(.stopped)
    }

    /// scheduleRestart re-checks generation itself, rather than trusting
    /// its caller: both spawn's error path and handleExit reach it after
    /// their own await on clock.now(), each a point where a concurrent
    /// stop() could already have superseded this run.
    private func scheduleRestart(configuration: EngineConfiguration, generation: Int) async {
        guard generation == self.generation else { return }
        let delay = backoffSchedule[min(attempt, backoffSchedule.count - 1)]
        attempt += 1
        setState(.waitingToRestart(attempt: attempt, delay: delay))

        do {
            try await clock.sleep(for: delay)
        } catch {
            return
        }

        await spawn(configuration: configuration, generation: generation)
    }
}
