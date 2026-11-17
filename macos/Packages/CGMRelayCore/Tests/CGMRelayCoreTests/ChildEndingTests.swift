import Testing
import Foundation
@testable import CGMRelayCore

/// These checks are the contract of TestChild (Support/TestChild.swift), the
/// test-target routine the credential lock test uses to end its child: it ends the child by
/// closing its input, waits on the child's exit event, and says "ended" only
/// when that event happened. They run real children and send no signal. Each
/// child is ended by its test: the one that ignores end of input is released
/// through a descriptor this suite owns, and one whose end is not confirmed
/// fails the test naming it.
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
@Suite("TestChild ends a child by end of input", .noSurvivingChildren)
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

// MARK: - Cleanup of the children the process suites start

// The checks below name three helpers the process suites call, all in the
// test target's Support folder:
//
//     enum ChildCleanup {
//         enum Outcome: Equatable { case ended; case notConfirmed(pid: Int32, start: String?) }
//
//         // A child the caller still holds. Does nothing and returns .ended when
//         // alreadyEnded. Otherwise runs send(), then waitForEnd(waitingMilliseconds),
//         // which says whether the exit event was observed.
//         static func endHeld(pid: Int32, start: String?, alreadyEnded: Bool,
//                             send: () -> Void, waitForEnd: (Int32) -> Bool,
//                             waitingMilliseconds: Int32) -> Outcome
//         // The same, and for a result other than .ended it records a test
//         // failure naming the pid and the start text. Result is discardable.
//         static func endHeldRecordingNotConfirmed(<same parameters>) -> Outcome
//
//         // A child known only by the pid and start text recorded at its launch.
//         // A send happens only when readStart(pid) returns exactly the recorded
//         // start. The child counts as gone when exists(pid) is false or
//         // readStart(pid) returns some other start. A start that cannot be read
//         // while the number still exists sends nothing and is .notConfirmed.
//         // After a send it waits, up to waitingMilliseconds, for the child to go.
//         static func endRecorded(pid: Int32, start: String,
//                                 readStart: (Int32) -> String?, exists: (Int32) -> Bool,
//                                 send: (Int32, Int32) -> Void,
//                                 waitingMilliseconds: Int32) -> Outcome
//         // Reads the record a test child wrote about itself (its pid on the first
//         // line, its start text on the second), ends it as endRecorded does and
//         // deletes `directory` only when the outcome is .ended. A result other
//         // than .ended is recorded as a test failure naming the pid and the
//         // start text, and the record stays. Result is discardable.
//         static func endRecordedChild(pidFile: URL, removingOnEnd directory: URL,
//                                      readStart: (Int32) -> String?, exists: (Int32) -> Bool,
//                                      send: (Int32, Int32) -> Void,
//                                      waitingMilliseconds: Int32) -> Outcome
//     }
//
//     enum ObservedHelper {
//         struct Observation { let output: String?; let helperPid: Int32?; let birthStart: String?
//                              let helperEnded: Bool; let helper: HeldChild? }
//         // Starts the helper through ChildSpawner, which holds it from birth, waits
//         // for its confirmed reap for at most the bound and returns its trimmed
//         // standard output only when it exited with status 0 in time. A helper
//         // that did not finish is sent TERM, then KILL, only through its held
//         // signaller. helperEnded is true only when its reap was confirmed (or
//         // none was started); false names the helper by pid and birth start.
//         static func read(executable: String, arguments: [String], waitingMilliseconds: Int32) -> Observation
//     }
//
//     enum ChildSurvivors {
//         struct Child: Equatable, Sendable { let pid: Int32; let start: String? }
//         static func census(parent: pid_t, listPids: ListPids = system) -> Census   // typed read, below
//         static func new(since before: [Child], now: [Child]) -> [Child]
//         static func recordSurvivors(_ survivors: [Child])           // one failure per survivor naming its pid and start
//         final class Accounting: @unchecked Sendable {
//             init(census: @escaping @Sendable () -> Census)
//             func enter()                                            // the first enter takes the baseline census; a failed one fails the test naming it
//             func exit() -> [Child]                                  // the last exit returns the children new since the baseline, others return []; a failed census fails the test naming it
//         }
//     }
//
// The typed reads (Support/ChildSurvivors.swift) the failed-read checks below are written against:
//
//     enum Census: Equatable, Sendable { case listed([pid_t]); case failed(Int32) }   // failed carries errno
//     // ListPids has proc_listpids's own shape and sets errno the way libproc does: 0 with errno set is a failure.
//     typealias ListPids = @Sendable (_ type: UInt32, _ typeinfo: UInt32, _ buffer: UnsafeMutableRawPointer?, _ byteCount: Int32) -> Int32
//
//     enum TableRead: Equatable { case present(ProcessRecord); case absent; case unreadable(Int32) }
//     // ProcPidInfo has proc_pidinfo(pid, PROC_PIDTBSDINFO, 0, buffer, size)'s shape; 0 with errno ESRCH is absent.
//     typealias ProcPidInfo = @Sendable (_ pid: pid_t, _ buffer: UnsafeMutableRawPointer, _ byteCount: Int32) -> Int32
//     func readProcessTable(_ pid: pid_t, pidInfo: ProcPidInfo = system) -> TableRead
//
//     enum DescendantCheck {
//         enum Verdict: Equatable { case stillThere, gone, unreadable(Int32) }
//         static func verdict(_ read: TableRead, of start: ProcessStart) -> Verdict
//         // Polls `read` until the descendant with `start` is gone. Returns at the first unreadable read without
//         // reading again, recording a failure that names the pid and "errno <code>". Returns true only for gone.
//         @discardableResult
//         static func requireGone(pid: pid_t, start: ProcessStart, read: (pid_t) -> TableRead, milliseconds: Int32 = TestChild.hangCeilingMilliseconds) -> Bool
//     }
//
// The sweep this story owes (every observation that can fail and every control whose verdict rests on a child's own
// timer, in the three process suites, this file and Tests/Support), as lines at head a76733a. Each member is fixed in the
// same change; the four controls and the three readers below are checked by the cases in this file and in RealProcessLauncherTests.swift, the rest by reading.
//
//   Observations read as an end or as no survivors:
//     Support/ChildSurvivors.swift:20-36   liveChildren: the failure branch (L25) is unreachable, libproc returns 0 on failure,
//                                          so a failed census is an empty list. Becomes ChildSurvivors.census(parent:).
//     Support/ChildSurvivors.swift:62-88   Accounting: census is () -> [Child], so a failed baseline (L74) or exit (L85) reads
//                                          as empty. Takes the typed census.
//     Support/ChildSurvivors.swift:91      shared: built from liveChildren().
//     ChildEndingTests.swift:616-623       censusSeesAHeldChild: its `!contains` (L622) passes on a failed census.
//     RealProcessLauncherTests.swift:449   the descendant's record is required, so nil fails; reads the typed table read.
//     RealProcessLauncherTests.swift:458-465  the descendants poll: nil (unreadable or absent) made stillThere false.
//     Sources/.../LaunchedChildSignaller.swift:122-131  systemProcessTable: returns nil for absent and unreadable alike. The
//                                          product reader is not changed here; a test-support readProcessTable(_:) sits beside it.
//     Support/ChildSurvivors.swift:38-43   startText: nil for a failed read and for a zombie; a name only, not a verdict (recorded, low).
//     Support/TestChild.swift:178-181, 187-193, 199-203, Support/ChildCleanup.swift:40-42  read systemProcessTable: a nil read
//                                          gives no record, a kill(pid, 0) fallback, or no send. They fail closed; checked, not members.
//   Controls that rest on a child's own timer:
//     ChildEndingTests.swift:535-568       unboundIdentityIsNeverSignalled (three cases): /bin/sleep 2 (L540-541), verdict L567.
//     ChildEndingTests.swift:817-837       refusedSendIsNotConfirmed: /bin/sleep 2 (L823), verdict L836.
//     ChildEndingTests.swift:469-480       realHeldChildThatStaysIsNotConfirmed: HeldSleeper's sleep 30 (L216), verdict L479.
//     RealProcessLauncherTests.swift:411-466  signalReachesTheChildsDescendants: the descendant is `sleep 30 &` (L415), so a
//                                          leader-only send would still end it inside the poll's window.
//     BoundedProcessRunnerTests.swift:75-97 and 340-360  timeoutEndsTheProcess (both): perl sleep 30 then a marker; the
//                                          marker's absence holds for 30 s whether or not the runner ended the child. It needs
//                                          the child's end confirmed as well. Not made executable here: the runner boundary
//                                          gives the test no handle on the child to read its end from.
//   Checked and left (not members): BoundedProcessRunnerTests.swift:230-239 lstart (nil fails closed through ChildCleanup.endRecorded
//     L98); :163-215 and :245-300 (end the child through a recorded identity; not timer-bound); ChildEndingTests.swift:494-503
//     (the helper is ended by TERM and KILL); :681-694 endAsParent; RealProcessLauncherTests.swift:143-190, 720-789.
//   Recorded as leads, not this story: EngineSupervisorTests.swift:204, 222, 240, 277 (30 ms negative windows),
//     RealProcessLauncherTests.swift:215 and :235 (the 3 s ready window), RealProcessLauncherTests.swift:576-594
//     launcherStopsReachARunningChild (no ceiling of its own).
//
// plus a suite trait, `.noSurvivingChildren`, built on Accounting, that every
// suite in the three process test files carries.

private final class CallLog: @unchecked Sendable {
    private let lock = NSLock()
    private var sentValues: [(pid: Int32, signal: Int32)] = []
    private var eventValues: [String] = []
    private var goneFlag = false

    func send(_ pid: Int32, _ signal: Int32) {
        lock.withLock {
            sentValues.append((pid, signal))
            eventValues.append("send")
        }
    }

    /// sendThenGo is a send after which the child is gone.
    func sendThenGo(_ pid: Int32, _ signal: Int32) {
        send(pid, signal)
        lock.withLock { goneFlag = true }
    }

    func event(_ name: String) { lock.withLock { eventValues.append(name) } }
    var sends: [(pid: Int32, signal: Int32)] { lock.withLock { sentValues } }
    var events: [String] { lock.withLock { eventValues } }
    var isGone: Bool { lock.withLock { goneFlag } }
}

/// HeldSleeper is a real /bin/sleep child, started through ChildSpawner so it
/// is held from birth, which this test ends through that handle.
private final class HeldSleeper: @unchecked Sendable {
    let held: HeldChild

    init() throws {
        held = try HeldChild.start(executable: "/bin/sleep", arguments: ["30"])
    }

    var pid: Int32 { held.processIdentifier }

    var isRunning: Bool { !held.hasExited }

    func terminate() { held.send(SIGTERM) }

    /// waitForEnd waits for the confirmed reap, at most the given bound.
    func waitForEnd(milliseconds: Int32) -> Bool { held.waitReaped(milliseconds: milliseconds) }

    /// endNow ends the child through its held signaller and says whether its
    /// reap was confirmed.
    func endNow() -> Bool { held.end(signals: [SIGKILL]) == .ended }
}

private func namesPidAndStart(pid: Int32, start: String) -> @Sendable (Issue) -> Bool {
    { issue in
        issue.comments.contains { comment in
            let text = String(describing: comment)
            return text.contains("\(pid)") && text.contains(start)
        }
    }
}

@Suite("ChildCleanup ends a recorded child only on a matching identity and keeps the record when it cannot confirm")
struct ChildCleanupTests {
    private static let start = "Mon Jan  1 00:00:00 2001"
    private static let fakePid: Int32 = 70_001
    /// Short bounds below are for children that cannot end by themselves
    /// (a stand-in that never goes, or a sleep that outlasts the bound), so no
    /// host speed can make the bound outlast the thing it waits for.
    private static let shortBound: Int32 = 100

    private func makeRecord(pid: Int32, start: String) throws -> (directory: URL, pidFile: URL, text: String) {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("child-cleanup-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let pidFile = directory.appendingPathComponent("pid")
        let text = "\(pid)\n\(start)\n"
        try text.write(to: pidFile, atomically: true, encoding: .utf8)
        return (directory, pidFile, text)
    }

    @Test("a recorded child that no live process has is reported ended and nothing is sent")
    func goneChildIsEndedWithoutASend() {
        let log = CallLog()
        let outcome = ChildCleanup.endRecorded(
            pid: Self.fakePid, start: Self.start,
            readStart: { _ in nil }, exists: { _ in false },
            send: { log.send($0, $1) }, waitingMilliseconds: Self.shortBound
        )
        #expect(outcome == .ended)
        #expect(log.sends.isEmpty)
    }

    @Test("a number that now shows another start time is not the recorded child: reported ended, nothing is sent")
    func reusedNumberIsNeverSignalled() {
        let log = CallLog()
        let outcome = ChildCleanup.endRecorded(
            pid: Self.fakePid, start: Self.start,
            readStart: { _ in "Tue Feb  2 02:02:02 2002" }, exists: { _ in true },
            send: { log.send($0, $1) }, waitingMilliseconds: Self.shortBound
        )
        #expect(outcome == .ended)
        #expect(log.sends.isEmpty, "a signal went to a number that shows another start time")
    }

    @Test("a start time that cannot be read while the number exists is not confirmed, names the child and sends nothing")
    func unreadableIdentityIsNotConfirmedAndNothingIsSent() {
        let log = CallLog()
        let outcome = ChildCleanup.endRecorded(
            pid: Self.fakePid, start: Self.start,
            readStart: { _ in nil }, exists: { _ in true },
            send: { log.send($0, $1) }, waitingMilliseconds: Self.shortBound
        )
        #expect(outcome == .notConfirmed(pid: Self.fakePid, start: Self.start))
        #expect(log.sends.isEmpty, "a signal was sent on an identity that could not be read")
    }

    @Test("a matching identity is signalled once the child is confirmed, and the child going away is reported ended")
    func matchingIdentityIsSignalledAndEnded() {
        let log = CallLog()
        let outcome = ChildCleanup.endRecorded(
            pid: Self.fakePid, start: Self.start,
            readStart: { _ in log.isGone ? nil : Self.start },
            exists: { _ in !log.isGone },
            send: { log.sendThenGo($0, $1) }, waitingMilliseconds: Self.shortBound
        )
        #expect(outcome == .ended)
        #expect(!log.sends.isEmpty)
        #expect(log.sends.allSatisfy { $0.pid == Self.fakePid && $0.signal > 0 })
    }

    @Test("a signalled child whose end is not seen is not confirmed ended")
    func signalledChildThatStaysIsNotConfirmed() {
        let log = CallLog()
        let outcome = ChildCleanup.endRecorded(
            pid: Self.fakePid, start: Self.start,
            readStart: { _ in Self.start }, exists: { _ in true },
            send: { log.send($0, $1) }, waitingMilliseconds: Self.shortBound
        )
        #expect(outcome == .notConfirmed(pid: Self.fakePid, start: Self.start))
        #expect(!log.sends.isEmpty)
    }

    @Test("a record whose identity cannot be read stays on disk, is not deleted, and the failure names the child and its recorded start")
    func recordSurvivesAnUnconfirmedEnd() throws {
        let record = try makeRecord(pid: Self.fakePid, start: Self.start)
        defer { try? FileManager.default.removeItem(at: record.directory) }
        let log = CallLog()
        var outcome: ChildCleanup.Outcome?
        withKnownIssue(
            "the identity read fails, so the end cannot be confirmed",
            { outcome = ChildCleanup.endRecordedChild(
                pidFile: record.pidFile, removingOnEnd: record.directory,
                readStart: { _ in nil }, exists: { _ in true },
                send: { log.send($0, $1) }, waitingMilliseconds: Self.shortBound
            ) },
            matching: namesPidAndStart(pid: Self.fakePid, start: Self.start)
        )
        #expect(outcome == .notConfirmed(pid: Self.fakePid, start: Self.start))
        #expect(log.sends.isEmpty, "a signal was sent on an identity that could not be read")
        #expect(FileManager.default.fileExists(atPath: record.pidFile.path), "the record was deleted although the end was not confirmed")
        #expect((try? String(contentsOf: record.pidFile, encoding: .utf8)) == record.text, "the record was changed")
    }

    @Test("a record whose child was signalled but not seen to end stays on disk and the failure names the child")
    func recordSurvivesASignalThatDoesNotEnd() throws {
        let record = try makeRecord(pid: Self.fakePid, start: Self.start)
        defer { try? FileManager.default.removeItem(at: record.directory) }
        let log = CallLog()
        var outcome: ChildCleanup.Outcome?
        withKnownIssue(
            "the child never goes",
            { outcome = ChildCleanup.endRecordedChild(
                pidFile: record.pidFile, removingOnEnd: record.directory,
                readStart: { _ in Self.start }, exists: { _ in true },
                send: { log.send($0, $1) }, waitingMilliseconds: Self.shortBound
            ) },
            matching: namesPidAndStart(pid: Self.fakePid, start: Self.start)
        )
        #expect(outcome == .notConfirmed(pid: Self.fakePid, start: Self.start))
        #expect(!log.sends.isEmpty)
        #expect(FileManager.default.fileExists(atPath: record.pidFile.path), "the record was deleted although the end was not confirmed")
    }

    @Test("a child confirmed ended has its record deleted, and no failure is recorded")
    func recordIsDeletedOnlyWhenEnded() throws {
        let record = try makeRecord(pid: Self.fakePid, start: Self.start)
        defer { try? FileManager.default.removeItem(at: record.directory) }
        let log = CallLog()
        let outcome = ChildCleanup.endRecordedChild(
            pidFile: record.pidFile, removingOnEnd: record.directory,
            readStart: { _ in log.isGone ? nil : Self.start }, exists: { _ in !log.isGone },
            send: { log.sendThenGo($0, $1) }, waitingMilliseconds: Self.shortBound
        )
        #expect(outcome == .ended)
        #expect(!FileManager.default.fileExists(atPath: record.directory.path), "an ended child's record was left behind")
    }

    @Test("a record for a child no live process has is ended without a send and deleted")
    func recordForAGoneChildIsDeleted() throws {
        let record = try makeRecord(pid: Self.fakePid, start: Self.start)
        defer { try? FileManager.default.removeItem(at: record.directory) }
        let log = CallLog()
        let outcome = ChildCleanup.endRecordedChild(
            pidFile: record.pidFile, removingOnEnd: record.directory,
            readStart: { _ in nil }, exists: { _ in false },
            send: { log.send($0, $1) }, waitingMilliseconds: Self.shortBound
        )
        #expect(outcome == .ended)
        #expect(log.sends.isEmpty)
        #expect(!FileManager.default.fileExists(atPath: record.directory.path))
    }
}

@Suite("ChildCleanup ends a child the caller holds and says plainly when it could not confirm the end", .noSurvivingChildren)
struct HeldChildCleanupTests {
    private static let start = "Mon Jan  1 00:00:00 2001"
    private static let fakePid: Int32 = 70_002
    private static let shortBound: Int32 = 100

    @Test("a child whose exit was already reported is ended: nothing is sent and nothing is waited on")
    func alreadyEndedNeedsNothing() {
        let log = CallLog()
        let outcome = ChildCleanup.endHeld(
            pid: Self.fakePid, start: Self.start, alreadyEnded: true,
            send: { log.event("send") }, waitForEnd: { _ in log.event("wait"); return true },
            waitingMilliseconds: Self.shortBound
        )
        #expect(outcome == .ended)
        #expect(log.events.isEmpty)
    }

    @Test("a held child is sent the end, then its exit is waited on, and an observed exit is ended")
    func heldChildIsSentThenWaited() {
        let log = CallLog()
        let outcome = ChildCleanup.endHeld(
            pid: Self.fakePid, start: Self.start, alreadyEnded: false,
            send: { log.event("send") }, waitForEnd: { _ in log.event("wait"); return true },
            waitingMilliseconds: Self.shortBound
        )
        #expect(outcome == .ended)
        #expect(log.events == ["send", "wait"])
    }

    @Test("a final wait that does not see the exit is not confirmed and carries the child's pid and recorded start")
    func unobservedExitIsNotConfirmed() {
        let outcome = ChildCleanup.endHeld(
            pid: Self.fakePid, start: Self.start, alreadyEnded: false,
            send: {}, waitForEnd: { _ in false }, waitingMilliseconds: Self.shortBound
        )
        #expect(outcome == .notConfirmed(pid: Self.fakePid, start: Self.start))
    }

    @Test("the recording form fails the test naming the child and its start when the exit is not seen")
    func recordingFormFailsNamingTheChild() {
        withKnownIssue(
            "the exit is never seen",
            {
                ChildCleanup.endHeldRecordingNotConfirmed(
                    pid: Self.fakePid, start: Self.start, alreadyEnded: false,
                    send: {}, waitForEnd: { _ in false }, waitingMilliseconds: Self.shortBound
                )
            },
            matching: namesPidAndStart(pid: Self.fakePid, start: Self.start)
        )
    }

    @Test("the recording form records nothing when the exit is seen")
    func recordingFormIsQuietWhenEnded() {
        let outcome = ChildCleanup.endHeldRecordingNotConfirmed(
            pid: Self.fakePid, start: Self.start, alreadyEnded: false,
            send: {}, waitForEnd: { _ in true }, waitingMilliseconds: Self.shortBound
        )
        #expect(outcome == .ended)
    }

    @Test("a real held child is ended through its handle, its exit is seen and its number is gone")
    func realHeldChildIsEnded() throws {
        let sleeper = try HeldSleeper()
        defer { #expect(sleeper.endNow(), "test child \(sleeper.pid) may still be running, it was not confirmed ended") }
        let outcome = ChildCleanup.endHeld(
            pid: sleeper.pid, start: nil, alreadyEnded: false,
            send: { sleeper.terminate() },
            waitForEnd: { sleeper.waitForEnd(milliseconds: $0) },
            waitingMilliseconds: TestChild.hangCeilingMilliseconds
        )
        #expect(outcome == .ended)
        #expect(StoppedChildSupport.isGone(pid: sleeper.pid), "child \(sleeper.pid) was reported ended but its number is still held")
    }

    @Test("a real held child that is sent nothing is not confirmed ended and is still alive afterwards")
    func realHeldChildThatStaysIsNotConfirmed() throws {
        // A child blocked on input this test holds: it has no end of its own, so it
        // is still there however late the caller reads it. The test ends it by releasing the input.
        let input = HeldInput()
        let held = try HeldChild.startBlocked(on: input)
        defer { held.endByReleasing(input) }
        let outcome = ChildCleanup.endHeld(
            pid: held.processIdentifier, start: Self.start, alreadyEnded: false,
            send: {}, waitForEnd: { held.waitReaped(milliseconds: $0) },
            waitingMilliseconds: Self.shortBound
        )
        #expect(outcome == .notConfirmed(pid: held.processIdentifier, start: Self.start))
        #expect(!held.hasExited, "a child that was sent nothing ended")
    }
}

@Suite("ObservedHelper holds the helper it starts from birth and says when it could not confirm its end", .noSurvivingChildren)
struct ObservedHelperTests {
    @Test("a helper that finishes in time gives its output and is collected")
    func finishedHelperGivesOutput() throws {
        let observation = ObservedHelper.read(executable: "/bin/echo", arguments: ["hello"], waitingMilliseconds: TestChild.hangCeilingMilliseconds)
        #expect(observation.output == "hello")
        #expect(observation.helperEnded)
        let pid = try #require(observation.helperPid)
        #expect(StoppedChildSupport.isGone(pid: pid), "helper \(pid) was not collected")
    }

    @Test("a helper that outlasts the wait gives no output and is ended and collected before the call returns")
    func expiredWaitEndsAndCollectsTheHelper() throws {
        // A sleep that outlasts the bound by a wide margin, so the wait always
        // expires. It ends by itself after 30 seconds if a fix is missing.
        let observation = ObservedHelper.read(executable: "/bin/sleep", arguments: ["30"], waitingMilliseconds: 150)
        let pid = try #require(observation.helperPid, "no helper was started")
        #expect(observation.output == nil)
        #expect(observation.helperEnded, "helper \(pid) was left without a confirmed end")
        #expect(StoppedChildSupport.isGone(pid: pid), "helper \(pid) was left running or uncollected when the wait expired")
    }

    @Test("a helper that exits with a failure status gives no output and is collected")
    func failedHelperGivesNothing() throws {
        let observation = ObservedHelper.read(executable: "/bin/sh", arguments: ["-c", "echo partial; exit 3"], waitingMilliseconds: TestChild.hangCeilingMilliseconds)
        #expect(observation.output == nil)
        let pid = try #require(observation.helperPid)
        #expect(observation.helperEnded)
        #expect(StoppedChildSupport.isGone(pid: pid), "helper \(pid) was not collected")
    }

    /// IdentityGate scripts what the process table shows for a helper after its
    /// birth read, and counts the reads.
    private final class IdentityGate: @unchecked Sendable {
        private let lock = NSLock()
        private var reads = 0
        func read(_ pid: pid_t, real: ProcessRecord?) -> ProcessRecord? {
            lock.withLock {
                reads += 1
                guard reads > 1, let real else { return real }
                return ProcessRecord(pid: real.pid, parentPID: real.parentPID, start: ProcessStart(seconds: real.start.seconds, microseconds: real.start.microseconds + 1))
            }
        }
    }

    enum UnboundIdentity: String, Sendable, CaseIterable, CustomTestStringConvertible {
        case nothingAtBirth, replacementAtBirth, changedAfterBirth
        var testDescription: String { rawValue }
    }

    @Test("a helper whose identity does not hold is sent nothing and is not confirmed ended, and it is ended by the test releasing its input", arguments: UnboundIdentity.allCases)
    func unboundIdentityIsNeverSignalled(_ identity: UnboundIdentity) {
        let gate = IdentityGate()
        // The helper reads an input this test holds, so it has no end of its own: it
        // stays alive however late the caller reads it, and ends only when the test
        // releases the input. Its signaller refuses every send here, so release is the way out.
        let input = HeldInput()
        let observation = ObservedHelper.read(
            executable: "/bin/cat", arguments: [], waitingMilliseconds: 100, standardInput: input.childEnd,
            readProcessTable: { pid in
                let real = LaunchedChildSignaller.systemProcessTable(pid)
                switch identity {
                case .nothingAtBirth: return nil
                case .replacementAtBirth: return ProcessRecord(pid: pid, parentPID: getpid() + 1, start: ProcessStart(seconds: 1, microseconds: 0))
                case .changedAfterBirth: return gate.read(pid, real: real)
                }
            }
        )
        input.closeChildEnd()
        let helper = observation.helper
        // Ended by releasing the input on every path from here.
        defer {
            if let helper { helper.endByReleasing(input) } else { input.release() }
        }
        // The caller is held past the lifetime the old two-second child had, then reads.
        CallerHold.pastTheOldTwoSecondChild()
        #expect(helper != nil && observation.helperPid == helper?.processIdentifier)
        #expect(observation.output == nil)
        #expect(!observation.helperEnded, "a helper whose end was not seen was reported ended")
        #expect(helper?.hasExited == false, "a helper whose identity did not hold was ended anyway")
    }

    @Test("a helper that cannot be started gives no output and has no process to end")
    func unstartableHelperGivesNothing() {
        let observation = ObservedHelper.read(executable: "/no/such/helper-cgmrelay-test", arguments: [], waitingMilliseconds: TestChild.hangCeilingMilliseconds)
        #expect(observation.output == nil)
        #expect(observation.helperPid == nil)
    }
}

@Suite("ChildSurvivors names every child the suites started and left alive", .noSurvivingChildren)
struct ChildSurvivorsTests {
    /// The census the accounting reads, set by the test. Its pids are far above any
    /// live process's; the start each shows is given to the accounting by the test.
    private final class CensusBox: @unchecked Sendable {
        private let lock = NSLock()
        private var stored: [Int32] = []
        var current: [Int32] {
            get { lock.withLock { stored } }
            set { lock.withLock { stored = newValue } }
        }
        var census: Census { .listed(current) }
    }

    private static func child(_ pid: Int32) -> ChildSurvivors.Child { ChildSurvivors.Child(pid: pid, start: "start-\(pid)") }
    private static func fakePid(_ n: Int32) -> Int32 { 90_000 + n }

    @Test("children new since the baseline are survivors, ones that were there before are not")
    func newChildrenAreSurvivors() {
        let before = [Self.child(1), Self.child(2)]
        let now = [Self.child(1), Self.child(2), Self.child(3)]
        #expect(ChildSurvivors.new(since: before, now: now) == [Self.child(3)])
        #expect(ChildSurvivors.new(since: now, now: before).isEmpty)
        // The same number with another start time is another process.
        #expect(ChildSurvivors.new(since: [Self.child(1)], now: [ChildSurvivors.Child(pid: 1, start: "other")]).count == 1)
    }

    @Test("each survivor is recorded as a failure naming its pid and start")
    func survivorsAreRecordedNamingThem() {
        let survivor = Self.child(4242)
        withKnownIssue(
            "a child is left alive",
            { ChildSurvivors.recordSurvivors([survivor]) },
            matching: namesPidAndStart(pid: 4242, start: "start-4242")
        )
    }

    @Test("no survivors records nothing")
    func noSurvivorsRecordsNothing() {
        ChildSurvivors.recordSurvivors([])
    }

    @Test("the census reads this process's live children from the kernel: a held child is listed while it lives and not after its end is seen")
    func censusSeesAHeldChild() throws {
        let sleeper = try HeldSleeper()
        defer { #expect(sleeper.endNow(), "test child \(sleeper.pid) may still be running, it was not confirmed ended") }
        func listed(_ when: String) -> [pid_t] {
            switch ChildSurvivors.census(parent: getpid()) {
            case .listed(let pids): return pids
            case .failed(let code):
                Issue.record("the census could not be read (errno \(code)) \(when), so child \(sleeper.pid) could not be counted")
                return []
            }
        }
        let whileLive = listed("while the child lives")
        #expect(whileLive.contains(sleeper.pid), "held child \(sleeper.pid) is not in the census")
        #expect(sleeper.endNow())
        // An empty answer from a failed read must not stand for "not in the census".
        let afterEnd = ChildSurvivors.census(parent: getpid())
        guard case .listed(let pids) = afterEnd else {
            Issue.record("the census could not be read after the end (\(afterEnd)), so the ended child \(sleeper.pid) could not be counted gone")
            return
        }
        #expect(!pids.contains(sleeper.pid), "ended child \(sleeper.pid) is still in the census")
    }

    @Test("the check runs when the last scope exits, against the baseline the first scope took")
    func accountingChecksWhenTheLastScopeExits() {
        let box = CensusBox()
        let (a, b, c) = (Self.fakePid(1), Self.fakePid(2), Self.fakePid(3))
        box.current = [a]
        let accounting = ChildSurvivors.Accounting(census: { box.census }, startOf: { "start-\($0)" })
        accounting.enter()
        box.current = [a, b]
        accounting.enter()
        box.current = [a, b, c]
        #expect(accounting.exit().isEmpty, "the check ran while another suite was still running")
        #expect(accounting.exit().map(\.pid) == [b, c])
    }

    @Test("children that ended before the last scope exits are not survivors, and a later round starts from a new baseline")
    func accountingSeesOnlyWhatIsStillThere() {
        let box = CensusBox()
        let accounting = ChildSurvivors.Accounting(census: { box.census }, startOf: { "start-\($0)" })
        accounting.enter()
        box.current = [Self.fakePid(5)]
        box.current = []
        #expect(accounting.exit().isEmpty)

        box.current = [Self.fakePid(6)]
        accounting.enter()
        box.current = [Self.fakePid(6), Self.fakePid(7)]
        #expect(accounting.exit().map(\.pid) == [Self.fakePid(7)])
    }

    /// StartBox is the start each pid shows to the accounting, changed by the test
    /// between the baseline and the end. A pid with no entry shows no start: its read failed.
    private final class StartBox: @unchecked Sendable {
        private let lock = NSLock()
        private var starts: [Int32: String] = [:]
        func set(_ pid: Int32, _ start: String?) { lock.withLock { starts[pid] = start } }
        func read(_ pid: Int32) -> String? { lock.withLock { starts[pid] } }
    }

    struct StartCase: Sendable, CustomTestStringConvertible {
        let atBaseline: String?
        let atEnd: String?
        let reported: Bool
        var testDescription: String { "baseline \(atBaseline ?? "unreadable"), end \(atEnd ?? "unreadable"): \(reported ? "reported" : "not a survivor")" }
    }

    @Test(
        "a child whose start could not be read at either end is never taken for the same process as the one with that pid in the other census; a readable equal start is not a survivor, another start is",
        arguments: [
            StartCase(atBaseline: nil, atEnd: nil, reported: true),
            StartCase(atBaseline: nil, atEnd: "t-1", reported: true),
            StartCase(atBaseline: "t-1", atEnd: nil, reported: true),
            StartCase(atBaseline: "t-1", atEnd: "t-1", reported: false),
            StartCase(atBaseline: "t-1", atEnd: "t-2", reported: true),
        ]
    )
    func unreadableStartIsNeverTheSameProcess(_ testCase: StartCase) {
        let pid = Self.fakePid(11)
        let box = CensusBox()
        let starts = StartBox()
        box.current = [pid]
        starts.set(pid, testCase.atBaseline)
        let accounting = ChildSurvivors.Accounting(census: { box.census }, startOf: { starts.read($0) })
        accounting.enter()
        starts.set(pid, testCase.atEnd)
        let survivors = accounting.exit()
        if testCase.reported {
            #expect(survivors == [ChildSurvivors.Child(pid: pid, start: testCase.atEnd)], "survivors \(survivors)")
        } else {
            #expect(survivors.isEmpty, "survivors \(survivors)")
        }
    }

    @Test("a child with no readable start that is reported is named with its pid and that its start is not recorded")
    func unreadableSurvivorIsNamed() {
        let pid = Self.fakePid(12)
        let box = CensusBox()
        box.current = [pid]
        let accounting = ChildSurvivors.Accounting(census: { box.census }, startOf: { _ in nil })
        accounting.enter()
        let survivors = accounting.exit()
        withKnownIssue(
            "a child whose start was never readable is still a survivor",
            { ChildSurvivors.recordSurvivors(survivors) },
            matching: issueNames("\(pid)", "start not recorded")
        )
    }

    @Test("a child that appears only at the end is a survivor whether or not its start can be read")
    func newChildIsASurvivorWithOrWithoutAStart() {
        let (withStart, withoutStart) = (Self.fakePid(13), Self.fakePid(14))
        let box = CensusBox()
        let accounting = ChildSurvivors.Accounting(census: { box.census }, startOf: { $0 == withStart ? "t-1" : nil })
        accounting.enter()
        box.current = [withStart, withoutStart]
        #expect(accounting.exit().map(\.pid).sorted() == [withStart, withoutStart])
    }
}

// MARK: - An end that the holder could not observe is never an end

@Suite("A child whose exit the holder could not observe is not counted as ended", .noSurvivingChildren)
struct UnobservedExitCleanupTests {
    /// The wait fails outright: the holder cannot observe the exit, reaps
    /// nothing and reports ProcessExitCode.statusUnknown. The child is a real
    /// /bin/cat that this test ends itself, as its parent, by closing its input.
    private static let failingWait: ChildSpawner.WaitForExit = { _ in (-1, siginfo_t()) }

    private struct Started {
        let held: HeldChild
        let input: Pipe
    }

    private static func start() throws -> Started {
        let input = Pipe()
        let held = try HeldChild.start(
            executable: "/bin/cat",
            standardInput: input.fileHandleForReading.fileDescriptor,
            waitForExit: failingWait
        )
        try? input.fileHandleForReading.close()
        return Started(held: held, input: input)
    }

    /// endAsParent closes the child's input and collects it with a bounded
    /// waitpid: the holder reaped nothing, so this test, its parent, still holds it.
    private static func endAsParent(_ started: Started) {
        try? started.input.fileHandleForWriting.close()
        let pid = started.held.processIdentifier
        let deadline = DispatchTime.now() + .milliseconds(Int(TestChild.hangCeilingMilliseconds))
        var collected = false
        while DispatchTime.now() < deadline {
            var status: Int32 = 0
            let result = waitpid(pid, &status, WNOHANG)
            if result == pid { collected = true; break }
            if result < 0 && errno != EINTR { break }
            usleep(20_000)
        }
        #expect(collected, "test child \(ChildCleanup.describe(pid: pid, start: started.held.birthStart)) may still be running, it was not confirmed ended")
    }

    @Test("an unknown report is a report but not a reap: nothing is confirmed, no send is accepted, and the failure names the pid and the birth start")
    func unknownReportIsNotAnEnd() throws {
        let started = try Self.start()
        defer { Self.endAsParent(started) }
        let held = started.held
        let start = try #require(held.birthStart, "no birth start was recorded")

        #expect(!held.waitReaped(milliseconds: TestChild.hangCeilingMilliseconds), "an unobserved exit was confirmed")
        #expect(held.watch.reportedStatusUnknown)
        // What the earlier decisions read: a report arrived. It is not a reap.
        #expect(!held.watch.reported.isEmpty)
        #expect(!held.hasReportedExit)
        #expect(!held.hasExited)
        #expect(!held.send(SIGKILL), "a send was accepted after the holder gave up")

        withKnownIssue(
            "the end of the child cannot be confirmed",
            {
                ChildCleanup.endHeldRecordingNotConfirmed(
                    pid: held.processIdentifier, start: held.birthStart, alreadyEnded: held.hasReportedExit,
                    send: { held.send(SIGKILL) },
                    waitForEnd: { held.waitReaped(milliseconds: $0) },
                    waitingMilliseconds: TestChild.hangCeilingMilliseconds
                )
            },
            matching: namesPidAndStart(pid: held.processIdentifier, start: start)
        )
    }

    @Test("a process known through RunningProcess is confirmed reaped only by the holder's own word, and an unknown report is not that")
    func launchedProcessIsConfirmedOnlyByTheReap() throws {
        let started = try Self.start()
        defer { Self.endAsParent(started) }
        let process = RealProcess(child: started.held.child, stdinHandle: FileHandle.nullDevice)
        #expect(!ConfirmedEnd.isReaped(process))
        #expect(!ConfirmedEnd.wait(process, milliseconds: 100))

        let ended = try HeldChild.start(executable: "/usr/bin/true")
        #expect(ended.waitReaped())
        #expect(ConfirmedEnd.isReaped(RealProcess(child: ended.child, stdinHandle: FileHandle.nullDevice)))
    }

    @Test("an observing helper that is not confirmed ended fails the test naming its pid and birth start, and one that is stays quiet")
    func unresolvedHelperIsNamed() {
        withKnownIssue(
            "the helper's end was not seen",
            { ObservedHelper.Observation(output: nil, helperPid: 4243, birthStart: "born-4243", helperEnded: false, helper: nil).failIfNotEnded() },
            matching: namesPidAndStart(pid: 4243, start: "born-4243")
        )
        ObservedHelper.Observation(output: "x", helperPid: 4243, birthStart: "born-4243", helperEnded: true, helper: nil).failIfNotEnded()
    }
}

@Suite("A record directory is kept unless the end of its child is confirmed or the launch is said to have failed")
struct RecordDirectoryTests {
    private func makeDirectory() throws -> URL {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("record-directory-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        return directory
    }

    @Test("a directory with no pid file is not proof that nothing was started: it is not confirmed, the failure says so and the directory stays")
    func absentRecordIsNotConfirmed() throws {
        let directory = try makeDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let log = CallLog()
        var outcome: ChildCleanup.Outcome?
        withKnownIssue(
            "no record exists and the launch was not reported failed",
            { outcome = ChildCleanup.endRecordedChild(
                pidFile: directory.appendingPathComponent("pid"), removingOnEnd: directory,
                readStart: { _ in nil }, exists: { _ in false },
                send: { log.send($0, $1) }, waitingMilliseconds: 100
            ) }
        )
        #expect(outcome == .notConfirmed(pid: 0, start: nil))
        #expect(FileManager.default.fileExists(atPath: directory.path), "the directory was deleted without proof that no child was started")
        #expect(log.sends.isEmpty)
    }

    @Test("a directory with no pid file is removed when the caller says the launch itself failed")
    func absentRecordAfterAFailedLaunchIsEnded() throws {
        let directory = try makeDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let outcome = ChildCleanup.endRecordedChild(
            pidFile: directory.appendingPathComponent("pid"), removingOnEnd: directory, launchFailed: true,
            readStart: { _ in nil }, exists: { _ in false },
            send: { _, _ in }, waitingMilliseconds: 100
        )
        #expect(outcome == .ended)
        #expect(!FileManager.default.fileExists(atPath: directory.path))
    }

    @Test("a record kept by identity alone is removed only on a confirmed end, and an unconfirmed one fails naming the child and keeps it")
    func identityRecordIsRemovedOnlyOnEnd() throws {
        let kept = try makeDirectory()
        let removed = try makeDirectory()
        defer {
            try? FileManager.default.removeItem(at: kept)
            try? FileManager.default.removeItem(at: removed)
        }
        withKnownIssue(
            "the identity cannot be read",
            { ChildCleanup.endRecordedRemovingOnEnd(
                pid: 70_003, start: "born", removingOnEnd: kept,
                readStart: { _ in nil }, exists: { _ in true },
                send: { _, _ in }, waitingMilliseconds: 100
            ) },
            matching: namesPidAndStart(pid: 70_003, start: "born")
        )
        #expect(FileManager.default.fileExists(atPath: kept.path), "the record was deleted although the end was not confirmed")
        let outcome = ChildCleanup.endRecordedRemovingOnEnd(
            pid: 70_003, start: "born", removingOnEnd: removed,
            readStart: { _ in nil }, exists: { _ in false },
            send: { _, _ in }, waitingMilliseconds: 100
        )
        #expect(outcome == .ended)
        #expect(!FileManager.default.fileExists(atPath: removed.path))
    }
}

@Suite("A held child is ended only through its held signaller", .noSurvivingChildren)
struct HeldChildSendGuardTests {
    @Test("a held child whose identity does not hold is sent nothing by end, and says so with its pid and birth start")
    func refusedSendIsNotConfirmed() throws {
        // A replacement shown at birth: the signaller accepts no identity and refuses every send.
        // The child reads an input this test holds, so it has no end of its own; the test ends it by releasing the input.
        let input = HeldInput()
        let held = try HeldChild.startBlocked(
            on: input,
            readProcessTable: { pid in ProcessRecord(pid: pid, parentPID: getpid() + 1, start: ProcessStart(seconds: 1, microseconds: 0)) }
        )
        defer { held.endByReleasing(input) }
        let outcome = held.end(signals: [SIGTERM, SIGKILL], waitingMilliseconds: 100)
        // The caller is held past the lifetime the old two-second child had, then reads.
        CallerHold.pastTheOldTwoSecondChild()
        #expect(outcome == .notConfirmed(pid: held.processIdentifier, start: held.birthStart))
        #expect(!held.hasExited, "a child whose identity did not hold was ended anyway")
    }
}

// MARK: - A read that could not be taken is never an end

/// issueNames matches a recorded failure whose comment contains every piece.
private func issueNames(_ pieces: String...) -> @Sendable (Issue) -> Bool {
    { issue in
        issue.comments.contains { comment in
            let text = String(describing: comment)
            return pieces.allSatisfy { text.contains($0) }
        }
    }
}

/// KernelList stands in for proc_listpids(PROC_PPID_ONLY, parent, ...) the way
/// libproc behaves: a call with no buffer is a size query that answers with
/// room to spare, a call with a buffer fills it with as many pids as fit, and a
/// failure returns 0 with errno set. A success leaves errno exactly as it was.
private final class KernelList: @unchecked Sendable {
    struct Call: Equatable { let type: UInt32; let typeinfo: UInt32; let hadBuffer: Bool }

    private let lock = NSLock()
    private var recorded: [Call] = []
    let pids: [pid_t]
    /// An errno to fail the size query with, or nil.
    var failSizeQuery: Int32?
    /// An errno to fail a read into a buffer with, or nil.
    var failRead: Int32?
    /// True when the size query answers with room for only four pids, so a
    /// reader that trusts it fills its buffer and must read again, larger.
    var sizeQueryRunsShort = false

    init(pids: [pid_t]) { self.pids = pids }

    var calls: [Call] { lock.withLock { recorded } }

    var listPids: ChildSurvivors.ListPids {
        { [self] type, typeinfo, buffer, byteCount in call(type, typeinfo, buffer, byteCount) }
    }

    private func call(_ type: UInt32, _ typeinfo: UInt32, _ buffer: UnsafeMutableRawPointer?, _ byteCount: Int32) -> Int32 {
        lock.withLock { recorded.append(Call(type: type, typeinfo: typeinfo, hadBuffer: buffer != nil)) }
        let width = Int32(MemoryLayout<pid_t>.size)
        guard let buffer else {
            if let code = failSizeQuery { errno = code; return 0 }
            return sizeQueryRunsShort ? 4 * width : Int32(pids.count + 20) * width
        }
        if let code = failRead { errno = code; return 0 }
        let fits = min(Int(byteCount / width), pids.count)
        let out = buffer.bindMemory(to: pid_t.self, capacity: max(fits, 1))
        for index in 0..<fits { out[index] = pids[index] }
        return Int32(fits) * width
    }
}

/// KernelRecord stands in for proc_pidinfo(pid, PROC_PIDTBSDINFO, 0, buffer, size).
private enum KernelRecord {
    static let size = Int32(MemoryLayout<proc_bsdinfo>.size)

    /// a record for pid that fills the buffer and answers with its full size.
    static func answering(pid: pid_t, parent: pid_t, seconds: UInt64, microseconds: UInt64) -> ProcPidInfo {
        { _, buffer, _ in
            var info = proc_bsdinfo()
            info.pbi_pid = UInt32(pid)
            info.pbi_ppid = UInt32(parent)
            info.pbi_start_tvsec = seconds
            info.pbi_start_tvusec = microseconds
            buffer.bindMemory(to: proc_bsdinfo.self, capacity: 1).pointee = info
            return size
        }
    }

    /// a failed read: 0 with errno set.
    static func failing(errno code: Int32) -> ProcPidInfo { { _, _, _ in errno = code; return 0 } }

    /// 0 with errno untouched.
    static let silentZero: ProcPidInfo = { _, _, _ in 0 }

    /// a positive count short of the record.
    static let shortRead: ProcPidInfo = { _, _, _ in size - 8 }
}

/// ScriptedTable gives a descendant's process-table reads one by one and counts
/// them. Past the end of the script it says the process is absent, so a
/// consumer that reads on after an unreadable answer sees the end it must not
/// have gone looking for.
private final class ScriptedTable: @unchecked Sendable {
    private let lock = NSLock()
    private let script: [TableRead]
    private var next = 0
    init(_ script: [TableRead]) { self.script = script }
    var reads: Int { lock.withLock { next } }
    func read(_ pid: pid_t) -> TableRead {
        lock.withLock {
            defer { next += 1 }
            return next < script.count ? script[next] : .absent
        }
    }
}

/// CensusScript answers one census per call, in order.
private final class CensusScript: @unchecked Sendable {
    private let lock = NSLock()
    private let script: [Census]
    private var position = 0
    init(_ script: [Census]) { self.script = script }
    func next() -> Census {
        lock.withLock {
            defer { position += 1 }
            return position < script.count ? script[position] : .listed([])
        }
    }
}

@Suite("A failed read is never counted as an end or as no survivors")
struct FailedReadsAreNotEndsTests {
    private static let parent: pid_t = 4_242
    private static let unreadableCode: Int32 = 4_243

    // MARK: The census

    @Test("a census whose read failed after the size query is failed with the errno, never listed empty")
    func censusFailedOnTheSizeQuery() {
        let kernel = KernelList(pids: [90_001])
        kernel.failSizeQuery = EPERM
        #expect(ChildSurvivors.census(parent: Self.parent, listPids: kernel.listPids) == .failed(EPERM))
    }

    @Test("a census whose read failed when the buffer was read is failed with the errno, never listed empty")
    func censusFailedOnTheRead() {
        let kernel = KernelList(pids: [90_001, 90_002])
        kernel.failRead = ENOMEM
        #expect(ChildSurvivors.census(parent: Self.parent, listPids: kernel.listPids) == .failed(ENOMEM))
    }

    @Test("a genuine empty list is listed empty, even with an old errno left in the thread")
    func genuineEmptyCensusIsListedEmpty() {
        let kernel = KernelList(pids: [])
        errno = EPERM
        #expect(ChildSurvivors.census(parent: Self.parent, listPids: kernel.listPids) == .listed([]))
        errno = 0
        #expect(ChildSurvivors.census(parent: Self.parent, listPids: kernel.listPids) == .listed([]))
    }

    @Test("a census lists the children it was given and asks the kernel for the children of the parent named")
    func censusListsTheChildrenOfTheParentNamed() {
        let kernel = KernelList(pids: [90_001, 90_002, 90_003])
        #expect(ChildSurvivors.census(parent: Self.parent, listPids: kernel.listPids) == .listed([90_001, 90_002, 90_003]))
        #expect(!kernel.calls.isEmpty)
        for call in kernel.calls {
            #expect(call.type == UInt32(PROC_PPID_ONLY))
            #expect(call.typeinfo == UInt32(Self.parent))
        }
    }

    @Test("a read that fills its buffer is read again larger, so a long list is listed whole")
    func censusFillingTheBufferIsReadAgainLarger() {
        let many = (1...100).map { pid_t(90_000 + $0) }
        let kernel = KernelList(pids: many)
        kernel.sizeQueryRunsShort = true
        #expect(ChildSurvivors.census(parent: Self.parent, listPids: kernel.listPids) == .listed(many))
    }

    @Test("an accounting whose baseline census failed fails the test naming the failed read")
    func failedBaselineIsNamed() {
        let accounting = ChildSurvivors.Accounting(census: { .failed(Self.unreadableCode) })
        withKnownIssue(
            "the baseline census could not be read",
            { accounting.enter() },
            matching: issueNames("errno \(Self.unreadableCode)", "could not be read")
        )
    }

    @Test("an accounting whose census at the last exit failed fails the test naming the failed read, and reports no survivors only from a census it could read")
    func failedExitCensusIsNamed() {
        // The baseline reads; the census at the last exit fails.
        let script = CensusScript([.listed([90_001]), .failed(Self.unreadableCode)])
        let accounting = ChildSurvivors.Accounting(census: { script.next() })
        accounting.enter()
        withKnownIssue(
            "the census at the last exit could not be read",
            { _ = accounting.exit() },
            matching: issueNames("errno \(Self.unreadableCode)", "could not be read")
        )
    }

    @Test("an accounting whose censuses are genuinely empty reports no survivors and records nothing")
    func genuineEmptyCensusesAreNoSurvivors() {
        let accounting = ChildSurvivors.Accounting(census: { .listed([]) })
        accounting.enter()
        #expect(accounting.exit().isEmpty)
    }

    // MARK: The process-table read

    @Test("a full record is present, whatever errno an earlier call left in the thread")
    func fullRecordIsPresent() {
        errno = ESRCH
        let read = readProcessTable(9_001, pidInfo: KernelRecord.answering(pid: 9_001, parent: 77, seconds: 1_700_000_000, microseconds: 5))
        #expect(read == .present(ProcessRecord(pid: 9_001, parentPID: 77, start: ProcessStart(seconds: 1_700_000_000, microseconds: 5))))
    }

    @Test("no such process is absent")
    func noSuchProcessIsAbsent() {
        #expect(readProcessTable(9_001, pidInfo: KernelRecord.failing(errno: ESRCH)) == .absent)
    }

    @Test("any other failure is unreadable with its errno, never absent", arguments: [EPERM, ENOMEM, EINVAL])
    func otherFailuresAreUnreadable(_ code: Int32) {
        #expect(readProcessTable(9_001, pidInfo: KernelRecord.failing(errno: code)) == .unreadable(code))
    }

    @Test("a short read is unreadable, never present and never absent")
    func shortReadIsUnreadable() {
        guard case .unreadable = readProcessTable(9_001, pidInfo: KernelRecord.shortRead) else {
            Issue.record("a short read was not reported unreadable")
            return
        }
    }

    @Test("a 0 with no errno of its own is unreadable even when an old ESRCH is left in the thread")
    func silentZeroIsNotAbsent() {
        errno = ESRCH
        guard case .unreadable = readProcessTable(9_001, pidInfo: KernelRecord.silentZero) else {
            Issue.record("a 0 that set no errno was read as absent from an old errno")
            return
        }
    }

    // MARK: The descendants check

    private static let descendantPID: pid_t = 98_765
    private static let descendantStart = ProcessStart(seconds: 1_700_000_000, microseconds: 5)
    private static func record(_ start: ProcessStart) -> ProcessRecord { ProcessRecord(pid: descendantPID, parentPID: 1, start: start) }

    @Test("the verdict on one read: the same start is still there, another start or no process is gone, an unreadable read is never gone")
    func verdictOnOneRead() {
        let same = Self.descendantStart
        let other = ProcessStart(seconds: same.seconds, microseconds: same.microseconds + 1)
        #expect(DescendantCheck.verdict(.present(Self.record(same)), of: same) == .stillThere)
        #expect(DescendantCheck.verdict(.present(Self.record(other)), of: same) == .gone)
        #expect(DescendantCheck.verdict(.absent, of: same) == .gone)
        #expect(DescendantCheck.verdict(.unreadable(EPERM), of: same) == .unreadable(EPERM))
        #expect(DescendantCheck.verdict(.unreadable(0), of: same) == .unreadable(0))
    }

    @Test("a descendant that is still there and then absent is counted gone, and nothing is recorded")
    func absentDescendantIsGone() {
        let table = ScriptedTable([.present(Self.record(Self.descendantStart)), .present(Self.record(Self.descendantStart)), .absent])
        let gone = DescendantCheck.requireGone(pid: Self.descendantPID, start: Self.descendantStart, read: table.read)
        #expect(gone)
        #expect(table.reads == 3)
    }

    @Test("a descendant whose record cannot be read is not counted gone: the check stops at that read, names the pid and the errno")
    func unreadableDescendantIsNotGone() {
        // After the unreadable read the script says absent. A check that reads on would count the descendant gone.
        let table = ScriptedTable([.present(Self.record(Self.descendantStart)), .unreadable(EPERM)])
        var gone: Bool?
        withKnownIssue(
            "the descendant's record could not be read",
            { gone = DescendantCheck.requireGone(pid: Self.descendantPID, start: Self.descendantStart, read: table.read) },
            matching: issueNames("\(Self.descendantPID)", "errno \(EPERM)")
        )
        #expect(gone == false, "an unreadable record was counted as an end")
        #expect(table.reads == 2, "the check read on after a record it could not read")
    }
}

// MARK: - A launch is accounted by how its run ended

/// AccountedRead stands in for the read of a recorded identity after the
/// release: it answers from a fixed set of pids that read gone, and keeps every
/// identity it was asked about, so a check can tell that a confirmed end was
/// never read again.
private final class AccountedRead: @unchecked Sendable {
    private let lock = NSLock()
    private let gone: Set<Int32>
    private var askedPids: [Int32] = []

    init(gone: Set<Int32>) { self.gone = gone }

    var asked: [Int32] { lock.withLock { askedPids } }

    func isGone(_ identity: StoppedChildSupport.RecordedProcess) -> Bool {
        lock.withLock {
            askedPids.append(identity.pid)
            return gone.contains(identity.pid)
        }
    }
}

/// OpenOnce is a gate a test opens once: `wait` returns when it is open, at
/// once if it already is. It lets a scripted run say "I am inside the call"
/// and lets the test say "go on", with no sleep and no polling.
private final class OpenOnce: @unchecked Sendable {
    private let lock = NSLock()
    private var isOpen = false
    private var waiters: [CheckedContinuation<Void, Never>] = []

    func open() {
        let pending = lock.withLock { () -> [CheckedContinuation<Void, Never>] in
            isOpen = true
            let all = waiters
            waiters = []
            return all
        }
        pending.forEach { $0.resume() }
    }

    func wait() async {
        await withCheckedContinuation { continuation in
            let already = lock.withLock { () -> Bool in
                if isOpen { return true }
                waiters.append(continuation)
                return false
            }
            if already { continuation.resume() }
        }
    }
}

/// ScriptedStep is what one call of a scripted inner runner does: read the
/// launch identity of `readPid` through the reader it was given (if any), run
/// `during` (which sees the calls listed so far), open `entered` and wait for
/// `resume` (if given), then return `result`. It starts no process.
private struct ScriptedStep: Sendable {
    var readPid: pid_t?
    var during: (@Sendable () -> Void)?
    var entered: OpenOnce?
    var resume: OpenOnce?
    var result: BoundedProcessResult

    init(_ result: BoundedProcessResult, readPid: pid_t? = nil, during: (@Sendable () -> Void)? = nil, entered: OpenOnce? = nil, resume: OpenOnce? = nil) {
        self.result = result
        self.readPid = readPid
        self.during = during
        self.entered = entered
        self.resume = resume
    }
}

/// ScriptedPlan hands out one step per call, in the order the calls are made.
private final class ScriptedPlan: @unchecked Sendable {
    private let lock = NSLock()
    private let steps: [ScriptedStep]
    private var next = 0

    init(_ steps: [ScriptedStep]) { self.steps = steps }

    func take() -> ScriptedStep {
        lock.withLock {
            defer { next += 1 }
            return next < steps.count ? steps[next] : ScriptedStep(.notConfirmedEnded)
        }
    }
}

private struct ScriptedRunner: BoundedProcessRunning {
    let reader: LaunchedChildSignaller.ProcessTableReader
    let step: ScriptedStep

    private func perform() async -> BoundedProcessResult {
        if let pid = step.readPid { _ = reader(pid) }
        step.during?()
        step.entered?.open()
        if let resume = step.resume { await resume.wait() }
        return step.result
    }

    func run(executableURL: URL, arguments: [String], standardInputData: Data, timeout: Duration) async -> BoundedProcessResult {
        await perform()
    }

    func runCapturingOutput(executableURL: URL, arguments: [String], standardInputData: Data, timeout: Duration) async -> BoundedProcessOutput {
        BoundedProcessOutput(result: await perform(), output: Data())
    }

    func runOnCallingThread(executableURL: URL, arguments: [String], standardInputData: Data, timeout: Duration) -> BoundedProcessResult {
        if let pid = step.readPid { _ = reader(pid) }
        step.during?()
        return step.result
    }
}

/// Snapshots keeps what a scripted run saw of the launch's calls.
private final class Snapshots: @unchecked Sendable {
    private let lock = NSLock()
    private var all: [[BoundedProcessResult?]] = []
    var launch: RunnerLaunch?
    func take() { lock.withLock { all.append(launch?.calls.map(\.result) ?? []) } }
    var values: [[BoundedProcessResult?]] { lock.withLock { all } }
}

@Suite("A test accounts for every launch by how its run ended")
struct LaunchAccountTests {
    /// DecisionCase is a list of calls (each one's result, nil while it still
    /// runs, and the pid of the identity its launch read gave, nil when none)
    /// with what the cleanup must decide for it.
    struct DecisionCase: Sendable, CustomTestStringConvertible {
        let label: String
        let results: [BoundedProcessResult?]
        let identities: [Int32?]
        /// the identities that read gone after the release
        var gone: Set<Int32> = []
        let removesDirectory: Bool
        /// the calls, by position, that the cleanup names and keeps the records for
        var named: [Int] = []
        /// the identities read after the release, in order
        var reads: [Int32] = []
        var testDescription: String { label }

        var calls: [LaunchCall] {
            zip(results, identities).map { result, pid in
                LaunchCall(result: result, identity: pid.map(LaunchAccountTests.identity))
            }
        }
    }

    static func identity(_ pid: Int32) -> StoppedChildSupport.RecordedProcess {
        StoppedChildSupport.RecordedProcess(pid: pid, start: ProcessStart(seconds: 1_700_000_000, microseconds: Int(pid)))
    }

    static let decisionCases: [DecisionCase] = [
        // The two schedules the account exists for.
        DecisionCase(label: "a known child that ended, then an unbound unconfirmed call: the unbound one is named and the records kept",
                     results: [.exited(0), .notConfirmedEnded], identities: [101, nil], removesDirectory: false, named: [1]),
        DecisionCase(label: "an unbound unconfirmed call, then a known child that ended: the unbound one is named and the records kept",
                     results: [.notConfirmedEnded, .exited(0)], identities: [nil, 101], removesDirectory: false, named: [0]),
        DecisionCase(label: "every call ended with a recorded identity: nothing is read and the records go",
                     results: [.exited(0), .exited(7), .timedOut], identities: [101, 102, 103], removesDirectory: true),
        DecisionCase(label: "every call has no identity and a confirmed end (exit codes, a death by signal, a timeout): no failure",
                     results: [.exited(0), .timedOut, .exited(-9), .exited(1)], identities: [nil, nil, nil, nil], removesDirectory: true),
        DecisionCase(label: "every identity missing and every result unconfirmed: each is named and the records kept",
                     results: [.notConfirmedEnded, .notConfirmedEnded], identities: [nil, nil], removesDirectory: false, named: [0, 1]),
        // Kept genuine controls.
        DecisionCase(label: "a failed launch is no child",
                     results: [.failedToLaunch], identities: [nil], removesDirectory: true),
        DecisionCase(label: "a failed launch beside a call that ended",
                     results: [.exited(0), .failedToLaunch, .timedOut], identities: [101, nil, nil], removesDirectory: true),
        DecisionCase(label: "a confirmed exit after an unavailable launch read is an end",
                     results: [.exited(3)], identities: [nil], removesDirectory: true),
        DecisionCase(label: "exited(255) is an end, with no identity",
                     results: [.exited(255)], identities: [nil], removesDirectory: true),
        // An unconfirmed call is confirmed only by a read of its own identity.
        DecisionCase(label: "an unconfirmed call whose identity reads gone after the release is removed",
                     results: [.notConfirmedEnded], identities: [101], gone: [101], removesDirectory: true, reads: [101]),
        DecisionCase(label: "an unconfirmed call whose identity still reads present is named and the records kept",
                     results: [.notConfirmedEnded], identities: [101], removesDirectory: false, named: [0], reads: [101]),
        DecisionCase(label: "two unconfirmed calls, one gone and one still present: only the present one is named",
                     results: [.notConfirmedEnded, .notConfirmedEnded], identities: [101, 102], gone: [101], removesDirectory: false, named: [1], reads: [101, 102]),
        DecisionCase(label: "a call that ended is never read again, whatever an unconfirmed one beside it reads",
                     results: [.exited(0), .notConfirmedEnded, .timedOut], identities: [101, 102, 103], gone: [102], removesDirectory: true, reads: [102]),
        // A call still running when the cleanup starts is an unconfirmed call.
        DecisionCase(label: "a call with no result yet whose identity reads gone is removed",
                     results: [nil], identities: [101], gone: [101], removesDirectory: true, reads: [101]),
        DecisionCase(label: "a call with no result yet whose identity still reads present is named",
                     results: [nil], identities: [101], removesDirectory: false, named: [0], reads: [101]),
        DecisionCase(label: "a call with no result yet and no identity is named",
                     results: [nil], identities: [nil], removesDirectory: false, named: [0]),
        DecisionCase(label: "no call was recorded: nothing was launched, the records go and nothing is named",
                     results: [], identities: [], removesDirectory: true),
        DecisionCase(label: "a failed launch, an exit without identity and an unconfirmed call that reads gone, together",
                     results: [.failedToLaunch, .exited(0), .notConfirmedEnded], identities: [nil, nil, 103], gone: [103], removesDirectory: true, reads: [103]),
    ]

    @Test("the per-call decision names every call it cannot confirm, and the records go only when none is left", arguments: decisionCases)
    func decisionPerCall(_ testCase: DecisionCase) {
        let read = AccountedRead(gone: testCase.gone)
        let verdict = LaunchAccount.decide(testCase.calls, gone: read.isGone)
        #expect(verdict.removeDirectory == testCase.removesDirectory)
        #expect(verdict.named == testCase.named)
        #expect(read.asked == testCase.reads, "the read after the release looked at \(read.asked)")
    }

    @Test("the signalling route signals only a call that has an identity and no confirmed end")
    func signalTargets() {
        let calls = [
            LaunchCall(result: .exited(0), identity: Self.identity(101)),
            LaunchCall(result: .notConfirmedEnded, identity: Self.identity(102)),
            LaunchCall(result: nil, identity: Self.identity(103)),
            LaunchCall(result: .notConfirmedEnded, identity: nil),
            LaunchCall(result: .failedToLaunch, identity: nil),
            LaunchCall(result: .timedOut, identity: Self.identity(104)),
            LaunchCall(result: nil, identity: nil),
            LaunchCall(result: .exited(255), identity: nil),
        ]
        #expect(LaunchAccount.signalTargets(calls) == [1, 2])
    }

    // MARK: Calls counted at the call, with no child started

    private static let missing = URL(fileURLWithPath: "/no/such/executable-cgmrelay-test")

    private static func directory() throws -> URL {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("launch-account-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }

    /// failLaunches makes one call of each entry point at an executable that is
    /// not there: posix_spawn refuses, so no child exists.
    private static func failLaunches(_ runner: any BoundedProcessRunning) async -> [BoundedProcessResult] {
        let first = await runner.run(executableURL: missing, arguments: [], standardInputData: Data(), timeout: .seconds(5))
        let second = await runner.runCapturingOutput(executableURL: missing, arguments: [], standardInputData: Data(), timeout: .seconds(5)).result
        let third = runner.runOnCallingThread(executableURL: missing, arguments: [], standardInputData: Data(), timeout: .seconds(5))
        return [first, second, third]
    }

    @Test("run, runCapturingOutput and runOnCallingThread each leave one entry with that call's own result and no identity when the launch failed")
    func everyEntryPointLeavesOneEntry() async throws {
        let launch = RunnerLaunch()
        let runner: any BoundedProcessRunning = launch.runner
        #expect(launch.calls.isEmpty)

        let first = await runner.run(executableURL: Self.missing, arguments: [], standardInputData: Data(), timeout: .seconds(5))
        #expect(launch.calls.map(\.result) == [first])
        let second = await runner.runCapturingOutput(executableURL: Self.missing, arguments: [], standardInputData: Data(), timeout: .seconds(5)).result
        #expect(launch.calls.map(\.result) == [first, second])
        let third = runner.runOnCallingThread(executableURL: Self.missing, arguments: [], standardInputData: Data(), timeout: .seconds(5))

        #expect([first, second, third] == [.failedToLaunch, .failedToLaunch, .failedToLaunch])
        #expect(launch.calls.map(\.result) == [.failedToLaunch, .failedToLaunch, .failedToLaunch])
        #expect(launch.calls.allSatisfy { $0.identity == nil })
    }

    @Test("a launch that failed is no child: endChildren removes the records and fails nothing")
    func endChildrenAfterFailedLaunches() async throws {
        let directory = try Self.directory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let launch = RunnerLaunch()
        _ = await Self.failLaunches(launch.runner)
        launch.endChildren(removing: directory)
        #expect(!FileManager.default.fileExists(atPath: directory.path), "the records of a launch that started nothing were kept")
    }

    @Test("a launch that failed is no child: endChildrenAfterRelease releases once, removes the records and fails nothing")
    func endChildrenAfterReleaseAfterFailedLaunches() async throws {
        let directory = try Self.directory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let launch = RunnerLaunch()
        _ = await Self.failLaunches(launch.runner)
        let releases = Counter()
        launch.endChildrenAfterRelease(removing: directory, release: { releases.bump() })
        #expect(releases.value == 1)
        #expect(!FileManager.default.fileExists(atPath: directory.path), "the records of a launch that started nothing were kept")
    }

    @Test("a launch that failed needs no identity: requireEnded fails nothing")
    func requireEndedAfterFailedLaunches() async throws {
        let launch = RunnerLaunch()
        _ = await Self.failLaunches(launch.runner)
        launch.requireEnded()
    }

    // MARK: Calls counted at the call, through a scripted inner runner (no child)

    /// A pid no live process has: the launch read of it finds nothing.
    private static let nowhere: pid_t = 2_000_000_000

    private static func scripted(_ steps: [ScriptedStep]) -> RunnerLaunch {
        let plan = ScriptedPlan(steps)
        return RunnerLaunch(inner: { reader in ScriptedRunner(reader: reader, step: plan.take()) })
    }

    private static func call(_ runner: any BoundedProcessRunning) async -> BoundedProcessResult {
        await runner.run(executableURL: missing, arguments: [], standardInputData: Data(), timeout: .seconds(5))
    }

    @Test("every entry point lists its call before the inner runner returns, with no result yet, and fills in that call's own result when it returns")
    func callIsListedBeforeTheChildStarts() async throws {
        let seen = Snapshots()
        let steps = [
            ScriptedStep(.exited(0), during: { seen.take() }),
            ScriptedStep(.timedOut, during: { seen.take() }),
            ScriptedStep(.exited(5), during: { seen.take() }),
        ]
        let launch = Self.scripted(steps)
        seen.launch = launch
        let runner: any BoundedProcessRunning = launch.runner

        let first = await runner.run(executableURL: Self.missing, arguments: [], standardInputData: Data(), timeout: .seconds(5))
        let second = await runner.runCapturingOutput(executableURL: Self.missing, arguments: [], standardInputData: Data(), timeout: .seconds(5)).result
        let third = runner.runOnCallingThread(executableURL: Self.missing, arguments: [], standardInputData: Data(), timeout: .seconds(5))

        #expect([first, second, third] == [.exited(0), .timedOut, .exited(5)])
        // Inside call n the list already holds n entries, the last one without a result.
        #expect(seen.values == [[nil], [.exited(0), nil], [.exited(0), .timedOut, nil]])
        #expect(launch.calls.map(\.result) == [.exited(0), .timedOut, .exited(5)])
    }

    @Test("a launch read that finds nothing, or a process that is not this process's child, leaves that call with no identity, and the next call is not given it")
    func identityIsPerCall() async throws {
        let launch = Self.scripted([
            ScriptedStep(.exited(1), readPid: Self.nowhere),
            ScriptedStep(.exited(2), readPid: getpid()),
            ScriptedStep(.exited(3)),
        ])
        let runner: any BoundedProcessRunning = launch.runner
        for _ in 0..<3 { _ = await Self.call(runner) }
        #expect(launch.calls.map(\.result) == [.exited(1), .exited(2), .exited(3)])
        #expect(launch.calls.allSatisfy { $0.identity == nil })
    }

    @Test("a known call that ended and an unbound unconfirmed call, in either order: the unbound one fails the test and the records stay", arguments: [false, true])
    func unboundUnconfirmedCallKeepsTheRecords(unconfirmedFirst: Bool) async throws {
        let directory = try Self.directory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let ended = ScriptedStep(.exited(0))
        let unconfirmed = ScriptedStep(.notConfirmedEnded)
        let launch = Self.scripted(unconfirmedFirst ? [unconfirmed, ended] : [ended, unconfirmed])
        let runner: any BoundedProcessRunning = launch.runner
        _ = await Self.call(runner)
        _ = await Self.call(runner)

        let releases = Counter()
        withKnownIssue("the unconfirmed call has no identity and its end cannot be read") {
            launch.endChildrenAfterRelease(removing: directory, release: { releases.bump() })
        }
        #expect(releases.value == 1)
        #expect(FileManager.default.fileExists(atPath: directory.path), "the records were removed while a call may still have a child")
    }

    @Test("the signalling route and requireEnded also fail naming an unbound unconfirmed call, and endChildren keeps the records")
    func otherCallersFailOnAnUnboundUnconfirmedCall() async throws {
        let directory = try Self.directory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let launch = Self.scripted([ScriptedStep(.exited(0)), ScriptedStep(.notConfirmedEnded)])
        let runner: any BoundedProcessRunning = launch.runner
        _ = await Self.call(runner)
        _ = await Self.call(runner)

        withKnownIssue("the unconfirmed call has no identity, so nothing can be signalled or read") {
            launch.endChildren(removing: directory)
        }
        #expect(FileManager.default.fileExists(atPath: directory.path), "the records were removed while a call may still have a child")
        withKnownIssue("the unconfirmed call has neither a confirmed end nor an identity read gone") {
            launch.requireEnded()
        }
    }

    @Test("a confirmed exit after an unavailable launch read is an end: nothing fails and the records go", arguments: [BoundedProcessResult.exited(3), .exited(255), .timedOut])
    func confirmedEndWithoutIdentity(_ result: BoundedProcessResult) async throws {
        let directory = try Self.directory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let launch = Self.scripted([ScriptedStep(result, readPid: Self.nowhere), ScriptedStep(.exited(0), readPid: Self.nowhere)])
        let runner: any BoundedProcessRunning = launch.runner
        _ = await Self.call(runner)
        _ = await Self.call(runner)
        #expect(launch.calls.allSatisfy { $0.identity == nil })

        launch.requireEnded()
        launch.endChildrenAfterRelease(removing: directory, release: {})
        #expect(!FileManager.default.fileExists(atPath: directory.path), "the records of calls that all ended were kept")
    }

    @Test("a call still running when the cleanup starts is an unconfirmed call: it fails the test and keeps the records, and once it returns the records go")
    func callStillRunningAtCleanup() async throws {
        let directory = try Self.directory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let entered = OpenOnce()
        let resume = OpenOnce()
        let launch = Self.scripted([ScriptedStep(.exited(0), entered: entered, resume: resume)])
        let runner: any BoundedProcessRunning = launch.runner
        let running = Task { await Self.call(runner) }
        await entered.wait()
        // Whatever happens below, the scripted run is let go.
        defer { resume.open() }

        #expect(launch.calls.map(\.result) == [nil])
        withKnownIssue("the call has not returned and has no identity") {
            launch.endChildrenAfterRelease(removing: directory, release: {})
        }
        #expect(FileManager.default.fileExists(atPath: directory.path), "the records were removed while a call was still running")

        resume.open()
        #expect(await running.value == .exited(0))
        launch.endChildrenAfterRelease(removing: directory, release: {})
        #expect(!FileManager.default.fileExists(atPath: directory.path), "the records were kept after every call ended")
    }

    @Test("a launch with no call recorded started nothing: the records go and nothing fails")
    func noCallsIsNoChild() throws {
        let directory = try Self.directory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let launch = RunnerLaunch()
        launch.requireEnded()
        launch.endChildrenAfterRelease(removing: directory, release: {})
        #expect(!FileManager.default.fileExists(atPath: directory.path))
        let second = try Self.directory()
        defer { try? FileManager.default.removeItem(at: second) }
        launch.endChildren(removing: second)
        #expect(!FileManager.default.fileExists(atPath: second.path))
    }

    private final class Counter: @unchecked Sendable {
        private let lock = NSLock()
        private var count = 0
        func bump() { lock.withLock { count += 1 } }
        var value: Int { lock.withLock { count } }
    }
}

// MARK: - The suites call the cleanup on every exit path

/// SourceText reads a test file with its comments and the contents of its
/// string literals removed, so what is left is the code a call or a brace
/// can be found in.
private enum SourceText {
    static func load(_ fileName: String) throws -> String {
        let directory = URL(fileURLWithPath: #filePath).deletingLastPathComponent()
        let text = try String(contentsOf: directory.appendingPathComponent(fileName), encoding: .utf8)
        return stripped(text)
    }

    static func stripped(_ source: String) -> String {
        let s = Array(source.unicodeScalars)
        var out = String.UnicodeScalarView()
        func has(_ text: String, at index: Int) -> Bool {
            let scalars = Array(text.unicodeScalars)
            return index + scalars.count <= s.count && Array(s[index..<index + scalars.count]) == scalars
        }
        var i = 0
        while i < s.count {
            if has("//", at: i) {
                while i < s.count, s[i] != "\n" { i += 1 }
                continue
            }
            if has("/*", at: i) {
                var depth = 1
                i += 2
                while i < s.count, depth > 0 {
                    if has("/*", at: i) { depth += 1; i += 2 } else if has("*/", at: i) { depth -= 1; i += 2 } else { i += 1 }
                }
                out.append(" ")
                continue
            }
            var hashes = 0
            var j = i
            while j < s.count, s[j] == "#" { hashes += 1; j += 1 }
            if j < s.count, s[j] == "\"" {
                let quotes = has("\"\"\"", at: j) ? 3 : 1
                let closing = String(repeating: "\"", count: quotes) + String(repeating: "#", count: hashes)
                var k = j + quotes
                while k < s.count {
                    if s[k] == "\\", hashes == 0 {
                        if k + 1 < s.count, s[k + 1] == "(" {
                            var depth = 1
                            k += 2
                            while k < s.count, depth > 0 {
                                if s[k] == "(" { depth += 1 } else if s[k] == ")" { depth -= 1 }
                                k += 1
                            }
                        } else {
                            k += 2
                        }
                        continue
                    }
                    if has(closing, at: k) { break }
                    k += 1
                }
                i = min(k + closing.unicodeScalars.count, s.count)
                out.append(contentsOf: "\"\"".unicodeScalars)
                continue
            }
            out.append(s[i])
            i += 1
        }
        return String(out)
    }

    /// braceBlock returns the text between the first `{` at or after `index`
    /// and its matching `}`, and where that block starts.
    static func braceBlock(in text: String, from index: String.Index) -> (inner: String, start: String.Index)? {
        guard let open = text[index...].firstIndex(of: "{") else { return nil }
        var depth = 0
        var cursor = open
        while cursor < text.endIndex {
            if text[cursor] == "{" { depth += 1 } else if text[cursor] == "}" {
                depth -= 1
                if depth == 0 {
                    return (String(text[text.index(after: open)..<cursor]), open)
                }
            }
            cursor = text.index(after: cursor)
        }
        return nil
    }

    static func functionBody(_ name: String, in text: String) -> (inner: String, start: String.Index)? {
        guard let found = text.range(of: "func \(name)(") else { return nil }
        return braceBlock(in: text, from: found.upperBound)
    }

    /// deferBlocks lists every `defer { ... }` in text, in order.
    static func deferBlocks(in text: String) -> [(inner: String, start: String.Index)] {
        var blocks: [(inner: String, start: String.Index)] = []
        var from = text.startIndex
        while let found = text.range(of: "defer {", range: from..<text.endIndex) {
            if let block = braceBlock(in: text, from: found.lowerBound) { blocks.append(block) }
            from = found.upperBound
        }
        return blocks
    }

    /// problemsOnEveryPath says what is wrong with how `name` ends the child it
    /// starts. The cleanup must sit in a defer block that no condition guards,
    /// registered before any statement that can leave the function early.
    static func problemsOnEveryPath(function name: String, in text: String, startedBy marker: String?, calling helper: String) -> [String] {
        guard let body = functionBody(name, in: text) else { return ["\(name) was not found"] }
        guard let cleanup = deferBlocks(in: body.inner).first(where: { $0.inner.contains(helper) }) else {
            return ["\(name) has no defer block that calls \(helper)"]
        }
        var problems: [String] = []
        if let call = cleanup.inner.range(of: helper) {
            let before = cleanup.inner[..<call.lowerBound]
            for guarding in ["if ", "guard ", "switch "] where before.contains(guarding) {
                problems.append("\(name): the cleanup sits behind a condition (\(guarding.trimmingCharacters(in: .whitespaces)))")
            }
        }
        if let marker {
            if let started = body.inner.range(of: marker) {
                if started.upperBound <= cleanup.start {
                    let between = body.inner[started.upperBound..<cleanup.start]
                    for early in ["#require", "throw ", "return"] where between.contains(early) {
                        problems.append("\(name): `\(early)` can leave the function before the cleanup is registered")
                    }
                }
            } else {
                problems.append("\(name): its start marker `\(marker)` is not in the function, so the early-exit check did not run")
            }
        }
        return problems
    }

    /// discards finds a result thrown away with `_ =` where it is a wait on a
    /// child or a call of the cleanup helpers.
    static func discards(in text: String) -> [String] {
        let pattern = #"_\s*=\s*[^\n]*(\.wait\(|waitForExit\(|ChildCleanup\.)"#
        guard let expression = try? NSRegularExpression(pattern: pattern) else { return ["bad pattern"] }
        let range = NSRange(text.startIndex..., in: text)
        return expression.matches(in: text, range: range).compactMap { match in
            Range(match.range, in: text).map { String(text[$0]) }
        }
    }
}

/// AllTestFiles reads every Swift file under Tests/CGMRelayCoreTests/, Support
/// included, with comments and string contents removed, so a source rule is
/// never limited to a list of names. A rule states how many files it read and
/// fails below the expected minimum.
private enum AllTestFiles {
    /// The least number of files a full read may find; fewer means the walk missed some.
    static let expectedMinimum = 45

    /// The starters of a real child: each names a type or helper that starts a process.
    static let realChildStarters = [
        "RealProcessLauncher(", "RealAccountChecker(", "RealTailscaleController(", "RealBoundedProcessRunner(",
        "ChildSpawner.spawn(", "HeldChild.start(", "HeldSleeper(", "TestChild(", "ObservedHelper.read(", "FakeTailscale(",
    ]

    static func read() throws -> [(name: String, text: String)] {
        let directory = URL(fileURLWithPath: #filePath).deletingLastPathComponent()
        let root = directory.standardizedFileURL.path
        let enumerator = try #require(FileManager.default.enumerator(at: directory, includingPropertiesForKeys: nil))
        var files: [(name: String, text: String)] = []
        for case let url as URL in enumerator where url.pathExtension == "swift" {
            let name = String(url.standardizedFileURL.path.dropFirst(root.count + 1))
            files.append((name, SourceText.stripped(try String(contentsOf: url, encoding: .utf8))))
        }
        return files.sorted { $0.name < $1.name }
    }

    /// suites lists every `@Suite` in text with its attribute and its body.
    static func suites(in text: String) -> [(attribute: String, body: String)] {
        var found: [(attribute: String, body: String)] = []
        var from = text.startIndex
        while let at = text.range(of: "@Suite(", range: from..<text.endIndex) {
            var depth = 1
            var cursor = at.upperBound
            while cursor < text.endIndex, depth > 0 {
                if text[cursor] == "(" { depth += 1 } else if text[cursor] == ")" { depth -= 1 }
                cursor = text.index(after: cursor)
            }
            found.append((String(text[at.lowerBound..<cursor]), SourceText.braceBlock(in: text, from: cursor)?.inner ?? ""))
            from = cursor
        }
        return found
    }

    /// suitesMissingTheSurvivorCheck names every suite in `files` whose body names a
    /// real-child starter and whose attribute lacks `.noSurvivingChildren`.
    static func suitesMissingTheSurvivorCheck(in files: [(name: String, text: String)]) -> [String] {
        var missing: [String] = []
        for file in files {
            for suite in suites(in: file.text) {
                guard let starter = realChildStarters.first(where: { suite.body.contains($0) }) else { continue }
                if !suite.attribute.contains(".noSurvivingChildren") {
                    missing.append("\(file.name): \(suite.attribute) names \(starter) and does not carry .noSurvivingChildren")
                }
            }
        }
        return missing
    }
}

/// DescendantCleanupRule says how the descendants test must treat the background process
/// it identifies: its identity is stored only after the record has shown it is the
/// leader's child and in the leader's group, and the cleanup confirms its end by read
/// only, never signalling it.
struct DescendantCleanupRule {
    static let function = "signalReachesTheChildsDescendants"

    static func problems(in text: String) -> [String] {
        guard let body = SourceText.functionBody(function, in: text) else { return ["\(function) was not found"] }
        let code = body.inner
        var found: [String] = []

        // 1. The identity is assigned only after both premises have passed.
        let premises = ["descendant.parentPID == pid", "getpgid(descendantPID) == pid"]
        var lastPremise = code.startIndex
        for premise in premises {
            if let at = code.range(of: premise) {
                if at.upperBound > lastPremise { lastPremise = at.upperBound }
            } else {
                found.append("\(function): the premise `\(premise)` is not checked")
            }
        }
        let assignments = (try? NSRegularExpression(pattern: #"descendantIdentity\s*=[^=]"#))?
            .matches(in: code, range: NSRange(code.startIndex..., in: code)) ?? []
        if assignments.isEmpty { found.append("\(function): the descendant's identity is never stored") }
        for match in assignments {
            if let range = Range(match.range, in: code), range.lowerBound < lastPremise {
                found.append("\(function): the identity is stored before both premises (its parent is the leader, its group is the leader's) have passed")
            }
        }

        // 2. The cleanup confirms the end by read only and sends the descendant nothing.
        guard let cleanup = SourceText.deferBlocks(in: code).first(where: { $0.inner.contains("input.release()") }) else {
            return found + ["\(function): no defer block releases the input"]
        }
        let inner = cleanup.inner
        if !inner.contains("DescendantCheck.requireGone(") { found.append("\(function): the cleanup does not confirm the descendant's end through DescendantCheck.requireGone") }
        let withoutLeader = inner.replacingOccurrences(of: "leader.send(SIGKILL)", with: "")
        for signalling in [".send(", "signal(", "kill(", "killpg(", "endRecorded"] where withoutLeader.contains(signalling) {
            found.append("\(function): the cleanup sends something other than the leader's own kill (`\(signalling)`)")
        }
        return found
    }
}

@Suite("The process suites call the cleanup on every exit path")
struct ProcessSuiteCleanupSourceTests {
    private static let threeFiles = ["BoundedProcessRunnerTests.swift", "EngineSupervisorTests.swift", "RealProcessLauncherTests.swift"]

    struct Site: Sendable, CustomTestStringConvertible {
        let file: String
        let function: String
        let marker: String?
        let helper: String
        var testDescription: String { "\(file) \(function)" }
    }

    static let sites: [Site] = [
        Site(file: "BoundedProcessRunnerTests.swift", function: "stoppedChildEndsTheRunAsTimedOut", marker: "createDirectory(", helper: "ChildCleanup.endRecordedChild("),
        Site(file: "RealProcessLauncherTests.swift", function: "signalReachesTheChildsDescendants", marker: "HeldChild.start(", helper: "ChildCleanup."),
        Site(file: "RealProcessLauncherTests.swift", function: "lineArrivesWhileEngineStillRuns", marker: "launcher.launch(", helper: "ChildCleanup."),
    ]

    /// Sites that already end their child on every path and must keep doing so.
    static let keptSites: [Site] = [
        Site(file: "RealProcessLauncherTests.swift", function: "stoppedThenContinuedChildReportsItsOwnExitOnce", marker: "spawnAnnounced(", helper: "endNow("),
        Site(file: "RealProcessLauncherTests.swift", function: "sendToAStoppedChildDoesNotWaitForItsExit", marker: "spawnAnnounced(", helper: "endNow("),
        Site(file: "RealProcessLauncherTests.swift", function: "sendAfterAStoppedChildWasReapedIsRefused", marker: "spawnAnnounced(", helper: "endNow("),
        Site(file: "EngineSupervisorTests.swift", function: "stopAndWaitEndsAStoppedEngine", marker: "launcher.process", helper: "endEngineIfLeftRunning("),
        Site(file: "EngineSupervisorTests.swift", function: "stopAndWaitReturnsOnlyAfterTheReap", marker: "launcher.process", helper: "endEngineIfLeftRunning("),
    ]

    @Test("a test that starts a child ends it in an unconditional defer registered before it can leave early", arguments: sites)
    func startedChildIsEndedOnEveryPath(_ site: Site) throws {
        let text = try SourceText.load(site.file)
        let problems = SourceText.problemsOnEveryPath(function: site.function, in: text, startedBy: site.marker, calling: site.helper)
        #expect(problems.isEmpty, "\(problems.joined(separator: "; "))")
    }

    @Test("the sites that already end their child in a defer keep doing so", arguments: keptSites)
    func keptSitesStillEndTheirChild(_ site: Site) throws {
        let text = try SourceText.load(site.file)
        let problems = SourceText.problemsOnEveryPath(function: site.function, in: text, startedBy: site.marker, calling: site.helper)
        #expect(problems.isEmpty, "\(problems.joined(separator: "; "))")
    }

    @Test("the engine and the stopped-child cleanups end through the cleanup helper and fail naming the child when the end is not seen")
    func finalWaitIsNotDiscarded() throws {
        let engine = try SourceText.load("EngineSupervisorTests.swift")
        let launcher = try SourceText.load("RealProcessLauncherTests.swift")
        for (file, name, text) in [("EngineSupervisorTests.swift", "endEngineIfLeftRunning", engine), ("RealProcessLauncherTests.swift", "endNow", launcher)] {
            let body = try #require(SourceText.functionBody(name, in: text), "\(file) has no \(name)")
            #expect(body.inner.contains("ChildCleanup.endHeld"), "\(name) does not end the child through ChildCleanup")
            let recordsFailure = body.inner.contains("ChildCleanup.endHeldRecordingNotConfirmed(") || body.inner.contains("Issue.record(")
            #expect(recordsFailure, "\(name) does not fail the test when the end is not confirmed")
        }
    }

    @Test("no wait on a child and no cleanup result is thrown away with `_ =` in any test file")
    func nothingIsDiscarded() throws {
        let files = try AllTestFiles.read()
        #expect(files.count >= AllTestFiles.expectedMinimum, "read \(files.count) test files, expected at least \(AllTestFiles.expectedMinimum)")
        for file in files {
            let found = SourceText.discards(in: file.text)
            #expect(found.isEmpty, "\(file.name) discards a result: \(found.joined(separator: " | "))")
        }
    }

    @Test("the helper process that reads a start time is started and ended by ObservedHelper, and no suite starts a Process by hand")
    func helperProcessesGoThroughObservedHelper() throws {
        let runner = try SourceText.load("BoundedProcessRunnerTests.swift")
        let body = try #require(SourceText.functionBody("lstart", in: runner), "no lstart in the runner tests")
        #expect(body.inner.contains("ObservedHelper."), "lstart does not read through ObservedHelper")
        let files = try AllTestFiles.read()
        #expect(files.count >= AllTestFiles.expectedMinimum, "read \(files.count) test files, expected at least \(AllTestFiles.expectedMinimum)")
        for file in files where file.name != "Support/TestChild.swift" {
            // `Process()` with no identifier character before it, so a name that merely ends in
            // "Process" (a test called stopTerminatesRunningProcess) is not read as one.
            let started = file.text.range(of: #"(?<![A-Za-z0-9_])Process\(\)"#, options: .regularExpression)
            #expect(started == nil, "\(file.name) starts a Process by hand")
        }
    }

    @Test("every suite in the three process test files carries the survivor check")
    func everySuiteCarriesTheSurvivorCheck() throws {
        for file in Self.threeFiles {
            let text = try SourceText.load(file)
            var attributes: [String] = []
            var from = text.startIndex
            while let found = text.range(of: "@Suite(", range: from..<text.endIndex) {
                var depth = 1
                var cursor = found.upperBound
                while cursor < text.endIndex, depth > 0 {
                    if text[cursor] == "(" { depth += 1 } else if text[cursor] == ")" { depth -= 1 }
                    cursor = text.index(after: cursor)
                }
                attributes.append(String(text[found.lowerBound..<cursor]))
                from = cursor
            }
            #expect(!attributes.isEmpty, "\(file) has no suite")
            for attribute in attributes {
                #expect(attribute.contains(".noSurvivingChildren"), "\(file): \(attribute) does not carry .noSurvivingChildren")
            }
        }
    }

    @Test("every suite in any test file whose body names a real-child starter carries the survivor check")
    func everySuiteThatStartsAChildCarriesTheSurvivorCheck() throws {
        let files = try AllTestFiles.read()
        #expect(files.count >= AllTestFiles.expectedMinimum, "read \(files.count) test files, expected at least \(AllTestFiles.expectedMinimum)")
        let missing = AllTestFiles.suitesMissingTheSurvivorCheck(in: files)
        #expect(missing.isEmpty, "\(missing.joined(separator: "; "))")
    }

    @Test("the descendants test stores the descendant's identity only after its premises pass, and its cleanup reads the end and signals nothing")
    func descendantsTestOrderAndNoSignal() throws {
        let problems = DescendantCleanupRule.problems(in: try SourceText.load("RealProcessLauncherTests.swift"))
        #expect(problems.isEmpty, "\(problems.joined(separator: "; "))")
    }
}

/// ReapFactRule says what a cleanup site must read and must not read to decide
/// that its child has ended: the holder's confirmed reap, never the fact that an
/// exit was reported (a report can be status unknown, which reaps nothing) or a
/// semaphore a callback signals for any code.
struct ReapFactRule: Sendable, CustomTestStringConvertible {
    let file: String
    let function: String
    let requires: [String]
    let forbids: [String]
    /// Each of these must appear in the function outside the argument list of
    /// every `ChildCleanup.endHeldRecordingNotConfirmed(` call: a release of the
    /// child's input inside the call's `send:` closure runs only when the child
    /// was not already reported ended, so a child whose leader ended first would
    /// keep a process blocked on that input.
    var releasesOutsideGate: [String] = []
    var testDescription: String { "\(file) \(function)" }

    func violations(in text: String) -> [String] {
        guard let body = SourceText.functionBody(function, in: text) else { return ["\(function) was not found"] }
        var found: [String] = []
        for needed in requires where !body.inner.contains(needed) { found.append("\(function) does not use \(needed)") }
        for banned in forbids where body.inner.contains(banned) { found.append("\(function) still uses \(banned)") }
        if !releasesOutsideGate.isEmpty {
            let outside = Self.removingGatedCalls(from: body.inner)
            for needle in releasesOutsideGate where !outside.contains(needle) {
                found.append("\(function) releases the input (\(needle)) only inside the cleanup call, so it is skipped when the child was already reported ended")
            }
        }
        return found
    }

    /// removingGatedCalls drops every `ChildCleanup.endHeldRecordingNotConfirmed(...)`
    /// call, its whole argument list, from text.
    private static func removingGatedCalls(from text: String) -> String {
        var rest = text
        let marker = "ChildCleanup.endHeldRecordingNotConfirmed("
        while let call = rest.range(of: marker) {
            var depth = 1
            var cursor = call.upperBound
            while cursor < rest.endIndex, depth > 0 {
                if rest[cursor] == "(" { depth += 1 } else if rest[cursor] == ")" { depth -= 1 }
                cursor = rest.index(after: cursor)
            }
            rest.removeSubrange(call.lowerBound..<cursor)
        }
        return rest
    }
}

@Suite("Every cleanup site decides on the confirmed reap and names what it could not confirm")
struct ProcessSuiteReapFactSourceTests {
    static let rules: [ReapFactRule] = [
        ReapFactRule(file: "EngineSupervisorTests.swift", function: "endEngineIfLeftRunning",
                     requires: ["ConfirmedEnd.isReaped(", "ConfirmedEnd.wait(", "reportedStatusUnknown"], forbids: ["exitCodes.isEmpty", "exited.wait("]),
        ReapFactRule(file: "RealProcessLauncherTests.swift", function: "endStarted",
                     requires: ["hasReportedExit", "waitReaped("], forbids: ["reported.isEmpty", "waitForExit("],
                     releasesOutsideGate: ["started.input.close()"]),
        ReapFactRule(file: "Support/HeldChild.swift", function: "endByReleasing",
                     requires: ["hasReportedExit", "waitReaped("], forbids: ["reported.isEmpty", "waitForExit(", "kill("],
                     releasesOutsideGate: ["input.release()"]),
        // The descendant is not held, so it is ended by the release of its input and confirmed by read only from its own
        // pid and start; nothing is sent to it, and nothing to a group after the leader is reaped.
        ReapFactRule(file: "RealProcessLauncherTests.swift", function: "signalReachesTheChildsDescendants",
                     requires: ["hasReportedExit", "waitReaped(", "send(SIGKILL)", "DescendantCheck.requireGone(", "Issue.record("],
                     forbids: ["reported.isEmpty", "waitForExit(", "kill(", "-pid", "killpg(", "StoppedChildSupport.signal(", "endRecorded"],
                     releasesOutsideGate: ["input.release()"]),
        ReapFactRule(file: "RealProcessLauncherTests.swift", function: "endNow",
                     requires: ["hasReportedExit", "waitReaped("], forbids: ["reported.isEmpty", "waitForExit("]),
        ReapFactRule(file: "RealProcessLauncherTests.swift", function: "lineArrivesWhileEngineStillRuns",
                     requires: ["ConfirmedEnd.isReaped(", "ConfirmedEnd.wait(", "reportedStatusUnknown"], forbids: ["exited.wait(", "alreadyEnded: false"]),
        ReapFactRule(file: "BoundedProcessRunnerTests.swift", function: "lstart",
                     requires: ["failIfNotEnded("], forbids: []),
        // A fixture that blocks on an input the test holds is ended by releasing it, and its end is read, never signalled.
        ReapFactRule(file: "BoundedProcessRunnerTests.swift", function: "unsignallableChildIsNotConfirmedEnded",
                     requires: ["HeldFifo(", "endChildrenAfterRelease(", "release:"], forbids: ["removeItem(", "StoppedChildSupport.signal(", "kill("]),
        ReapFactRule(file: "AccountCheckerTests.swift", function: "timedOutCheckProcessIsEnded",
                     requires: ["HeldFifo(", "RunnerLaunch(", "endChildrenAfterRelease(", "requireEnded("], forbids: ["kill(", "removeItem("]),
        ReapFactRule(file: "TailscaleServeTests.swift", function: "enableOutcomes",
                     requires: ["RunnerLaunch(", "endChildrenAfterRelease(", "release:"], forbids: ["fake.remove()", "kill("]),
        ReapFactRule(file: "TailscaleServeTests.swift", function: "changeRetries",
                     requires: ["RunnerLaunch(", "endChildrenAfterRelease(", "release:"], forbids: ["fake.remove()", "kill("]),
        ReapFactRule(file: "Support/RunnerLaunch.swift", function: "endChildren",
                     requires: ["LaunchAccount.signalTargets(", "ChildCleanup.endRecordedRecordingNotConfirmed(", "LaunchAccount.decide("], forbids: ["launchFailed", "unknownLaunch("]),
        ReapFactRule(file: "Support/RunnerLaunch.swift", function: "endChildrenAfterRelease",
                     requires: ["release()", "LaunchAccount.decide(", "DescendantCheck.requireGone(", "Issue.record("], forbids: ["signal(", "kill(", "launchFailed", "unknownLaunch("]),
        ReapFactRule(file: "Support/RunnerLaunch.swift", function: "requireEnded",
                     requires: ["LaunchAccount.decide(", "Issue.record("], forbids: ["signal(", "kill("]),
        ReapFactRule(file: "BoundedProcessRunnerTests.swift", function: "stoppedChildEndsTheRunAsTimedOut",
                     requires: ["launchFailed:"], forbids: []),
    ]

    @Test("a cleanup site reads the confirmed reap, never that an exit was reported", arguments: rules)
    func siteReadsTheConfirmedReap(_ rule: ReapFactRule) throws {
        let found = rule.violations(in: try SourceText.load(rule.file))
        #expect(found.isEmpty, "\(found.joined(separator: "; "))")
    }

    @Test("no test starts a process with Foundation's Process except TestChild, which never signals")
    func onlyTestChildStartsAProcessByHand() throws {
        let directory = URL(fileURLWithPath: #filePath).deletingLastPathComponent()
        let enumerator = try #require(FileManager.default.enumerator(at: directory, includingPropertiesForKeys: nil))
        var checked = 0
        for case let url as URL in enumerator where url.pathExtension == "swift" && url.lastPathComponent != "TestChild.swift" {
            checked += 1
            let text = SourceText.stripped(try String(contentsOf: url, encoding: .utf8))
            let started = text.range(of: #"(?<![A-Za-z0-9_])Process\(\)"#, options: .regularExpression)
            #expect(started == nil, "\(url.lastPathComponent) starts a Process by hand")
        }
        #expect(checked >= AllTestFiles.expectedMinimum - 1, "read \(checked) test files besides TestChild.swift, expected at least \(AllTestFiles.expectedMinimum - 1)")
    }

    @Test("every suite in this file that starts a real process carries the survivor check")
    func suitesThatStartProcessesCarryTheSurvivorCheck() throws {
        let text = try SourceText.load("ChildEndingTests.swift")
        let starters = ["HeldChild.start(", "HeldSleeper(", "TestChild(", "ObservedHelper.read(", "ChildSpawner.spawn("]
        var from = text.startIndex
        var suites = 0
        while let found = text.range(of: "@Suite(", range: from..<text.endIndex) {
            var depth = 1
            var cursor = found.upperBound
            while cursor < text.endIndex, depth > 0 {
                if text[cursor] == "(" { depth += 1 } else if text[cursor] == ")" { depth -= 1 }
                cursor = text.index(after: cursor)
            }
            let attribute = String(text[found.lowerBound..<cursor])
            let body = SourceText.braceBlock(in: text, from: cursor)?.inner ?? ""
            suites += 1
            from = cursor
            if starters.contains(where: { body.contains($0) }) {
                #expect(attribute.contains(".noSurvivingChildren"), "\(attribute) starts a process and does not carry .noSurvivingChildren")
            }
        }
        #expect(suites > 5)
    }
}

@Suite("The source rules reject what they are there to reject")
struct ProcessSuiteCleanupRuleControlTests {
    private func problems(_ source: String) -> [String] {
        SourceText.problemsOnEveryPath(function: "f", in: SourceText.stripped(source), startedBy: "start(", calling: "ChildCleanup.")
    }

    @Test("a cleanup in an unconditional defer right after the start is accepted")
    func goodShapeIsAccepted() {
        let source = """
        func f() throws {
            let child = try start()
            defer { ChildCleanup.endHeld(child) }
            try #require(child.ok)
        }
        """
        #expect(problems(source).isEmpty)
    }

    @Test("a cleanup that runs only on the success path is rejected")
    func successPathOnlyIsRejected() {
        let source = """
        func f() throws {
            let child = try start()
            try #require(child.ok)
            ChildCleanup.endHeld(child)
        }
        """
        #expect(!problems(source).isEmpty)
    }

    @Test("a cleanup registered after a statement that can leave early is rejected")
    func lateRegistrationIsRejected() {
        let source = """
        func f() throws {
            let child = try start()
            try #require(child.ok)
            defer { ChildCleanup.endHeld(child) }
        }
        """
        #expect(!problems(source).isEmpty)
    }

    @Test("a cleanup behind a flag set only by some outcomes is rejected")
    func guardedCleanupIsRejected() {
        let source = """
        func f() throws {
            let child = try start()
            defer { if hung { ChildCleanup.endHeld(child) } }
        }
        """
        #expect(!problems(source).isEmpty)
    }

    @Test("a defer that does not call the helper is rejected")
    func missingCallIsRejected() {
        let source = """
        func f() throws {
            let child = try start()
            defer { child.closeInput() }
        }
        """
        #expect(!problems(source).isEmpty)
    }

    @Test("a call that only a comment or a string mentions is not a call")
    func commentsAndStringsAreNotCode() {
        let source = """
        func f() throws {
            let child = try start()
            let text = "{ ChildCleanup.endHeld }"
            // defer { ChildCleanup.endHeld(child) }
            defer { child.closeInput() }
        }
        """
        #expect(!problems(source).isEmpty)
    }

    @Test("a site that decides on a reported exit, a callback semaphore or a bare kill is rejected, one that reads the confirmed reap is accepted")
    func reapFactRuleSeparatesTheShapes() {
        let rule = ReapFactRule(file: "none", function: "end", requires: ["hasReportedExit"], forbids: ["reported.isEmpty", "kill("])
        func violations(_ body: String) -> [String] {
            rule.violations(in: SourceText.stripped("func end(_ x: X) {\n\(body)\n}"))
        }
        #expect(violations("ChildCleanup.endHeldRecordingNotConfirmed(alreadyEnded: x.child.hasReportedExit)").isEmpty)
        #expect(!violations("ChildCleanup.endHeldRecordingNotConfirmed(alreadyEnded: !x.exits.reported.isEmpty)").isEmpty)
        #expect(!violations("let ended = x.child.hasReportedExit; kill(-pid, SIGKILL)").isEmpty)
        #expect(!violations("// x.child.hasReportedExit named only in a comment").isEmpty)
    }

    @Test("a release of the child's input that sits only inside the cleanup call is rejected, one outside it is accepted")
    func releaseOutsideTheGateIsRequired() {
        let rule = ReapFactRule(file: "none", function: "end", requires: [], forbids: [], releasesOutsideGate: ["input.release()"])
        func violations(_ body: String) -> [String] {
            rule.violations(in: SourceText.stripped("func end(_ x: X) {\n\(body)\n}"))
        }
        let gated = """
        defer {
            ChildCleanup.endHeldRecordingNotConfirmed(
                pid: pid, start: leader.birthStart, alreadyEnded: leader.hasReportedExit,
                send: { leader.send(SIGKILL); input.release() },
                waitForEnd: { leader.waitReaped(milliseconds: $0) }, waitingMilliseconds: bound)
        }
        """
        let outside = """
        defer {
            input.release()
            ChildCleanup.endHeldRecordingNotConfirmed(
                pid: pid, start: leader.birthStart, alreadyEnded: leader.hasReportedExit,
                send: { leader.send(SIGKILL) },
                waitForEnd: { leader.waitReaped(milliseconds: $0) }, waitingMilliseconds: bound)
        }
        """
        #expect(!violations(gated).isEmpty)
        #expect(violations(outside).isEmpty)
        #expect(!violations("// input.release() named only in a comment").isEmpty)
    }

    @Test("a site whose start marker is not in the function is a problem, not a skipped check")
    func absentMarkerIsAProblem() {
        let source = """
        func f() throws {
            let child = try launch()
            defer { ChildCleanup.endHeld(child) }
        }
        """
        let found = SourceText.problemsOnEveryPath(function: "f", in: SourceText.stripped(source), startedBy: "start(", calling: "ChildCleanup.")
        #expect(found.contains { $0.contains("start marker") })
    }

    private static let goodDescendants = """
    func signalReachesTheChildsDescendants() throws {
        var descendantIdentity: Identity?
        defer {
            input.release()
            ChildCleanup.endHeldRecordingNotConfirmed(pid: pid, start: nil, alreadyEnded: leader.hasReportedExit,
                send: { leader.send(SIGKILL) }, waitForEnd: { leader.waitReaped(milliseconds: $0) }, waitingMilliseconds: bound)
            if let identity = descendantIdentity {
                if !DescendantCheck.requireGone(pid: identity.pid, start: identity.start, read: { readProcessTable($0) }) { Issue.record("not ended") }
            }
        }
        try #require(descendant.parentPID == pid)
        try #require(getpgid(descendantPID) == pid)
        descendantIdentity = Identity(pid: descendantPID)
    }
    """

    @Test("the descendant rule accepts the identity stored after both premises and a cleanup that only reads")
    func descendantRuleAcceptsTheGoodShape() {
        #expect(DescendantCleanupRule.problems(in: SourceText.stripped(Self.goodDescendants)).isEmpty)
    }

    @Test("the descendant rule rejects an identity stored before a premise has passed")
    func descendantRuleRejectsAnEarlyIdentity() {
        let early = Self.goodDescendants
            .replacingOccurrences(of: "    try #require(descendant.parentPID == pid)\n    try #require(getpgid(descendantPID) == pid)\n    descendantIdentity = Identity(pid: descendantPID)",
                                   with: "    descendantIdentity = Identity(pid: descendantPID)\n    try #require(descendant.parentPID == pid)\n    try #require(getpgid(descendantPID) == pid)")
        #expect(early != Self.goodDescendants)
        #expect(!DescendantCleanupRule.problems(in: SourceText.stripped(early)).isEmpty)
        let afterOne = Self.goodDescendants
            .replacingOccurrences(of: "    try #require(descendant.parentPID == pid)\n    try #require(getpgid(descendantPID) == pid)\n    descendantIdentity = Identity(pid: descendantPID)",
                                   with: "    try #require(descendant.parentPID == pid)\n    descendantIdentity = Identity(pid: descendantPID)\n    try #require(getpgid(descendantPID) == pid)")
        #expect(!DescendantCleanupRule.problems(in: SourceText.stripped(afterOne)).isEmpty)
    }

    @Test("the descendant rule rejects a cleanup that sends the descendant any signal, and one that does not confirm its end by read")
    func descendantRuleRejectsASignallingCleanup() {
        let signalling = Self.goodDescendants.replacingOccurrences(
            of: "if let identity = descendantIdentity {",
            with: "if let identity = descendantIdentity {\n                StoppedChildSupport.signal(identity, SIGKILL)")
        #expect(signalling != Self.goodDescendants)
        #expect(!DescendantCleanupRule.problems(in: SourceText.stripped(signalling)).isEmpty)
        let killed = Self.goodDescendants.replacingOccurrences(of: "if let identity = descendantIdentity {", with: "if let identity = descendantIdentity {\n                kill(identity.pid, SIGKILL)")
        #expect(!DescendantCleanupRule.problems(in: SourceText.stripped(killed)).isEmpty)
        let unread = Self.goodDescendants.replacingOccurrences(of: "DescendantCheck.requireGone(", with: "somethingElse(")
        #expect(!DescendantCleanupRule.problems(in: SourceText.stripped(unread)).isEmpty)
    }

    private static let starterFiles: [(name: String, text: String)] = [
        ("RealProcessLauncherTests.swift", SourceText.stripped("""
        @Suite("RealProcessLauncher", .noSurvivingChildren)
        struct A { func f() { _ = ChildSpawner.spawn(x) } }
        """)),
        ("OtherTests.swift", SourceText.stripped("""
        @Suite("RealAccountChecker")
        struct B { func f() { let c = RealAccountChecker(engineURL: u) } }
        """)),
    ]

    @Test("the old three-file scope misses a starter in another file; the scope over every file names it")
    func oldScopeMissesAStarterInAnotherFile() {
        let threeNames = ["BoundedProcessRunnerTests.swift", "EngineSupervisorTests.swift", "RealProcessLauncherTests.swift"]
        let oldScope = AllTestFiles.suitesMissingTheSurvivorCheck(in: Self.starterFiles.filter { threeNames.contains($0.name) })
        let everyFile = AllTestFiles.suitesMissingTheSurvivorCheck(in: Self.starterFiles)
        #expect(oldScope.isEmpty, "the old scope was expected to miss it")
        #expect(everyFile.count == 1 && everyFile[0].contains("OtherTests.swift") && everyFile[0].contains("RealAccountChecker("), "\(everyFile)")
    }

    @Test("a starter named only in a comment or a string is not a starter, and a suite with the trait is accepted")
    func startersInCommentsAndStringsAreNotStarters() {
        let files: [(name: String, text: String)] = [("QuietTests.swift", SourceText.stripped("""
        // RealAccountChecker( is only named here
        @Suite("starts HeldChild.start( in prose")
        struct Quiet { let text = "TestChild(" }
        @Suite("starts one", .noSurvivingChildren)
        struct Loud { func f() { _ = try? TestChild(executable: "x", arguments: []) } }
        """))]
        #expect(AllTestFiles.suitesMissingTheSurvivorCheck(in: files).isEmpty)
    }

    @Test("a thrown-away wait or cleanup result is found, an ordinary discarded launch is not")
    func discardsAreFound() {
        #expect(!SourceText.discards(in: "_ = exited.wait(timeout: bound)").isEmpty)
        #expect(!SourceText.discards(in: "_ = started.exits.waitForExit()").isEmpty)
        #expect(!SourceText.discards(in: "_ = ChildCleanup.endHeld(a)").isEmpty)
        #expect(SourceText.discards(in: "_ = try launcher.launch(a)").isEmpty)
        #expect(SourceText.discards(in: "_ = try await withCheckedThrowingContinuation { }").isEmpty)
    }
}
