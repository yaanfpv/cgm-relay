import Foundation

/// EngineSupervisor starts the engine as a child process, restarts it
/// with backoff if it exits on its own, and starts no second engine while
/// the first may still be running. It is an actor because every field below is
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
    /// engine's own exit code (storeKeyMismatch, storeInUse, storeDamaged,
    /// portInUse) or discovered by the caller before a process was ever started
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
        /// portInUse is the outcome of the engine exiting with
        /// portInUseExitCode: another program holds the follower port. It
        /// is not restarted on its own, since a restart loses the same
        /// race, but it is retried whenever the menu opens, and a new port
        /// recovers it at once.
        case portInUse
        /// httpsOnStatusPort is the caller refusing a start because Tailscale
        /// HTTPS holds the follower port fixed and it is the relay's own
        /// status port, where the engine can never listen. Turning Tailscale
        /// HTTPS off frees the port to move, so it is retried like portInUse.
        case httpsOnStatusPort
        /// engineStatusUnknown is the outcome of an engine whose end could not
        /// be confirmed: its exit was reported as ProcessExitCode.statusUnknown,
        /// or stopAndWait could not confirm the reap within its bound. It may
        /// still be running, so no second engine is started while it may hold
        /// the store; neither clearFailure(), fail(_:) nor stop() leaves this
        /// state, and it lasts until the app quits.
        case engineStatusUnknown
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

    /// portInUseExitCode is the process exit status
    /// `cgm-relay serve --config-stdin` returns when it cannot listen on
    /// the follower port because another program holds it
    /// (cmd/cgm-relay/main.go's own exitCodePortInUse constant; the two
    /// must always agree).
    public static let portInUseExitCode: Int32 = 6

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
    /// confirmation is the one wait for the reap of the engine a stopAndWait
    /// ended, held while it runs so every overlapping stopAndWait joins it and a
    /// start() cannot launch a second engine in that time.
    private var confirmation: Task<Bool, Never>?
    private var isConfirmingStop: Bool { confirmation != nil }

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
        guard state == .stopped, !isConfirmingStop else { return }
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
        // An engine whose end could not be confirmed stays reported as such.
        if state == .failed(.engineStatusUnknown) { return }
        generation += 1
        statusSecret?.clear()
        setState(.stopped)
        current?.terminate()
        current = nil
    }

    /// killReapBound is how long stopAndWait waits for the reap after it has
    /// sent SIGKILL. SIGKILL cannot be caught or ignored and ends a stopped
    /// child too, so the reap follows at once; this only bounds a wait that
    /// would otherwise stay open for ever (a child that cannot be signalled).
    static let killReapBound: Duration = .seconds(2)

    /// stopAndWait stops the engine like stop(), then waits for its process
    /// to be gone, killing it if it is still running after timeout, so the
    /// caller knows the engine it ended is gone. After the kill it waits, up to killReapBound, for the reap of that same
    /// process. It returns true only once the engine it ended is reaped and
    /// its exit reported (or there was none to end). If it cannot confirm
    /// that, it returns false and the supervisor is
    /// .failed(.engineStatusUnknown), so no second engine is started while
    /// the first may still run. A call that arrives while another is waiting
    /// joins that wait and returns its answer.
    public func stopAndWait(timeout: Duration) async -> Bool {
        // A call while a confirmation is in flight joins it: it answers what
        // that confirmation answers, and never before it.
        if let confirmation { return await confirmation.value }
        if state == .failed(.engineStatusUnknown) { return false }
        let process = current
        stop()
        guard let process else { return true }
        let wait = Task { await self.confirmEnd(of: process, timeout: timeout) }
        confirmation = wait
        return await wait.value
    }

    /// confirmEnd waits for the reap of process, killing it once timeout has
    /// passed, and frees the confirmation slot whatever the answer.
    private func confirmEnd(of process: any RunningProcess, timeout: Duration) async -> Bool {
        defer { confirmation = nil }
        var reaped = await process.waitUntilExit(timeout: timeout)
        if !reaped {
            process.kill()
            reaped = await process.waitUntilExit(timeout: Self.killReapBound)
        }
        if !reaped {
            generation += 1
            statusSecret?.clear()
            setState(.failed(.engineStatusUnknown))
        }
        // An exit reported as not confirmed while this wait ran is an end that
        // was not confirmed, whatever the wait itself saw.
        return reaped && state != .failed(.engineStatusUnknown)
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

    /// handleExit reacts to the child process ending on its own. An exit
    /// reported as ProcessExitCode.statusUnknown is a permanent failure, never
    /// a restart. Four
    /// exit codes are recognised as permanent (storeKeyMismatchExitCode,
    /// storeInUseExitCode, storeDamagedExitCode, portInUseExitCode): those
    /// exits earn no restart at all, since the engine has already said
    /// running it again will not help. Every other exit code is
    /// "unexpected" and earns a restart, whatever code it carried; the
    /// engine's own /status endpoint, once it is back up, is where a
    /// sign-in or configuration problem actually surfaces.
    private func handleExit(
        generation: Int,
        configuration: EngineConfiguration,
        startedAt: Duration,
        exitCode: Int32
    ) async {
        // An exit nobody observed is not a crash to restart from: the engine
        // may still be running and holding the store. It counts whichever
        // generation reported it, since a stop that superseded it did not
        // end the process.
        if exitCode == ProcessExitCode.statusUnknown {
            if generation == self.generation {
                current = nil
            } else {
                self.generation += 1
            }
            statusSecret?.clear()
            setState(.failed(.engineStatusUnknown))
            return
        }

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
        case EngineSupervisor.portInUseExitCode:
            setState(.failed(.portInUse))
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
    /// running, or waiting to restart, nor one whose engine is still being
    /// waited for.
    public func fail(_ reason: FailureReason) {
        guard state == .stopped, !isConfirmingStop else { return }
        generation += 1
        statusSecret?.clear()
        setState(.failed(reason))
    }

    /// clearFailure resets a permanently-failed supervisor back to
    /// `.stopped`, so a fresh start() can run as part of a recovery
    /// (moving the unreadable database aside, or trying the launch
    /// again). A no-op unless state is currently `.failed`, so a
    /// caller can call it unconditionally before every recovery attempt.
    /// It never leaves .failed(.engineStatusUnknown): that engine may still
    /// be running.
    public func clearFailure() {
        guard case .failed(let reason) = state, reason != .engineStatusUnknown else { return }
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
