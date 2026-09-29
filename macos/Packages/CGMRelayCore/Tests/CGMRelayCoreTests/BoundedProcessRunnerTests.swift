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

    @Test("a process that outlives timeout is terminated and reported as timedOut")
    func timeoutTerminatesTheProcess() async throws {
        let runner = RealBoundedProcessRunner()
        let start = ContinuousClock.now
        let result = await runner.run(
            executableURL: URL(fileURLWithPath: "/bin/sh"),
            arguments: ["-c", "sleep 30"],
            standardInputData: Data(),
            timeout: .milliseconds(200)
        )
        let elapsed = ContinuousClock.now - start
        #expect(result == .timedOut)
        #expect(elapsed < .seconds(5), "must not wait anywhere near the process's own sleep duration")
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
}
