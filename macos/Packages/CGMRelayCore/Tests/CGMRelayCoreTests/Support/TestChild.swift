import Testing
import Foundation

/// ChildEnd is what ending a test child can honestly say. `.ended` means the
/// child's exit event was observed. Anything else, including a wait that ran
/// out of time, is `.unknown`: the child may still be running.
enum ChildEnd: Equatable {
    case ended
    case unknown(pid: Int32, reason: String)
}

/// TestChild starts a real child with a stdin and a stdout pipe and ends it
/// the one way a test may: by closing its input and waiting on its exit event.
/// It sends no signal and never calls terminate(), so a child that ignores end
/// of input is reported as unknown and left for the developer to end.
///
/// Every wait is a semaphore wait on the termination handler's event, bounded
/// by the repo's hang ceiling. Nothing polls, sleeps or reads isRunning, so
/// "ended" is never inferred from anything but the exit event itself.
final class TestChild: @unchecked Sendable {
    /// The repo's hang ceiling: the longest any wait on a child may take. It is
    /// a bound for a hang, never the expected time.
    static let hangCeilingMilliseconds: Int32 = 30_000

    let processIdentifier: Int32
    /// The read end of the child's stdout.
    let standardOutput: FileHandle

    private let process: Process
    private let input: FileHandle
    private let exited: DispatchSemaphore
    private let lock = NSLock()
    private var inputClosed = false
    private var exitObserved = false

    /// init launches the child. The termination handler is set before run(),
    /// so no exit can be missed. If run() throws, no child exists. After init
    /// returns, the caller's next statement registers `endRecordingUnknown`.
    init(executable: String, arguments: [String]) throws {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: executable)
        process.arguments = arguments
        let inputPipe = Pipe()
        let outputPipe = Pipe()
        process.standardInput = inputPipe
        process.standardOutput = outputPipe
        let exited = DispatchSemaphore(value: 0)
        process.terminationHandler = { _ in exited.signal() }
        try process.run()

        self.process = process
        self.exited = exited
        self.input = inputPipe.fileHandleForWriting
        self.standardOutput = outputPipe.fileHandleForReading
        self.processIdentifier = process.processIdentifier
    }

    /// closeInput closes the child's stdin. Calling it again does nothing.
    func closeInput() {
        lock.withLock {
            guard !inputClosed else { return }
            inputClosed = true
            try? input.close()
        }
    }

    /// end closes the input and waits for the exit event for at most
    /// `waitingMilliseconds`. It returns `.ended` only when that event
    /// happened. A wait that ends without it returns `.unknown`, and end may
    /// be called again to keep waiting.
    func end(waitingMilliseconds: Int32 = TestChild.hangCeilingMilliseconds) -> ChildEnd {
        closeInput()
        let alreadyObserved = lock.withLock { exitObserved }
        if alreadyObserved { return .ended }
        let bound = DispatchTime.now() + .milliseconds(Int(max(0, waitingMilliseconds)))
        switch exited.wait(timeout: bound) {
        case .success:
            lock.withLock { exitObserved = true }
            return .ended
        case .timedOut:
            return .unknown(
                pid: processIdentifier,
                reason: "no exit event within \(waitingMilliseconds) ms of closing its input"
            )
        }
    }

    /// endRecordingUnknown ends the child and, when the exit was not observed,
    /// records a test failure naming the pid. The child is not signalled.
    func endRecordingUnknown(waitingMilliseconds: Int32 = TestChild.hangCeilingMilliseconds) {
        if case .unknown(let pid, let reason) = end(waitingMilliseconds: waitingMilliseconds) {
            Issue.record("test child pid \(pid) may still be running, outcome unknown (\(reason)); it was not signalled, end it by hand")
        }
    }
}

/// StoppedChildSupport holds what tests need for a child that has been
/// stopped (SIGSTOP) from outside. Every wait is bounded only by the repo's
/// hang ceiling, and a bound that runs out is a failure the caller reports,
/// never an expected duration.
enum StoppedChildSupport {
    private final class Slot<T>: @unchecked Sendable {
        private let lock = NSLock()
        private var stored: T?
        func set(_ value: T) { lock.withLock { stored = value } }
        func get() -> T? { lock.withLock { stored } }
    }

    private static func ceilingWait(_ done: DispatchSemaphore) async -> Bool {
        await withCheckedContinuation { continuation in
            DispatchQueue.global().async {
                let bound = DispatchTime.now() + .milliseconds(Int(TestChild.hangCeilingMilliseconds))
                continuation.resume(returning: done.wait(timeout: bound) == .success)
            }
        }
    }

    /// withinBlocking runs a blocking call on a plain thread and returns its
    /// value, or nil if it had not returned within the hang ceiling. A call
    /// that never returns keeps its thread until the process ends.
    static func withinBlocking<T: Sendable>(_ work: @escaping @Sendable () -> T) async -> T? {
        let slot = Slot<T>()
        let done = DispatchSemaphore(value: 0)
        DispatchQueue.global().async {
            slot.set(work())
            done.signal()
        }
        return await ceilingWait(done) ? slot.get() : nil
    }

    /// withinAsync is withinBlocking for an async call.
    static func withinAsync<T: Sendable>(_ work: @escaping @Sendable () async -> T) async -> T? {
        let slot = Slot<T>()
        let done = DispatchSemaphore(value: 0)
        Task {
            slot.set(await work())
            done.signal()
        }
        return await ceilingWait(done) ? slot.get() : nil
    }

    /// waitUntilStopped returns true once the system reports the process as
    /// stopped, false if it had not been within the hang ceiling. It reads the
    /// process table only: it never waits on the child, so it consumes no
    /// state a holder of the child waits on.
    static func waitUntilStopped(pid: Int32) -> Bool {
        let stoppedStatus: UInt32 = 4 // SSTOP in <sys/proc.h>
        let deadline = DispatchTime.now() + .milliseconds(Int(TestChild.hangCeilingMilliseconds))
        while DispatchTime.now() < deadline {
            var info = proc_bsdinfo()
            let size = Int32(MemoryLayout<proc_bsdinfo>.size)
            if proc_pidinfo(pid, PROC_PIDTBSDINFO, 0, &info, size) == size, info.pbi_status == stoppedStatus {
                return true
            }
            sched_yield()
        }
        return false
    }

    /// isGone is true when no process, not even an unreaped one, has this pid.
    static func isGone(pid: Int32) -> Bool {
        errno = 0
        return kill(pid, 0) == -1 && errno == ESRCH
    }
}
