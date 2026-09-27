import CGMRelayCore
import Foundation

/// FakeRunningProcess reports terminate() calls back to the launcher that
/// created it, so a test can assert whether a given launch was ever asked
/// to stop.
final class FakeRunningProcess: RunningProcess, @unchecked Sendable {
    let processIdentifier: Int32
    private let onTerminate: @Sendable () -> Void

    init(processIdentifier: Int32, onTerminate: @escaping @Sendable () -> Void) {
        self.processIdentifier = processIdentifier
        self.onTerminate = onTerminate
    }

    func terminate() { onTerminate() }
}

/// FakeProcessLauncher records every launch and hands the test full
/// control over when and how each spawned "process" exits, via
/// finishLaunch(at:exitCode:). It never actually runs anything.
final class FakeProcessLauncher: ProcessLauncher, @unchecked Sendable {
    struct Launch: Sendable {
        let arguments: [String]
        let standardInputData: Data
    }

    private let lock = NSLock()
    private var launches: [Launch] = []
    private var terminatedFlags: [Bool] = []
    private var onExitHandlers: [(Int32) -> Void] = []
    private var nextPID: Int32 = 1000

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
        onExit: @escaping @Sendable (Int32) -> Void
    ) throws -> any RunningProcess {
        lock.withLock {
            launches.append(Launch(arguments: arguments, standardInputData: standardInputData))
            terminatedFlags.append(false)
            onExitHandlers.append(onExit)
        }
        let index = lock.withLock { launches.count - 1 }
        let pid = lock.withLock {
            let p = nextPID
            nextPID += 1
            return p
        }
        return FakeRunningProcess(processIdentifier: pid) { [weak self] in
            self?.markTerminated(index: index)
        }
    }

    private func markTerminated(index: Int) {
        lock.withLock {
            guard launches.indices.contains(index) else { return }
            terminatedFlags[index] = true
        }
    }

    func wasTerminated(at index: Int) -> Bool {
        lock.withLock { terminatedFlags.indices.contains(index) && terminatedFlags[index] }
    }

    /// finishLaunch simulates the process at `index` exiting on its own,
    /// invoking the onExit handler EngineSupervisor registered for it.
    func finishLaunch(at index: Int, exitCode: Int32) {
        let handler = lock.withLock { onExitHandlers.indices.contains(index) ? onExitHandlers[index] : nil }
        handler?(exitCode)
    }
}
