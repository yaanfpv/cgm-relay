import Testing
import Foundation
@testable import CGMRelayCore

/// ExitWatch records what a child's holder reported through onExit, and waits
/// for the reap to be confirmed. A report is only a callback: the holder
/// reports `ProcessExitCode.statusUnknown` when it could not observe the exit
/// and reaped nothing, so an end is confirmed only once the child itself says
/// it was reaped and reported (`hasReportedExit`).
final class ExitWatch: @unchecked Sendable {
    private let lock = NSLock()
    private var codes: [Int32] = []
    private let arrived = DispatchSemaphore(value: 0)

    /// record is the onExit callback.
    func record(_ code: Int32) {
        lock.withLock { codes.append(code) }
        arrived.signal()
    }

    /// reported lists every code the holder handed to onExit.
    var reported: [Int32] { lock.withLock { codes } }

    /// reportedStatusUnknown is true when the holder said it could not observe
    /// the exit. It then reaps nothing and never reports again.
    var reportedStatusUnknown: Bool { reported.contains(ProcessExitCode.statusUnknown) }

    /// waitConfirmed waits for the child's reap to be confirmed, at most the
    /// given bound. The wake-up is the holder's report; the answer is only
    /// ever the child's own `hasReportedExit`. A status-unknown report ends
    /// the wait at once with false.
    func waitConfirmed(for child: SpawnedChild, milliseconds: Int32) -> Bool {
        let deadline = DispatchTime.now() + .milliseconds(Int(max(0, milliseconds)))
        while true {
            if child.hasReportedExit { return true }
            if reportedStatusUnknown { return false }
            if reported.isEmpty {
                if arrived.wait(timeout: deadline) == .timedOut { return child.hasReportedExit }
            } else {
                // The report is in; the holder marks the child reported just after
                // it returns from the callback.
                if DispatchTime.now() >= deadline { return false }
                usleep(500)
            }
        }
    }
}

/// HeldChild is a child started through ChildSpawner, which holds it from
/// birth: its signaller read the child's start before the holder thread
/// existed, and every send goes through that signaller, which refuses after
/// the reap. Tests start every helper and fixture child this way, apart from
/// TestChild, which never signals.
final class HeldChild: @unchecked Sendable {
    let child: SpawnedChild
    let watch: ExitWatch
    /// The start time the process table showed when the child was born, as
    /// text, or nil when that read showed nothing.
    let birthStart: String?

    private init(child: SpawnedChild, watch: ExitWatch, birthStart: String?) {
        self.child = child
        self.watch = watch
        self.birthStart = birthStart
    }

    var processIdentifier: Int32 { child.processIdentifier }
    var signaller: LaunchedChildSignaller { child.signaller }
    var hasExited: Bool { child.hasExited }
    var hasReportedExit: Bool { child.hasReportedExit }

    /// A captured first read of the process table, taken by the signaller's
    /// own read at birth.
    private final class BirthRecord: @unchecked Sendable {
        private let lock = NSLock()
        private var taken = false
        private var stored: ProcessRecord?
        func take(_ record: ProcessRecord?) {
            lock.withLock {
                guard !taken else { return }
                taken = true
                stored = record
            }
        }
        var value: ProcessRecord? { lock.withLock { stored } }
    }

    /// start launches executable with a minimal environment and /dev/null for
    /// any descriptor not given. Nothing between the spawn and the returned
    /// value can throw, so no child is left without its holder.
    static func start(
        executable: String,
        arguments: [String] = [],
        standardInput: Int32? = nil,
        standardOutput: Int32? = nil,
        standardError: Int32? = nil,
        readProcessTable: @escaping LaunchedChildSignaller.ProcessTableReader = LaunchedChildSignaller.systemProcessTable,
        waitForExit: @escaping ChildSpawner.WaitForExit = ChildSpawner.systemWaitForExit
    ) throws -> HeldChild {
        let watch = ExitWatch()
        let birth = BirthRecord()
        let child = try ChildSpawner.spawn(
            executableURL: URL(fileURLWithPath: executable),
            arguments: arguments,
            environment: ["PATH": "/usr/bin:/bin"],
            standardInput: standardInput,
            standardOutput: standardOutput,
            standardError: standardError,
            readProcessTable: { pid in
                let record = readProcessTable(pid)
                birth.take(record)
                return record
            },
            waitForExit: waitForExit,
            onExit: { watch.record($0) }
        )
        return HeldChild(child: child, watch: watch, birthStart: birth.value.map(ChildCleanup.startText))
    }

    /// send signals the child through its held signaller, which sends only
    /// while the child is unreaped and its start still matches the one read
    /// at birth. False means nothing was sent.
    @discardableResult
    func send(_ signal: Int32) -> Bool { child.signaller.send(signal) }

    /// waitReaped waits for the confirmed reap, at most the given bound.
    func waitReaped(milliseconds: Int32 = TestChild.hangCeilingMilliseconds) -> Bool {
        watch.waitConfirmed(for: child, milliseconds: milliseconds)
    }

    /// end ends the child through its held signaller: each signal in turn,
    /// each followed by a wait for the confirmed reap. A refused send, or a
    /// wait that runs out, is not confirmed, and says so with the child's pid
    /// and birth start.
    func end(signals: [Int32], waitingMilliseconds: Int32 = TestChild.hangCeilingMilliseconds) -> ChildCleanup.Outcome {
        let unconfirmed = ChildCleanup.Outcome.notConfirmed(pid: processIdentifier, start: birthStart)
        for signal in signals {
            if hasReportedExit { return .ended }
            guard send(signal) else { return hasReportedExit ? .ended : unconfirmed }
            if waitReaped(milliseconds: waitingMilliseconds) { return .ended }
        }
        return hasReportedExit ? .ended : unconfirmed
    }
}

/// ConfirmedEnd answers "was this launched process reaped and reported" for a
/// process known only through RunningProcess, whose waitUntilExit is true only
/// once the holder has reaped it and reported the exit.
enum ConfirmedEnd {
    /// isReaped looks once.
    static func isReaped(_ process: any RunningProcess) -> Bool {
        wait(process, milliseconds: 0)
    }

    /// wait blocks the calling thread until the process is confirmed reaped, at
    /// most the given bound (plus the time its answer takes to arrive).
    static func wait(_ process: any RunningProcess, milliseconds: Int32) -> Bool {
        final class Answer: @unchecked Sendable {
            private let lock = NSLock()
            private var value = false
            func set(_ new: Bool) { lock.withLock { value = new } }
            var get: Bool { lock.withLock { value } }
        }
        let answer = Answer()
        let done = DispatchSemaphore(value: 0)
        Task.detached {
            answer.set(await process.waitUntilExit(timeout: .milliseconds(Int(max(0, milliseconds)))))
            done.signal()
        }
        // The task's own bound is the real limit; this one only keeps a task that
        // never gets to run from blocking the caller forever.
        let outer = DispatchTime.now() + .milliseconds(Int(max(0, milliseconds)) + Int(TestChild.hangCeilingMilliseconds))
        guard done.wait(timeout: outer) == .success else { return false }
        return answer.get
    }
}

/// HeldInput is a pipe the test keeps open behind a child's standard input. A
/// child that reads it (cat) ends only when the test calls `release`, which
/// closes the write end, so no timer of the child's own can end it first. The
/// test, not the child, decides when it ends, whatever the host does to the
/// caller's schedule.
final class HeldInput: @unchecked Sendable {
    private let pipe = Pipe()

    /// The read end, to hand a child as its standard input.
    var childEnd: Int32 { pipe.fileHandleForReading.fileDescriptor }

    /// closeChildEnd closes this process's copy of the read end, once the child
    /// has its own. Nothing about the child's end depends on it.
    func closeChildEnd() { try? pipe.fileHandleForReading.close() }

    /// release closes the write end. A child blocked reading the pipe sees end
    /// of input and exits.
    func release() { try? pipe.fileHandleForWriting.close() }
}

extension HeldChild {
    /// startBlocked starts /bin/cat on input the test holds. The child has no
    /// natural end inside the hang ceiling: it ends when the test releases the
    /// input, or when a signal sent through its held signaller reaches it.
    static func startBlocked(
        on input: HeldInput,
        readProcessTable: @escaping LaunchedChildSignaller.ProcessTableReader = LaunchedChildSignaller.systemProcessTable
    ) throws -> HeldChild {
        defer { input.closeChildEnd() }
        return try HeldChild.start(executable: "/bin/cat", standardInput: input.childEnd, readProcessTable: readProcessTable)
    }

    /// endByReleasing ends a child blocked on `input` by releasing the input,
    /// and confirms the reap. It sends no signal, so it ends the child even
    /// when its signaller refuses every send. A reap not confirmed fails the
    /// test naming the child and its birth start.
    @discardableResult
    func endByReleasing(_ input: HeldInput) -> ChildCleanup.Outcome {
        ChildCleanup.endHeldRecordingNotConfirmed(
            pid: processIdentifier, start: birthStart, alreadyEnded: hasReportedExit,
            send: { input.release() },
            waitForEnd: { waitReaped(milliseconds: $0) },
            waitingMilliseconds: TestChild.hangCeilingMilliseconds
        )
    }
}

/// CallerHold holds the calling test past the lifetime the old timer children
/// of these controls had, so a verdict that still depended on such a child's own
/// timer would be read after that timer ran out.
enum CallerHold {
    /// pastTheOldTwoSecondChild returns only after a reference child, started
    /// now and living two seconds by its own timer, has been reaped. The wait is
    /// on that reap, not on a clock: a slower host holds the caller longer, and
    /// no verdict reads this child. A reap not confirmed fails the test.
    static func pastTheOldTwoSecondChild() {
        do {
            let reference = try HeldChild.start(executable: "/bin/sleep", arguments: ["2"])
            ChildCleanup.endHeldRecordingNotConfirmed(
                pid: reference.processIdentifier, start: reference.birthStart, alreadyEnded: reference.hasReportedExit,
                send: {}, waitForEnd: { reference.waitReaped(milliseconds: $0) },
                waitingMilliseconds: TestChild.hangCeilingMilliseconds
            )
        } catch {
            Issue.record("the reference child that holds the caller past the old lifetime could not be started: \(error)")
        }
    }
}
