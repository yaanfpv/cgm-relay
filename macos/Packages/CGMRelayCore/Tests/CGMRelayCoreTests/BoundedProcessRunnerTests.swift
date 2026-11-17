import Testing
import Foundation
@testable import CGMRelayCore

/// LaunchRecorder keeps the identity a launch recorded for its child.
private final class LaunchRecorder: @unchecked Sendable {
    private let lock = NSLock()
    private var stored: StoppedChildSupport.RecordedProcess?
    var recorded: StoppedChildSupport.RecordedProcess? { lock.withLock { stored } }
    func set(pid: Int32, start: ProcessStart) {
        lock.withLock { if stored == nil { stored = StoppedChildSupport.RecordedProcess(pid: pid, start: start) } }
    }
}

/// RunnerLaunch is a runner whose launch read is recorded: the identity the
/// signaller took of its child while the child was necessarily unreaped. The read
/// itself is the real one, so the runner signals and reaps as it does in the app.
private struct RunnerLaunch {
    let recorder = LaunchRecorder()
    var runner: RealBoundedProcessRunner {
        let recorder = recorder
        return RealBoundedProcessRunner(readProcessTable: { pid in
            let real = LaunchedChildSignaller.systemProcessTable(pid)
            if let real, real.parentPID == getpid() { recorder.set(pid: real.pid, start: real.start) }
            return real
        })
    }

    /// endChild ends the child the runner launched, if it is still there, and removes
    /// `directory` only once that is confirmed. The number is signalled only while it
    /// still shows the start recorded at launch. A child not confirmed ended fails the test naming it.
    func endChild(removing directory: URL) {
        guard let recorded = recorder.recorded else {
            try? FileManager.default.removeItem(at: directory)
            return
        }
        ChildCleanup.endRecordedRemovingOnEnd(
            pid: recorded.pid, start: "\(recorded.start.seconds).\(recorded.start.microseconds)",
            removingOnEnd: directory,
            readStart: { ChildCleanup.startNow(pid: $0) },
            exists: { !StoppedChildSupport.isGone(pid: $0) },
            send: { _, signal in StoppedChildSupport.signal(recorded, signal) },
            waitingMilliseconds: TestChild.hangCeilingMilliseconds
        )
    }

    /// requireEnded fails the test, naming the child, unless the typed table read
    /// shows it gone now: absent, or present with another start. A child still
    /// there, or a record that cannot be read, is not an end.
    func requireEnded() {
        guard let recorded = recorder.recorded else {
            Issue.record("no identity was recorded for the launched child, so its end could not be checked")
            return
        }
        let read = readProcessTable(recorded.pid)
        let verdict = DescendantCheck.verdict(read, of: recorded.start)
        #expect(verdict == .gone, "the child \(recorded.pid) was not shown ended after the run returned: \(verdict) (read \(read))")
    }
}

@Suite("RealBoundedProcessRunner", .noSurvivingChildren)
struct RealBoundedProcessRunnerTests {
    @Test("reports an ordinary exit code")
    func reportsExitCode() async throws {
        let runner = RealBoundedProcessRunner()
        let result = await runner.run(
            executableURL: URL(fileURLWithPath: "/bin/sh"),
            arguments: ["-c", "exit 12"],
            standardInputData: Data(),
            timeout: .seconds(5)
        )
        #expect(result == .exited(12))
    }

    @Test("reports a death by signal as the negative of the signal number")
    func reportsSignalDeath() async throws {
        let runner = RealBoundedProcessRunner()
        let result = await runner.run(
            executableURL: URL(fileURLWithPath: "/bin/sh"),
            arguments: ["-c", "kill -QUIT $$"],
            standardInputData: Data(),
            timeout: .seconds(5)
        )
        #expect(result == .exited(-3))
    }

    @Test("writes standardInputData to the child's stdin")
    func writesStandardInput() async throws {
        let runner = RealBoundedProcessRunner()
        let result = await runner.run(
            executableURL: URL(fileURLWithPath: "/bin/sh"),
            arguments: ["-c", "read line; [ \"$line\" = hello ]"],
            standardInputData: Data("hello\n".utf8),
            timeout: .seconds(5)
        )
        #expect(result == .exited(0))
    }

    /// TimeoutCase names one perl child that must outlive the runner's timeout.
    struct TimeoutCase: Sendable, CustomTestStringConvertible {
        let label: String
        let ignoresTerminate: Bool
        var testDescription: String { label }
    }

    /// One single-process child (perl forks nothing). It sleeps and writes
    /// its file only if it gets to finish naturally.
    private static func perlScript(ignoringTerminate: Bool) -> String {
        (ignoringTerminate ? "$SIG{TERM}='IGNORE'; " : "")
            + "sleep 30; "
            + "open(my $m,\">\",$ARGV[0]) or die; print $m \"done\"; close($m) or die"
    }

    @Test(
        "a process that outlives the timeout is ended by the runner and reported as timedOut",
        arguments: [
            TimeoutCase(label: "an ordinary child", ignoresTerminate: false),
            TimeoutCase(label: "a child that ignores SIGTERM", ignoresTerminate: true),
        ]
    )
    func timeoutEndsTheProcess(_ testCase: TimeoutCase) async throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("runner-timeout-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        // The child's own timer is 30 s, so its absence of a marker proves nothing about
        // its end: the end is read from the process table, and a child left alive is ended here.
        let launch = RunnerLaunch()
        defer { launch.endChild(removing: dir) }
        let marker = dir.appendingPathComponent("marker")
        #expect(!FileManager.default.fileExists(atPath: marker.path))

        let runner = launch.runner
        let result = await runner.run(
            executableURL: URL(fileURLWithPath: "/usr/bin/perl"),
            arguments: ["-e", Self.perlScript(ignoringTerminate: testCase.ignoresTerminate), marker.path],
            standardInputData: Data(),
            timeout: .seconds(3)
        )

        // A runner that waited for the child to finish by itself would
        // write the marker.
        #expect(result == .timedOut)
        launch.requireEnded()
        #expect(!FileManager.default.fileExists(atPath: marker.path), "the child ran to its natural end")
    }

    @Test("a timeout that races the child's own exit gives one of the two outcomes and always returns")
    func timeoutRacingNaturalExitReturns() async throws {
        let runner = RealBoundedProcessRunner()
        for _ in 0..<25 {
            let result = await runner.run(
                executableURL: URL(fileURLWithPath: "/usr/bin/true"),
                arguments: [],
                standardInputData: Data(),
                timeout: .milliseconds(1)
            )
            #expect(result == .timedOut || result == .exited(0), "got \(result)")
        }
    }

    @Test("a child that exits immediately without reading a stdin payload larger than a pipe buffer never raises SIGPIPE into this process")
    func childExitingWithoutReadingLargePayloadNeverRaisesSIGPIPE() async throws {
        let runner = RealBoundedProcessRunner()
        // Well over one pipe buffer (64 KB): without the per-descriptor
        // SIGPIPE guard, writing this after `exit 7` has already closed
        // the read end kills the whole test process outright rather than
        // failing one test.
        let largePayload = Data(repeating: 0x41, count: 200_000)
        let result = await runner.run(
            executableURL: URL(fileURLWithPath: "/bin/sh"),
            arguments: ["-c", "exit 7"],
            standardInputData: largePayload,
            timeout: .seconds(5)
        )
        #expect(result == .exited(7))
    }

    @Test("a missing executable is reported as failedToLaunch")
    func missingExecutableFailsToLaunch() async throws {
        let runner = RealBoundedProcessRunner()
        let result = await runner.run(
            executableURL: URL(fileURLWithPath: "/no/such/executable-cgmrelay-test"),
            arguments: [],
            standardInputData: Data(),
            timeout: .seconds(5)
        )
        #expect(result == .failedToLaunch)
    }

    @Test("runCapturingOutput returns stdout and stderr, including more than one pipe buffer")
    func capturesOutput() async throws {
        let runner = RealBoundedProcessRunner()
        let run = await runner.runCapturingOutput(
            executableURL: URL(fileURLWithPath: "/bin/sh"),
            arguments: ["-c", "echo out; echo err >&2; head -c 200000 /dev/zero | tr '\\0' A; exit 4"],
            standardInputData: Data(),
            timeout: .seconds(10)
        )
        #expect(run.result == .exited(4))
        let text = String(decoding: run.output, as: UTF8.self)
        #expect(text.hasPrefix("out\nerr\n"))
        #expect(run.output.count == 8 + 200_000)
    }

    /// StoppedRunMode names which of the runner's entry points runs the child.
    enum StoppedRunMode: String, Sendable, CaseIterable, CustomTestStringConvertible {
        case run, runCapturingOutput, runOnCallingThread
        var testDescription: String { rawValue }
    }

    @Test("a child stopped while it runs ends the run as timedOut and is reaped", arguments: StoppedRunMode.allCases)
    func stoppedChildEndsTheRunAsTimedOut(_ mode: StoppedRunMode) async throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("runner-stopped-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let pidFile = dir.appendingPathComponent("pid")
        var runResult: BoundedProcessResult?
        defer {
            // Whatever the run returned, the child it started is ended here
            // unless it is already gone. Its number is signalled only while ps
            // still shows the start time the child itself recorded before it
            // stopped. A child whose end is not confirmed fails the test
            // naming it, and its record stays on disk. A missing record counts
            // as "nothing started" only when the runner reported that the
            // launch itself failed.
            ChildCleanup.endRecordedChild(
                pidFile: pidFile, removingOnEnd: dir,
                launchFailed: runResult == .failedToLaunch,
                readStart: { Self.lstart(ofPid: $0) },
                exists: { !StoppedChildSupport.isGone(pid: $0) },
                send: { kill($0, $1) },
                waitingMilliseconds: TestChild.hangCeilingMilliseconds
            )
        }
        // The child records its pid and its own start time (read by the
        // child itself), then stops itself: the same state as a stop sent
        // from outside, with no pid this test did not start.
        let script = "open(my $f,\">\",$ARGV[0]) or die; print $f \"$$\\n\", `/bin/ps -o lstart= -p $$`; close($f) or die; kill 'STOP', $$; sleep 30"
        let executable = URL(fileURLWithPath: "/usr/bin/perl")
        let arguments = ["-e", script, pidFile.path]

        let runner = RealBoundedProcessRunner()
        let result: BoundedProcessResult?
        switch mode {
        case .run:
            result = await StoppedChildSupport.withinAsync {
                await runner.run(executableURL: executable, arguments: arguments, standardInputData: Data(), timeout: .seconds(1))
            }
        case .runCapturingOutput:
            result = await StoppedChildSupport.withinAsync {
                await runner.runCapturingOutput(executableURL: executable, arguments: arguments, standardInputData: Data(), timeout: .seconds(1)).result
            }
        case .runOnCallingThread:
            result = await StoppedChildSupport.withinBlocking {
                runner.runOnCallingThread(executableURL: executable, arguments: arguments, standardInputData: Data(), timeout: .seconds(1))
            }
        }
        runResult = result
        try #require(result != nil, "the run did not end for a stopped child")
        #expect(result == .timedOut)

        let recordedChild = try #require(Self.readRecordedChild(pidFile: pidFile))
        #expect(StoppedChildSupport.isGone(pid: recordedChild.pid), "child \(recordedChild.pid) was not reaped")
    }

    /// readRecordedChild reads the pid and start time the test child wrote
    /// about itself: the pid on the first line, `ps -o lstart=` on the second.
    private static func readRecordedChild(pidFile: URL) -> (pid: Int32, lstart: String)? {
        guard let text = try? String(contentsOf: pidFile, encoding: .utf8) else { return nil }
        let lines = text.split(separator: "\n", omittingEmptySubsequences: false).map(String.init)
        guard lines.count >= 2, let pid = Int32(lines[0]) else { return nil }
        let lstart = lines[1].trimmingCharacters(in: .whitespaces)
        return lstart.isEmpty ? nil : (pid, lstart)
    }

    /// lstart reads `ps -o lstart= -p pid`, bounded by the hang ceiling. It is
    /// nil when ps fails or finds no such process. A ps whose end is not
    /// confirmed fails the test naming it, since its answer is then unknown.
    private static func lstart(ofPid pid: Int32) -> String? {
        let observation = ObservedHelper.read(
            executable: "/bin/ps",
            arguments: ["-o", "lstart=", "-p", String(pid)],
            waitingMilliseconds: TestChild.hangCeilingMilliseconds
        )
        observation.failIfNotEnded()
        guard let text = observation.output, !text.isEmpty else { return nil }
        return text
    }

    @Test(
        "a child that cannot be signalled ends the run as notConfirmedEnded, never as timedOut",
        arguments: [StoppedRunMode.run, StoppedRunMode.runOnCallingThread]
    )
    func unsignallableChildIsNotConfirmedEnded(_ mode: StoppedRunMode) async throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("runner-refused-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let pidFile = dir.appendingPathComponent("pid")
        // The reader sees the launch's own read of the child first, while the
        // child is necessarily unreaped, and keeps that identity; it then
        // reports no record, so no identity is accepted and every send is
        // refused.
        let launch = LaunchRecorder()
        defer {
            // The child stopped itself, so it cannot end by its own and the
            // runner sent it nothing. It is ended here, and only while its
            // number still shows the start time recorded at launch. The
            // directory with the child's own record is removed only once its end
            // is confirmed; otherwise the test fails naming the child and the
            // record stays.
            if let recorded = launch.recorded {
                ChildCleanup.endRecordedRemovingOnEnd(
                    pid: recorded.pid, start: "\(recorded.start.seconds).\(recorded.start.microseconds)",
                    removingOnEnd: dir,
                    readStart: { ChildCleanup.startNow(pid: $0) },
                    exists: { !StoppedChildSupport.isGone(pid: $0) },
                    send: { _, signal in StoppedChildSupport.signal(recorded, signal) },
                    waitingMilliseconds: TestChild.hangCeilingMilliseconds
                )
            }
        }
        let script = "open(my $f,\">\",$ARGV[0]) or die; print $f $$; close($f) or die; kill 'STOP', $$; sleep 30"
        let executable = URL(fileURLWithPath: "/usr/bin/perl")
        let arguments = ["-e", script, pidFile.path]

        let runner = RealBoundedProcessRunner(readProcessTable: { pid in
            if let entry = LaunchedChildSignaller.systemProcessTable(pid), entry.parentPID == getpid() {
                launch.set(pid: entry.pid, start: entry.start)
            }
            return nil
        })
        let result: BoundedProcessResult?
        switch mode {
        case .run:
            result = await StoppedChildSupport.withinAsync {
                await runner.run(executableURL: executable, arguments: arguments, standardInputData: Data(), timeout: .milliseconds(500))
            }
        case .runCapturingOutput:
            result = await StoppedChildSupport.withinAsync {
                await runner.runCapturingOutput(executableURL: executable, arguments: arguments, standardInputData: Data(), timeout: .milliseconds(500)).result
            }
        case .runOnCallingThread:
            result = await StoppedChildSupport.withinBlocking {
                runner.runOnCallingThread(executableURL: executable, arguments: arguments, standardInputData: Data(), timeout: .milliseconds(500))
            }
        }
        try #require(result != nil, "the run did not return for a child that could not be signalled")
        try #require(launch.recorded != nil, "no identity was recorded for the launched child")
        #expect(result == .notConfirmedEnded)
    }
}

@Suite("RealBoundedProcessRunner on the calling thread", .noSurvivingChildren)
struct RealBoundedProcessRunnerCallingThreadTests {
    /// Runs body on a thread of its own, so the call is made from a plain
    /// thread and never from one of Swift's pool threads.
    private func onPlainThread<T: Sendable>(_ body: @escaping @Sendable () -> T) async -> T {
        await withCheckedContinuation { continuation in
            Thread { continuation.resume(returning: body()) }.start()
        }
    }

    @Test("reports an exit code, a death by signal and a missing executable")
    func reportsOutcomes() async {
        let runner = RealBoundedProcessRunner()
        let results: [BoundedProcessResult] = await onPlainThread {
            [
                runner.runOnCallingThread(executableURL: URL(fileURLWithPath: "/bin/sh"), arguments: ["-c", "exit 12"], standardInputData: Data(), timeout: .seconds(5)),
                runner.runOnCallingThread(executableURL: URL(fileURLWithPath: "/bin/sh"), arguments: ["-c", "kill -QUIT $$"], standardInputData: Data(), timeout: .seconds(5)),
                runner.runOnCallingThread(executableURL: URL(fileURLWithPath: "/no/such/executable-cgmrelay-test"), arguments: [], standardInputData: Data(), timeout: .seconds(5)),
            ]
        }
        #expect(results == [.exited(12), .exited(-3), .failedToLaunch])
    }

    @Test("writes standardInputData to the child's stdin")
    func writesStandardInput() async {
        let runner = RealBoundedProcessRunner()
        let result = await onPlainThread {
            runner.runOnCallingThread(
                executableURL: URL(fileURLWithPath: "/bin/sh"),
                arguments: ["-c", "read line; [ \"$line\" = hello ]"],
                standardInputData: Data("hello\n".utf8),
                timeout: .seconds(5)
            )
        }
        #expect(result == .exited(0))
    }

    @Test("a child that outlives the timeout is ended and reported as timedOut", arguments: [false, true])
    func timeoutEndsTheProcess(ignoresTerminate: Bool) async throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("runner-sync-timeout-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        // The end is read from the process table; a child left alive is ended here.
        let launch = RunnerLaunch()
        defer { launch.endChild(removing: dir) }
        let marker = dir.appendingPathComponent("marker")
        let script = (ignoresTerminate ? "$SIG{TERM}='IGNORE'; " : "")
            + "sleep 30; open(my $m,\">\",$ARGV[0]) or die; print $m \"done\"; close($m) or die"

        let runner = launch.runner
        let result = await onPlainThread {
            runner.runOnCallingThread(
                executableURL: URL(fileURLWithPath: "/usr/bin/perl"),
                arguments: ["-e", script, marker.path],
                standardInputData: Data(),
                timeout: .milliseconds(300)
            )
        }
        #expect(result == .timedOut)
        launch.requireEnded()
        #expect(!FileManager.default.fileExists(atPath: marker.path), "the child ran to its natural end")
    }
}
