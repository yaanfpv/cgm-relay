import Testing
import Foundation
@testable import CGMRelayCore

@Suite("RealProcessLauncher")
struct RealProcessLauncherTests {
    /// Case names one shell command and the exit code RealProcessLauncher
    /// must report for it through onExit.
    struct Case: Sendable {
        let shellCommand: String
        let wantExitCode: Int32
    }

    /// exitCode launches /bin/sh with `-c shellCommand` through the real
    /// RealProcessLauncher and waits for its onExit callback, returning
    /// whatever code it reports. This is the only place the operating
    /// system's own termination reporting -- an ordinary exit status
    /// against a death by signal -- can actually be observed; every other
    /// test in this package launches a fake that never runs anything.
    private func exitCode(forShellCommand shellCommand: String, standardInputData: Data = Data()) async throws -> Int32 {
        let launcher = RealProcessLauncher()
        return try await withCheckedThrowingContinuation { continuation in
            do {
                _ = try launcher.launch(
                    executableURL: URL(fileURLWithPath: "/bin/sh"),
                    arguments: ["-c", shellCommand],
                    standardInputData: standardInputData,
                    onReady: {}
                ) { exitCode in
                    continuation.resume(returning: exitCode)
                }
            } catch {
                continuation.resume(throwing: error)
            }
        }
    }

    @Test(
        "onExit reports an ordinary exit status unchanged, and a death by signal as the negative of the signal number",
        arguments: [
            Case(shellCommand: "exit 3", wantExitCode: 3),
            Case(shellCommand: "kill -QUIT $$", wantExitCode: -3),
        ]
    )
    func onExitReportsTheRealTerminationReasonCorrectlySigned(_ testCase: Case) async throws {
        let got = try await exitCode(forShellCommand: testCase.shellCommand)
        #expect(got == testCase.wantExitCode)
    }

    @Test("a child that exits immediately without reading a stdin payload larger than a pipe buffer never raises SIGPIPE into this process")
    func childExitingWithoutReadingLargePayloadNeverRaisesSIGPIPE() async throws {
        // Well over one pipe buffer (64 KB): without the per-descriptor
        // SIGPIPE guard, writing this on the background queue after
        // `exit 9` has already closed the read end kills the whole test
        // process outright rather than failing one test.
        let largePayload = Data(repeating: 0x42, count: 200_000)
        let got = try await exitCode(forShellCommand: "exit 9", standardInputData: largePayload)
        #expect(got == 9)
    }

    /// EnvironmentCase names one shell command that exits 0 when the
    /// child process's environment is exactly what it should be, and
    /// something else otherwise -- either an unlisted variable this test
    /// process carries reaching the child (it must not), or an allowed
    /// one failing to (it must).
    struct EnvironmentCase: Sendable {
        let label: String
        let shellCommand: String
    }

    /// This test process sets a synthetic variable of its own before
    /// each case and clears it after, so the two cases below can run
    /// against the exact same real launch() path the rest of this suite
    /// does, never a fake. Serialized because both cases share that one
    /// process-wide variable.
    @Test(
        "the engine child process gets an explicit, minimal environment: nothing this test process happens to carry beyond the allowlist, and every allowed variable still arrives",
        .serialized,
        arguments: [
            EnvironmentCase(label: "an unlisted variable never reaches the child", shellCommand: "[ -z \"$CGMRELAY_TEST_SENTINEL\" ]"),
            EnvironmentCase(label: "an allowed variable still reaches the child", shellCommand: "[ -n \"$HOME\" ]"),
        ]
    )
    func childEnvironmentCases(_ testCase: EnvironmentCase) async throws {
        setenv("CGMRELAY_TEST_SENTINEL", "present", 1)
        defer { unsetenv("CGMRELAY_TEST_SENTINEL") }

        let got = try await exitCode(forShellCommand: testCase.shellCommand)
        #expect(got == 0, "\(testCase.label): shell command \"\(testCase.shellCommand)\" exited \(got)")
    }

    /// LineCollector gathers the lines the launcher forwards.
    private final class LineCollector: @unchecked Sendable {
        private let lock = NSLock()
        private var stored: [String] = []
        var lines: [String] { lock.withLock { stored } }
        func add(_ line: String) { lock.withLock { stored.append(line) } }
    }

    /// forwardedLines runs shellCommand through a launcher whose log sink is
    /// a collector, waits for the child to exit and its stderr to drain,
    /// and returns every line forwarded.
    private func forwardedLines(forShellCommand shellCommand: String, standardInputData: Data = Data()) async throws -> [String] {
        let collector = LineCollector()
        let launcher = RealProcessLauncher(engineLog: { collector.add($0) })
        _ = try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Int32, Error>) in
            do {
                _ = try launcher.launch(
                    executableURL: URL(fileURLWithPath: "/bin/sh"),
                    arguments: ["-c", shellCommand],
                    standardInputData: standardInputData,
                    onReady: {}
                ) { continuation.resume(returning: $0) }
            } catch {
                continuation.resume(throwing: error)
            }
        }
        // The exit callback can precede the last stderr read by a moment.
        for _ in 0..<200 where collector.lines.count < 3 {
            try await Task.sleep(for: .milliseconds(25))
        }
        return collector.lines
    }

    @Test("every complete line the engine writes to stderr is forwarded whole, with CRLF stripped and an unterminated last line kept")
    func engineStderrLinesAreForwardedWhole() async throws {
        let got = try await forwardedLines(
            forShellCommand: "printf 'poller: first\\n' >&2; printf 'poller: second\\r\\n\\n' >&2; printf 'poller: no newline' >&2"
        )

        #expect(got == ["poller: first", "poller: second", "poller: no newline"])
    }

    @Test("a line the engine writes is forwarded while the engine is still running, not when it exits")
    func lineArrivesWhileEngineStillRuns() async throws {
        let collector = LineCollector()
        let launcher = RealProcessLauncher(engineLog: { collector.add($0) })
        let process = try launcher.launch(
            executableURL: URL(fileURLWithPath: "/bin/sh"),
            arguments: ["-c", "printf 'poller: alive\\n' >&2; exec sleep 30"],
            standardInputData: Data(),
            onReady: {}
        ) { _ in }
        defer { process.terminate() }

        for _ in 0..<120 where collector.lines.isEmpty {
            try await Task.sleep(for: .milliseconds(25))
        }
        #expect(collector.lines == ["poller: alive"])
    }

    @Test("a line longer than the bound is cut to it, and the lines after it still arrive")
    func overlongLineIsBounded() async throws {
        let got = try await forwardedLines(
            forShellCommand: "head -c 20000 /dev/zero | tr '\\0' 'x' >&2; printf '\\npoller: after\\npoller: last\\n' >&2"
        )
        #expect(got.count == 3)
        #expect(got.first?.utf8.count == EngineLineSplitter.maxLineBytes)
        #expect(Array(got.dropFirst()) == ["poller: after", "poller: last"])
    }

    /// ReadyCounter counts onReady calls from the launcher's background queue.
    private final class ReadyCounter: @unchecked Sendable {
        private let lock = NSLock()
        private var stored = 0
        var count: Int { lock.withLock { stored } }
        func increment() { lock.withLock { stored += 1 } }
    }

    /// readyCount runs shellCommand, waits for it to exit and for onReady to
    /// have fired `expected` times (up to five seconds, since the stdout
    /// reader can trail the exit callback on a busy machine), then a short
    /// settle so a second, wrong call would still be counted, and returns how
    /// many times onReady fired.
    private func readyCount(forShellCommand shellCommand: String, expected: Int) async throws -> Int {
        let counter = ReadyCounter()
        let launcher = RealProcessLauncher()
        let exit = try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Int32, Error>) in
            do {
                _ = try launcher.launch(
                    executableURL: URL(fileURLWithPath: "/bin/sh"),
                    arguments: ["-c", shellCommand],
                    standardInputData: Data(),
                    onReady: { counter.increment() }
                ) { continuation.resume(returning: $0) }
            } catch {
                continuation.resume(throwing: error)
            }
        }
        #expect(exit == 0)
        for _ in 0..<200 where counter.count < expected {
            try await Task.sleep(for: .milliseconds(25))
        }
        try await Task.sleep(for: .milliseconds(200))
        return counter.count
    }

    @Test(
        "onReady fires once for the engine's ready line, never for other stdout, and a flood of stdout never blocks the child",
        arguments: [
            ReadyCase(shellCommand: "printf 'ready\\n'", wantCount: 1),
            ReadyCase(shellCommand: "printf 'rea'; sleep 0.1; printf 'dy\\nready\\n'", wantCount: 1),
            ReadyCase(shellCommand: "printf 'not ready\\nreadyx\\nready'", wantCount: 0),
            ReadyCase(shellCommand: "head -c 500000 /dev/zero | tr '\\0' 'x'; printf '\\nready\\n'", wantCount: 1),
        ]
    )
    func readyLineFiresOnReady(_ testCase: ReadyCase) async throws {
        #expect(try await readyCount(forShellCommand: testCase.shellCommand, expected: testCase.wantCount) == testCase.wantCount, "\(testCase.shellCommand)")
    }

    struct ReadyCase: Sendable {
        let shellCommand: String
        let wantCount: Int
    }

    /// ScannerCase feeds ReadyLineScanner a stream in the given chunks and
    /// names how many times append must return true across all of them.
    struct ScannerCase: Sendable {
        let chunks: [String]
        let wantReady: Int
    }

    /// The scanner owns "exactly once, and never for anything else": the
    /// launcher calls onReady only when append returns true, so this is the
    /// count contract, checked with no process and no clock. The table above
    /// checks that the real stdout pipe reaches it; a finite wait there can
    /// never rule out a callback arriving arbitrarily late, and this one has
    /// no wait to outlast.
    @Test(
        "the ready-line scanner reports the ready line exactly once and never for other output",
        arguments: [
            ScannerCase(chunks: ["ready\n"], wantReady: 1),
            ScannerCase(chunks: ["rea", "dy\nready\n"], wantReady: 1),
            ScannerCase(chunks: ["ready\nready\nready\n"], wantReady: 1),
            ScannerCase(chunks: ["ready\n", "ready\n", "ready\n"], wantReady: 1),
            ScannerCase(chunks: ["not ready\nreadyx\nready"], wantReady: 0),
            ScannerCase(chunks: ["xready\n", " ready\n", "ready \n", "READY\n"], wantReady: 0),
            ScannerCase(chunks: [String(repeating: "x", count: 500_000), "\nready\n"], wantReady: 1),
        ]
    )
    func scannerReportsTheReadyLineExactlyOnce(_ testCase: ScannerCase) {
        var scanner = ReadyLineScanner()
        let got = testCase.chunks.reduce(0) { count, chunk in count + (scanner.append(Data(chunk.utf8)) ? 1 : 0) }
        #expect(got == testCase.wantReady, "\(testCase.chunks.map { String($0.prefix(40)) })")
    }
}
