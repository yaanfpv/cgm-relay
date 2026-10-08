import Foundation
import Testing
@testable import CGMRelayCore

@Suite("AccountCheckOutcome")
struct AccountCheckOutcomeTests {
    @Test(
        "every check-account exit code maps to its own outcome",
        arguments: [
            (AccountCheckExitCode.signedIn, AccountCheckOutcome.signedIn),
            (AccountCheckExitCode.invalidCredentials, .invalidCredentials),
            (AccountCheckExitCode.termsNotAccepted, .termsNotAccepted),
            (AccountCheckExitCode.noConnections, .noConnections),
            (AccountCheckExitCode.rateLimited, .rateLimited),
            (AccountCheckExitCode.unreachable, .unreachable),
        ] as [(Int32, AccountCheckOutcome)]
    )
    func mapsKnownExitCodes(_ testCase: (Int32, AccountCheckOutcome)) {
        #expect(AccountCheckOutcome.from(exitCode: testCase.0) == testCase.1)
    }

    @Test("an exit code check-account never defines maps to other")
    func unknownExitCodeMapsToOther() {
        #expect(AccountCheckOutcome.from(exitCode: 1) == .other)
        #expect(AccountCheckOutcome.from(exitCode: -15) == .other)
        #expect(AccountCheckOutcome.from(exitCode: 42) == .other)
    }

    @Test("signedIn carries no message; every other outcome carries a non-empty one")
    func everyOutcomeHasTheRightMessagePresence() {
        #expect(AccountCheckOutcome.signedIn.message == nil)
        for outcome: AccountCheckOutcome in [.invalidCredentials, .termsNotAccepted, .noConnections, .rateLimited, .unreachable, .launchFailed, .timedOut, .malformedEmail, .other, .saveFailed] {
            #expect(!(outcome.message ?? "").isEmpty)
        }
    }

    @Test("every non-signedIn outcome's message is distinct from every other")
    func messagesAreDistinct() {
        let outcomes: [AccountCheckOutcome] = [.invalidCredentials, .termsNotAccepted, .noConnections, .rateLimited, .unreachable, .launchFailed, .timedOut, .malformedEmail, .other, .saveFailed]
        let messages = Set(outcomes.compactMap(\.message))
        #expect(messages.count == outcomes.count)
    }
}

/// ScriptedRunner answers every bounded run with one scripted result and
/// output, so each failure category is driven without a process.
private struct ScriptedRunner: BoundedProcessRunning {
    let output: BoundedProcessOutput

    func run(executableURL: URL, arguments: [String], standardInputData: Data, timeout: Duration) async -> BoundedProcessResult {
        output.result
    }

    func runCapturingOutput(executableURL: URL, arguments: [String], standardInputData: Data, timeout: Duration) async -> BoundedProcessOutput {
        output
    }
}

private final class RecordingLog: AccountCheckLogging, @unchecked Sendable {
    private let lock = NSLock()
    private var recorded: [String] = []
    var lines: [String] { lock.withLock { recorded } }
    func record(_ line: String) { lock.withLock { recorded.append(line) } }
}

@Suite("RealAccountChecker")
struct RealAccountCheckerTests {
    private static let email = "person@example.test"
    private static let password = "synthetic-password-1234"
    private static let engine = URL(fileURLWithPath: "/unused/engine")

    private func check(_ output: BoundedProcessOutput) async -> (AccountCheckOutcome, [String]) {
        let log = RecordingLog()
        let checker = RealAccountChecker(engineURL: Self.engine, runner: ScriptedRunner(output: output), log: log)
        let outcome = await checker.checkAccount(email: Self.email, password: Self.password, librelinkupBaseURL: nil)
        return (outcome, log.lines)
    }

    @Test("a launch failure, a timeout and an unknown exit each get their own outcome and one log line naming the category")
    func eachFailureCategoryIsDistinctAndLogged() async {
        let launch = await check(BoundedProcessOutput(result: .failedToLaunch, output: Data()))
        let timeout = await check(BoundedProcessOutput(result: .timedOut, output: Data()))
        let unknown = await check(BoundedProcessOutput(result: .exited(1), output: Data("cgm-relay: check-account: sign-in response carried no user id or token\n".utf8)))

        #expect(launch.0 == .launchFailed)
        #expect(timeout.0 == .timedOut)
        #expect(unknown.0 == .other)
        #expect(launch.1.count == 1 && launch.1[0].contains("launch-failed"))
        #expect(timeout.1.count == 1 && timeout.1[0].contains("timed-out"))
        #expect(unknown.1.count == 1 && unknown.1[0].contains("unknown-exit") && unknown.1[0].contains("status=1"))
        #expect(unknown.1[0].contains("sign-in response carried no user id or token"))
        #expect(Set([launch.0.message, timeout.0.message, unknown.0.message]).count == 3)
    }

    @Test("a known exit code writes no failure line")
    func knownExitIsNotLogged() async {
        let (outcome, lines) = await check(BoundedProcessOutput(result: .exited(AccountCheckExitCode.invalidCredentials), output: Data()))
        #expect(outcome == .invalidCredentials)
        #expect(lines.isEmpty)
    }

    @Test("the logged reason never carries the email, password, a token or a provider body")
    func loggedReasonIsSanitized() async {
        let token = "eyJhbGciOiJIUzI1NiJ9abcdefghijklmnop"
        let stderr = "cgm-relay: check-account: \(Self.email) \(Self.password) bearer \(token) {\"data\":\"raw provider body\"}\nsecond line"
        let (_, lines) = await check(BoundedProcessOutput(result: .exited(1), output: Data(stderr.utf8)))

        #expect(lines.count == 1)
        for planted in [Self.email, Self.password, token, "raw provider body", "second line", "person"] {
            #expect(!lines[0].contains(planted), "log line leaked \(planted)")
        }
    }

    @Test("a reason is capped in length and stripped of control characters")
    func reasonIsBounded() {
        let long = String(repeating: "word ", count: 200) + "\u{1B}[31m"
        let reason = AccountCheckReason.sanitize(long, email: "a@b.c", password: "x")
        #expect(reason.count <= AccountCheckReason.maxLength)
        #expect(!reason.unicodeScalars.contains { CharacterSet.controlCharacters.contains($0) })
    }

    /// writeEngine writes a stand-in engine script and returns its URL.
    private func writeEngine(_ body: String) throws -> URL {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("account-checker-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let url = dir.appendingPathComponent("engine")
        try Data("#!/bin/sh\n\(body)\n".utf8).write(to: url)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: url.path)
        return url
    }

    @Test("a check that outlives its timeout is ended, even if it ignores the request to stop")
    func timedOutCheckProcessIsEnded() async throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("account-checker-pid-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let pidFile = dir.appendingPathComponent("pid").path
        let engine = try writeEngine("trap '' TERM\necho $$ > '\(pidFile)'\nwhile :; do sleep 0.1; done")
        let log = RecordingLog()
        let checker = RealAccountChecker(engineURL: engine, timeout: .seconds(2), log: log)

        let outcome = await checker.checkAccount(email: Self.email, password: Self.password, librelinkupBaseURL: nil)

        #expect(outcome == .timedOut)
        let pid = try #require(Int32(String(contentsOfFile: pidFile, encoding: .utf8).trimmingCharacters(in: .whitespacesAndNewlines)))
        #expect(kill(pid, 0) != 0, "the timed-out check process must be gone")
        #expect(log.lines.count == 1)
    }

    @Test("a real child that echoes the request it was given still leaves the log clean")
    func echoingChildLeavesLogClean() async throws {
        let engine = try writeEngine("cat >&2\nexit 1")
        let log = RecordingLog()
        let checker = RealAccountChecker(engineURL: engine, log: log)

        let outcome = await checker.checkAccount(email: Self.email, password: Self.password, librelinkupBaseURL: nil)

        #expect(outcome == .other)
        #expect(log.lines.count == 1)
        #expect(!log.lines[0].contains(Self.password))
        #expect(!log.lines[0].contains(Self.email))
    }
}

@Suite("AccountEmail")
struct AccountEmailTests {
    @Test(
        "malformed emails are refused and well-formed ones are trimmed",
        arguments: [
            ("", nil), ("   ", nil), ("abc", nil), ("a@", nil), ("a@b", nil), ("@b.c", nil),
            ("a@@b.c", nil), ("a@b.", nil), ("a@.c", nil), ("a b@c.d", nil),
            ("a@b.c", "a@b.c"), (" a@b.c ", "a@b.c"), ("\na@b.co\t", "a@b.co"),
        ] as [(String, String?)]
    )
    func validation(_ testCase: (String, String?)) {
        #expect(AccountEmail.trimmedIfValid(testCase.0) == testCase.1)
    }
}
