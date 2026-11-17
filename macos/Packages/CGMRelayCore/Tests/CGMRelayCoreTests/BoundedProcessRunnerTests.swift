import Testing
import Foundation
@testable import CGMRelayCore

@Suite("RealBoundedProcessRunner")
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
        defer { try? FileManager.default.removeItem(at: dir) }
        let marker = dir.appendingPathComponent("marker")
        #expect(!FileManager.default.fileExists(atPath: marker.path))

        let runner = RealBoundedProcessRunner()
        let result = await runner.run(
            executableURL: URL(fileURLWithPath: "/usr/bin/perl"),
            arguments: ["-e", Self.perlScript(ignoringTerminate: testCase.ignoresTerminate), marker.path],
            standardInputData: Data(),
            timeout: .seconds(3)
        )

        // The runner returns only after it has observed the child's own exit,
        // which the launcher's real-child tests cover, so a number read back
        // from a file is not probed here: it could name someone else by then.
        // A runner that waited for the child to finish by itself would
        // write the marker.
        #expect(result == .timedOut)
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
        var hung = false
        defer {
            // Only a run that never returned leaves its child behind.
            if hung, let text = try? String(contentsOf: pidFile, encoding: .utf8), let pid = Int32(text) {
                kill(pid, SIGKILL)
            }
            try? FileManager.default.removeItem(at: dir)
        }
        // The child records its pid, then stops itself: the same state as a
        // stop sent from outside, with no pid this test did not start.
        let script = "open(my $f,\">\",$ARGV[0]) or die; print $f $$; close($f) or die; kill 'STOP', $$; sleep 30"
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
        hung = result == nil
        try #require(result != nil, "the run did not end for a stopped child")
        #expect(result == .timedOut)

        let pid = try #require(Int32(try String(contentsOf: pidFile, encoding: .utf8)))
        #expect(StoppedChildSupport.isGone(pid: pid), "child \(pid) was not reaped")
    }
}

@Suite("RealBoundedProcessRunner on the calling thread")
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
        defer { try? FileManager.default.removeItem(at: dir) }
        let marker = dir.appendingPathComponent("marker")
        let script = (ignoresTerminate ? "$SIG{TERM}='IGNORE'; " : "")
            + "sleep 30; open(my $m,\">\",$ARGV[0]) or die; print $m \"done\"; close($m) or die"

        let runner = RealBoundedProcessRunner()
        let result = await onPlainThread {
            runner.runOnCallingThread(
                executableURL: URL(fileURLWithPath: "/usr/bin/perl"),
                arguments: ["-e", script, marker.path],
                standardInputData: Data(),
                timeout: .milliseconds(300)
            )
        }
        #expect(result == .timedOut)
        #expect(!FileManager.default.fileExists(atPath: marker.path), "the child ran to its natural end")
    }
}
