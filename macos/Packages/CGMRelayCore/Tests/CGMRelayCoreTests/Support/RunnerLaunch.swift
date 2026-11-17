import Testing
import Foundation
@testable import CGMRelayCore

/// HeldFifo is a FIFO the test keeps open for reading and writing, in a
/// directory the test owns. A fixture process that blocks reading it has no end
/// of its own: it goes on only when the test calls `release`, whatever the run
/// returned and however late the caller is. The test opens it first, so the
/// fixture's own open never blocks.
final class HeldFifo: @unchecked Sendable {
    let path: String
    private let descriptor: Int32
    private let lock = NSLock()
    private var released = false

    /// How many lines release writes: one per reader that may be blocked on it.
    private static let lines = 64

    init(in directory: URL, name: String = "release") throws {
        path = directory.appendingPathComponent(name).path
        guard mkfifo(path, 0o600) == 0 else { throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO) }
        // Read-write open never blocks on a FIFO.
        let fd = Darwin.open(path, O_RDWR)
        guard fd >= 0 else { throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO) }
        descriptor = fd
    }

    deinit { Darwin.close(descriptor) }

    /// release lets every fixture process blocked on the FIFO go on. It is made
    /// once, whatever state the fixtures are in, and again does nothing.
    func release() {
        lock.withLock {
            guard !released else { return }
            released = true
            let text = Array(String(repeating: "x\n", count: Self.lines).utf8)
            _ = text.withUnsafeBufferPointer { Darwin.write(descriptor, $0.baseAddress, $0.count) }
        }
    }
}

/// LaunchCall is one call of a runner's `run`, `runCapturingOutput` or
/// `runOnCallingThread`: the result it returned (nil while it still runs) and
/// the identity its own launch read gave (nil when that read failed or named
/// a process that is not a child of this process).
struct LaunchCall: Sendable {
    var result: BoundedProcessResult?
    var identity: StoppedChildSupport.RecordedProcess?
}

/// LaunchAccount decides, from a list of calls alone, which of them a cleanup
/// cannot confirm ended. It starts and signals nothing.
enum LaunchAccount {
    struct Verdict: Sendable {
        /// removeDirectory is true when every call is a confirmed end, no child,
        /// or a call that may still have run and was read gone.
        let removeDirectory: Bool
        /// named is the position of each call that is not confirmed.
        let named: [Int]
    }

    /// isEnd is true for a result the runner returns only on a real exit
    /// code, and for a launch that started no child.
    private static func isEnd(_ result: BoundedProcessResult?) -> Bool {
        switch result {
        case .exited, .timedOut, .failedToLaunch: return true
        case .notConfirmedEnded, nil: return false
        }
    }

    /// decide asks `gone` only about a call that has an identity and no
    /// confirmed end. A call with no confirmed end and no identity is named.
    static func decide(_ calls: [LaunchCall], gone: (StoppedChildSupport.RecordedProcess) -> Bool) -> Verdict {
        var named: [Int] = []
        for (index, call) in calls.enumerated() where !isEnd(call.result) {
            guard let identity = call.identity, gone(identity) else {
                named.append(index)
                continue
            }
        }
        return Verdict(removeDirectory: named.isEmpty, named: named)
    }

    /// signalTargets is the position of each call a cleanup may signal: one
    /// with an identity and no confirmed end.
    static func signalTargets(_ calls: [LaunchCall]) -> [Int] {
        calls.indices.filter { calls[$0].identity != nil && !isEnd(calls[$0].result) }
    }
}

/// RunnerLaunch builds a bounded runner that lists every call it is given,
/// before the child starts, with the identity that call's own launch read
/// took while the child was necessarily unreaped and the result once the call
/// returns. The launch read itself is the real one, so the runner signals and
/// reaps as it does in the app. One value serves any number of calls, so a
/// test that runs several commands accounts for every one.
final class RunnerLaunch: @unchecked Sendable {
    private let lock = NSLock()
    private var listed: [LaunchCall] = []
    private let extraEnvironment: [String: String]
    private let showsIdentityToRunner: Bool
    private let inner: ((@escaping LaunchedChildSignaller.ProcessTableReader) -> any BoundedProcessRunning)?

    /// `showsIdentityToRunner` false hands the runner no record after noting
    /// the child, so no identity is accepted and every send is refused.
    /// `inner` makes the runner a call uses from that call's reader; nil makes
    /// a real runner per call.
    init(
        extraEnvironment: [String: String] = [:],
        showsIdentityToRunner: Bool = true,
        inner: ((@escaping LaunchedChildSignaller.ProcessTableReader) -> any BoundedProcessRunning)? = nil
    ) {
        self.extraEnvironment = extraEnvironment
        self.showsIdentityToRunner = showsIdentityToRunner
        self.inner = inner
    }

    /// calls is every call made so far, in the order made.
    var calls: [LaunchCall] { lock.withLock { listed } }

    /// begin lists a call and returns its position with the reader that notes
    /// that call's own identity.
    fileprivate func begin() -> (index: Int, runner: any BoundedProcessRunning) {
        let index = lock.withLock {
            listed.append(LaunchCall(result: nil, identity: nil))
            return listed.count - 1
        }
        let reader: LaunchedChildSignaller.ProcessTableReader = { [self] pid in
            let real = LaunchedChildSignaller.systemProcessTable(pid)
            if let real, real.parentPID == getpid() {
                lock.withLock {
                    if listed[index].identity == nil {
                        listed[index].identity = StoppedChildSupport.RecordedProcess(pid: real.pid, start: real.start)
                    }
                }
            }
            return showsIdentityToRunner ? real : nil
        }
        let runner = inner?(reader) ?? RealBoundedProcessRunner(extraEnvironment: extraEnvironment, readProcessTable: reader)
        return (index, runner)
    }

    fileprivate func finish(_ index: Int, _ result: BoundedProcessResult) {
        lock.withLock { listed[index].result = result }
    }

    var runner: any BoundedProcessRunning { LaunchRunner(launch: self) }

    private static func text(_ recorded: StoppedChildSupport.RecordedProcess) -> String {
        "\(recorded.start.seconds).\(recorded.start.microseconds)"
    }

    private static func describe(call index: Int, _ call: LaunchCall) -> String {
        let who = call.identity.map { ChildCleanup.describe(pid: $0.pid, start: text($0)) } ?? "with no identity"
        return "call \(index) (\(who))"
    }

    /// endChildren ends every child a call started that may still be there,
    /// and removes `directory` only once the decision over every call allows
    /// it. A child is signalled only while its number still shows the start
    /// recorded at launch. A call with no confirmed end and no identity cannot
    /// be signalled: it fails the test naming it and the directory stays.
    func endChildren(removing directory: URL) {
        let all = calls
        var ended: Set<Int32> = []
        for index in LaunchAccount.signalTargets(all) {
            guard let child = all[index].identity else { continue }
            let outcome = ChildCleanup.endRecordedRecordingNotConfirmed(
                pid: child.pid, start: Self.text(child),
                readStart: { ChildCleanup.startNow(pid: $0) },
                exists: { !StoppedChildSupport.isGone(pid: $0) },
                send: { _, signal in StoppedChildSupport.signal(child, signal) },
                waitingMilliseconds: TestChild.hangCeilingMilliseconds
            )
            if outcome == .ended { ended.insert(child.pid) }
        }
        let verdict = LaunchAccount.decide(all, gone: { ended.contains($0.pid) })
        for index in verdict.named where all[index].identity == nil {
            Issue.record("test child \(Self.describe(call: index, all[index])) was not confirmed ended and could not be signalled, it may still be running; \(directory.path) was kept")
        }
        if verdict.removeDirectory { try? FileManager.default.removeItem(at: directory) }
    }

    /// endChildrenAfterRelease is for fixtures that block on an input the test
    /// holds. It releases that input first, on every path, whatever the run
    /// returned, then decides over every call, confirming a call that may
    /// still run by a read of its own identity only: it sends nothing.
    /// `directory` is removed only when the decision allows it; a call it
    /// names fails the test and the directory stays.
    func endChildrenAfterRelease(removing directory: URL, release: () -> Void) {
        release()
        let all = calls
        let verdict = LaunchAccount.decide(all, gone: {
            DescendantCheck.requireGone(pid: $0.pid, start: $0.start, read: { readProcessTable($0) })
        })
        for index in verdict.named {
            Issue.record("test child \(Self.describe(call: index, all[index])) was not confirmed ended after its input was released, it may still be running; \(directory.path) was kept")
        }
        if verdict.removeDirectory { try? FileManager.default.removeItem(at: directory) }
    }

    /// requireEnded fails the test, naming each call the decision names: one
    /// with no confirmed end whose own identity does not read gone now (absent,
    /// or present with another start), or that has no identity.
    func requireEnded() {
        let all = calls
        let verdict = LaunchAccount.decide(all, gone: {
            DescendantCheck.verdict(readProcessTable($0.pid), of: $0.start) == .gone
        })
        for index in verdict.named {
            Issue.record("the child of \(Self.describe(call: index, all[index])) was not shown ended after the run returned")
        }
    }
}

/// LaunchRunner is the runner a test gets from RunnerLaunch. Every method
/// lists its call first and gives that call its own inner runner.
private struct LaunchRunner: BoundedProcessRunning {
    let launch: RunnerLaunch

    func run(executableURL: URL, arguments: [String], standardInputData: Data, timeout: Duration) async -> BoundedProcessResult {
        let call = launch.begin()
        let result = await call.runner.run(executableURL: executableURL, arguments: arguments, standardInputData: standardInputData, timeout: timeout)
        launch.finish(call.index, result)
        return result
    }

    func runCapturingOutput(executableURL: URL, arguments: [String], standardInputData: Data, timeout: Duration) async -> BoundedProcessOutput {
        let call = launch.begin()
        let output = await call.runner.runCapturingOutput(executableURL: executableURL, arguments: arguments, standardInputData: standardInputData, timeout: timeout)
        launch.finish(call.index, output.result)
        return output
    }

    func runOnCallingThread(executableURL: URL, arguments: [String], standardInputData: Data, timeout: Duration) -> BoundedProcessResult {
        let call = launch.begin()
        let result = call.runner.runOnCallingThread(executableURL: executableURL, arguments: arguments, standardInputData: standardInputData, timeout: timeout)
        launch.finish(call.index, result)
        return result
    }
}
