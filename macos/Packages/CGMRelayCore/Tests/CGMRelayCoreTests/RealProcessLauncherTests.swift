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
                    standardInputData: standardInputData
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
}
