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

    init(
        processIdentifier: Int32,
        exitsWhenAsked: Bool = true,
        onKill: @escaping @Sendable () -> Void = {},
        onTerminate: @escaping @Sendable () -> Void
    ) {
        self.processIdentifier = processIdentifier
        self.exitsWhenAsked = exitsWhenAsked
        self.onKill = onKill
        self.onTerminate = onTerminate
    }

    func terminate() { onTerminate() }
    func waitUntilExit(timeout: Duration) async -> Bool { exitsWhenAsked }
    func kill() { onKill() }
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
