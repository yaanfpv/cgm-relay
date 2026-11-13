import Testing
import Foundation

/// These checks are the contract of the test-target routine every test uses to
/// end a child it started (Support/TestChild.swift): it ends the child by
/// closing its input, waits on the child's exit event, and says "ended" only
/// when that event happened. They run real children, send no signal, and leave
/// no child running: the one child that ignores end of input is released
/// through a descriptor this suite owns, then ended.
///
/// The routine under test:
///
///     enum ChildEnd: Equatable { case ended; case unknown(pid: Int32, reason: String) }
///
///     final class TestChild: @unchecked Sendable {
///         static let hangCeilingMilliseconds: Int32      // the repo's hang ceiling, 30_000
///         init(executable: String, arguments: [String]) throws   // launches; owns stdin and stdout pipes
///         let processIdentifier: Int32
///         let standardOutput: FileHandle
///         func closeInput()                                       // idempotent
///         func end(waitingMilliseconds: Int32 = hangCeilingMilliseconds) -> ChildEnd
///         func endRecordingUnknown(waitingMilliseconds: Int32 = hangCeilingMilliseconds)
///     }
///
/// `end` closes the input, then waits on the exit event for at most the given
/// bound. It may be called again after an unknown result and then reports
/// ended once the child has exited. `endRecordingUnknown` calls `end` and, for
/// an unknown result, records a test failure whose comment names the pid.
@Suite("TestChild ends a child by end of input")
struct ChildEndingTests {
    private static let python = "/usr/bin/python3"

    /// A bound short enough to pass while a child ignores end of input. It
    /// decides nothing about timing: the child below cannot exit until this
    /// suite releases it, so no host speed can make the bound outlast it.
    private static let shortBoundMilliseconds: Int32 = 200

    private func makeDirectory() throws -> URL {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("child-ending-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
    }

    @Test("a child that exits on end of input is reported ended, and it is gone when ended is reported")
    func childExitingOnEndOfInputIsEnded() throws {
        let child = try TestChild(executable: Self.python, arguments: ["-I", "-c", "import sys\nsys.stdin.read()"])
        defer { child.endRecordingUnknown() }
        let pid = child.processIdentifier

        let outcome = child.end()

        #expect(outcome == .ended)
        // An existence probe, not a signal: ended must mean the exit event happened.
        #expect(kill(pid, 0) != 0 && errno == ESRCH, "pid \(pid) was reported ended but still exists")
    }

    @Test("a child that ignores end of input is reported unknown naming its pid, never ended, and is ended once it exits by its own")
    func childIgnoringEndOfInputIsUnknownThenEnded() throws {
        let dir = try makeDirectory()
        defer { try? FileManager.default.removeItem(at: dir) }
        let fifo = dir.appendingPathComponent("release").path
        try #require(mkfifo(fifo, 0o600) == 0)
        // Read-write open never blocks on a FIFO; holding it keeps the child's own open from blocking too.
        let releaseFD = open(fifo, O_RDWR)
        try #require(releaseFD >= 0)
        defer { close(releaseFD) }

        // The child never reads its stdin; it exits only after one byte arrives on the FIFO.
        let child = try TestChild(
            executable: Self.python,
            arguments: ["-I", "-c", "import sys\nopen(sys.argv[1],'rb').read(1)", fifo]
        )
        func release() { _ = write(releaseFD, "x", 1) }
        // Release first so a failed expectation below cannot leave the child waiting.
        defer { release(); child.endRecordingUnknown() }
        let pid = child.processIdentifier

        let first = child.end(waitingMilliseconds: Self.shortBoundMilliseconds)

        switch first {
        case .ended:
            Issue.record("pid \(pid) ignores end of input and has not been released, but was reported ended")
        case .unknown(let reportedPID, _):
            #expect(reportedPID == pid)
        }

        release()
        #expect(child.end() == .ended)
    }

    @Test("an unknown outcome is recorded as a test failure that names the pid")
    func unknownOutcomeIsRecordedNamingThePid() throws {
        let dir = try makeDirectory()
        defer { try? FileManager.default.removeItem(at: dir) }
        let fifo = dir.appendingPathComponent("release").path
        try #require(mkfifo(fifo, 0o600) == 0)
        let releaseFD = open(fifo, O_RDWR)
        try #require(releaseFD >= 0)
        defer { close(releaseFD) }

        let child = try TestChild(
            executable: Self.python,
            arguments: ["-I", "-c", "import sys\nopen(sys.argv[1],'rb').read(1)", fifo]
        )
        defer { _ = write(releaseFD, "x", 1); child.endRecordingUnknown() }
        let pid = "\(child.processIdentifier)"

        // withKnownIssue passes only if a failure was recorded, and only one that names the pid.
        withKnownIssue(
            "the child ignores end of input until released",
            { child.endRecordingUnknown(waitingMilliseconds: Self.shortBoundMilliseconds) },
            matching: { issue in issue.comments.contains { String(describing: $0).contains(pid) } }
        )
    }
}
