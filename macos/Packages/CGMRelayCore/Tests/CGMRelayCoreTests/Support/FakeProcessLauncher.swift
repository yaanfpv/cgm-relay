import CGMRelayCore
import Foundation

/// FakeRunningProcess reports terminate() calls back to the launcher that
/// created it, so a test can assert whether a given launch was ever asked
/// to stop.
final class FakeRunningProcess: RunningProcess, @unchecked Sendable {
    let processIdentifier: Int32
    private let onTerminate: @Sendable () -> Void
    private let exitsWhenAsked: Bool
    private let onKill: @Sendable () -> Void
    private let gate: ExitGate?

    init(
        processIdentifier: Int32,
        exitsWhenAsked: Bool = true,
        gate: ExitGate? = nil,
        onKill: @escaping @Sendable () -> Void = {},
        onTerminate: @escaping @Sendable () -> Void
    ) {
        self.processIdentifier = processIdentifier
        self.exitsWhenAsked = exitsWhenAsked
        self.gate = gate
        self.onKill = onKill
        self.onTerminate = onTerminate
    }

    func terminate() { onTerminate() }
    func waitUntilExit(timeout: Duration) async -> Bool {
        if let gate { return await gate.wait() }
        return exitsWhenAsked
    }
    func kill() { onKill() }
}

/// ExitGate holds every waitUntilExit of the processes it was given open
/// until the test decides how it ends: release() ends the wait (and every
/// later one) as reaped, expirePending() ends the waits now open as not
/// reaped, the way a bound that ran out would. It waits on events only:
/// awaitWaits(_:) suspends until that many waits have begun.
final class ExitGate: @unchecked Sendable {
    private let lock = NSLock()
    private var pending: [CheckedContinuation<Bool, Never>] = []
    private var arrivals = 0
    private var watchers: [(count: Int, continuation: CheckedContinuation<Void, Never>)] = []
    private var isOpen = false

    func wait() async -> Bool {
        await withCheckedContinuation { (continuation: CheckedContinuation<Bool, Never>) in
            let (openNow, due): (Bool, [CheckedContinuation<Void, Never>]) = lock.withLock {
                arrivals += 1
                if !isOpen { pending.append(continuation) }
                let ready = watchers.filter { $0.count <= arrivals }.map(\.continuation)
                watchers.removeAll { $0.count <= arrivals }
                return (isOpen, ready)
            }
            if openNow { continuation.resume(returning: true) }
            for watcher in due { watcher.resume() }
        }
    }

    /// awaitWaits returns once at least count waits have begun, in all.
    func awaitWaits(_ count: Int) async {
        await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
            let ready: Bool = lock.withLock {
                if arrivals >= count { return true }
                watchers.append((count, continuation))
                return false
            }
            if ready { continuation.resume() }
        }
    }

    func release() {
        let open: [CheckedContinuation<Bool, Never>] = lock.withLock {
            isOpen = true
            defer { pending = [] }
            return pending
        }
        for continuation in open { continuation.resume(returning: true) }
    }

    func expirePending() {
        let open: [CheckedContinuation<Bool, Never>] = lock.withLock {
            defer { pending = [] }
            return pending
        }
        for continuation in open { continuation.resume(returning: false) }
    }
}

/// FakeProcessLauncher records every launch and hands the test full
/// control over when each spawned "process" reports ready and when and how
/// it exits, via reportReady(at:) and finishLaunch(at:exitCode:). It never
/// actually runs anything.
final class FakeProcessLauncher: ProcessLauncher, @unchecked Sendable {
    struct Launch: Sendable {
        let arguments: [String]
        let standardInputData: Data
    }

    private let lock = NSLock()
    private var launches: [Launch] = []
    private var terminatedFlags: [Bool] = []
    private var onExitHandlers: [(Int32) -> Void] = []
    private var onReadyHandlers: [() -> Void] = []
    private var nextPID: Int32 = 1000
    private var killedFlags: [Bool] = []

    /// processesIgnoreTerminate makes every process launched afterwards
    /// still be running when asked to exit, so a test can see it killed.
    var processesIgnoreTerminate = false

    /// exitGate, when set, holds the exit wait of every process launched
    /// afterwards open until the test releases or expires it.
    var exitGate: ExitGate?

    var launchCount: Int {
        lock.withLock { launches.count }
    }

    func launchRecords() -> [Launch] {
        lock.withLock { launches }
    }

    func launch(
        executableURL: URL,
        arguments: [String],
        standardInputData: Data,
        onReady: @escaping @Sendable () -> Void,
        onExit: @escaping @Sendable (Int32) -> Void
    ) throws -> any RunningProcess {
        lock.withLock {
            launches.append(Launch(arguments: arguments, standardInputData: standardInputData))
            terminatedFlags.append(false)
            killedFlags.append(false)
            onExitHandlers.append(onExit)
            onReadyHandlers.append(onReady)
        }
        let index = lock.withLock { launches.count - 1 }
        let pid = lock.withLock {
            let p = nextPID
            nextPID += 1
            return p
        }
        let ignores = processesIgnoreTerminate
        return FakeRunningProcess(
            processIdentifier: pid,
            exitsWhenAsked: !ignores,
            gate: exitGate,
            onKill: { [weak self] in self?.lock.withLock { self?.killedFlags[index] = true } }
        ) { [weak self] in
            self?.markTerminated(index: index)
        }
    }

    private func markTerminated(index: Int) {
        lock.withLock {
            guard launches.indices.contains(index) else { return }
            terminatedFlags[index] = true
        }
    }

    func wasKilled(at index: Int) -> Bool {
        lock.withLock { killedFlags.indices.contains(index) && killedFlags[index] }
    }

    func wasTerminated(at index: Int) -> Bool {
        lock.withLock { terminatedFlags.indices.contains(index) && terminatedFlags[index] }
    }

    /// reportReady simulates the process at `index` writing its ready line,
    /// invoking the onReady handler EngineSupervisor registered for it.
    func reportReady(at index: Int) {
        let handler = lock.withLock { onReadyHandlers.indices.contains(index) ? onReadyHandlers[index] : nil }
        handler?()
    }

    /// finishLaunch simulates the process at `index` exiting on its own,
    /// invoking the onExit handler EngineSupervisor registered for it.
    func finishLaunch(at index: Int, exitCode: Int32) {
        let handler = lock.withLock { onExitHandlers.indices.contains(index) ? onExitHandlers[index] : nil }
        handler?(exitCode)
    }
}
