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
//         static func liveChildren() -> [Child]                       // direct children of this process, read from the kernel
//         static func new(since before: [Child], now: [Child]) -> [Child]
//         static func recordSurvivors(_ survivors: [Child])           // one failure per survivor naming its pid and start
//         final class Accounting: @unchecked Sendable {
//             init(census: @escaping @Sendable () -> [Child])
//             func enter()                                            // the first enter takes the baseline census
//             func exit() -> [Child]                                  // the last exit returns the children new since the baseline, others return []
//         }
//     }
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
        let sleeper = try HeldSleeper()
        defer { #expect(sleeper.endNow(), "test child \(sleeper.pid) may still be running, it was not confirmed ended") }
        let outcome = ChildCleanup.endHeld(
            pid: sleeper.pid, start: Self.start, alreadyEnded: false,
            send: {}, waitForEnd: { sleeper.waitForEnd(milliseconds: $0) },
            waitingMilliseconds: Self.shortBound
        )
        #expect(outcome == .notConfirmed(pid: sleeper.pid, start: Self.start))
        #expect(sleeper.isRunning)
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
        private var other = true
        func read(_ pid: pid_t, real: ProcessRecord?) -> ProcessRecord? {
            lock.withLock {
                reads += 1
                guard reads > 1, other, let real else { return real }
                return ProcessRecord(pid: real.pid, parentPID: real.parentPID, start: ProcessStart(seconds: real.start.seconds, microseconds: real.start.microseconds + 1))
            }
        }
        func showRealAgain() { lock.withLock { other = false } }
    }

    enum UnboundIdentity: String, Sendable, CaseIterable, CustomTestStringConvertible {
        case nothingAtBirth, replacementAtBirth, changedAfterBirth
        var testDescription: String { rawValue }
    }

    @Test("a helper whose identity does not hold is sent nothing and is not confirmed ended, and its sleep is ended through the test's own handle", arguments: UnboundIdentity.allCases)
    func unboundIdentityIsNeverSignalled(_ identity: UnboundIdentity) {
        let gate = IdentityGate()
        // The sleep ends by itself after 2 seconds, so it cannot outlive the test
        // whatever happens here, and the short bound below always expires first.
        let observation = ObservedHelper.read(
            executable: "/bin/sleep", arguments: ["2"], waitingMilliseconds: 100,
            readProcessTable: { pid in
                let real = LaunchedChildSignaller.systemProcessTable(pid)
                switch identity {
                case .nothingAtBirth: return nil
                case .replacementAtBirth: return ProcessRecord(pid: pid, parentPID: getpid() + 1, start: ProcessStart(seconds: 1, microseconds: 0))
                case .changedAfterBirth: return gate.read(pid, real: real)
                }
            }
        )
        let helper = observation.helper
        // Ended through the test's own handle on every path from here.
        defer {
            if let helper {
                gate.showRealAgain()
                ChildCleanup.endHeldRecordingNotConfirmed(
                    pid: helper.processIdentifier, start: helper.birthStart, alreadyEnded: helper.hasReportedExit,
                    send: { helper.send(SIGKILL) },
                    waitForEnd: { helper.waitReaped(milliseconds: $0) },
                    waitingMilliseconds: TestChild.hangCeilingMilliseconds
                )
            }
        }
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
    private final class Census: @unchecked Sendable {
        private let lock = NSLock()
        private var stored: [ChildSurvivors.Child] = []
        var current: [ChildSurvivors.Child] {
            get { lock.withLock { stored } }
            set { lock.withLock { stored = newValue } }
        }
    }

    private static func child(_ pid: Int32) -> ChildSurvivors.Child { ChildSurvivors.Child(pid: pid, start: "start-\(pid)") }

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
        #expect(ChildSurvivors.liveChildren().contains { $0.pid == sleeper.pid }, "held child \(sleeper.pid) is not in the census")
        #expect(sleeper.endNow())
        #expect(!ChildSurvivors.liveChildren().contains { $0.pid == sleeper.pid }, "ended child \(sleeper.pid) is still in the census")
    }

    @Test("the check runs when the last scope exits, against the baseline the first scope took")
    func accountingChecksWhenTheLastScopeExits() {
        let census = Census()
        census.current = [Self.child(1)]
        let accounting = ChildSurvivors.Accounting(census: { census.current })
        accounting.enter()
        census.current = [Self.child(1), Self.child(2)]
        accounting.enter()
        census.current = [Self.child(1), Self.child(2), Self.child(3)]
        #expect(accounting.exit().isEmpty, "the check ran while another suite was still running")
        #expect(accounting.exit() == [Self.child(2), Self.child(3)])
    }

    @Test("children that ended before the last scope exits are not survivors, and a later round starts from a new baseline")
    func accountingSeesOnlyWhatIsStillThere() {
        let census = Census()
        let accounting = ChildSurvivors.Accounting(census: { census.current })
        accounting.enter()
        census.current = [Self.child(5)]
        census.current = []
        #expect(accounting.exit().isEmpty)

        census.current = [Self.child(6)]
        accounting.enter()
        census.current = [Self.child(6), Self.child(7)]
        #expect(accounting.exit() == [Self.child(7)])
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
        let held = try HeldChild.start(
            executable: "/bin/sleep", arguments: ["2"],
            readProcessTable: { pid in ProcessRecord(pid: pid, parentPID: getpid() + 1, start: ProcessStart(seconds: 1, microseconds: 0)) }
        )
        // The sleep ends by itself after 2 seconds; its reap is confirmed here on every path.
        defer {
            ChildCleanup.endHeldRecordingNotConfirmed(
                pid: held.processIdentifier, start: held.birthStart, alreadyEnded: held.hasReportedExit,
                send: {}, waitForEnd: { held.waitReaped(milliseconds: $0) },
                waitingMilliseconds: TestChild.hangCeilingMilliseconds
            )
        }
        let outcome = held.end(signals: [SIGTERM, SIGKILL], waitingMilliseconds: 100)
        #expect(outcome == .notConfirmed(pid: held.processIdentifier, start: held.birthStart))
        #expect(!held.hasExited, "a child whose identity did not hold was ended anyway")
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
        if let marker, let started = body.inner.range(of: marker), started.upperBound <= cleanup.start {
            let between = body.inner[started.upperBound..<cleanup.start]
            for early in ["#require", "throw ", "return"] where between.contains(early) {
                problems.append("\(name): `\(early)` can leave the function before the cleanup is registered")
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
        Site(file: "RealProcessLauncherTests.swift", function: "signalReachesTheChildsDescendants", marker: "ChildSpawner.spawn(", helper: "ChildCleanup."),
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

    @Test("no wait on a child and no cleanup result is thrown away with `_ =` in the three process suites")
    func nothingIsDiscarded() throws {
        for file in Self.threeFiles {
            let found = SourceText.discards(in: try SourceText.load(file))
            #expect(found.isEmpty, "\(file) discards a result: \(found.joined(separator: " | "))")
        }
    }

    @Test("the helper process that reads a start time is started and ended by ObservedHelper, and no suite starts a Process by hand")
    func helperProcessesGoThroughObservedHelper() throws {
        let runner = try SourceText.load("BoundedProcessRunnerTests.swift")
        let body = try #require(SourceText.functionBody("lstart", in: runner), "no lstart in the runner tests")
        #expect(body.inner.contains("ObservedHelper."), "lstart does not read through ObservedHelper")
        for file in Self.threeFiles {
            // `Process()` with no identifier character before it, so a name that merely ends in
            // "Process" (a test called stopTerminatesRunningProcess) is not read as one.
            let started = try SourceText.load(file).range(of: #"(?<![A-Za-z0-9_])Process\(\)"#, options: .regularExpression)
            #expect(started == nil, "\(file) starts a Process by hand")
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
    var testDescription: String { "\(file) \(function)" }

    func violations(in text: String) -> [String] {
        guard let body = SourceText.functionBody(function, in: text) else { return ["\(function) was not found"] }
        var found: [String] = []
        for needed in requires where !body.inner.contains(needed) { found.append("\(function) does not use \(needed)") }
        for banned in forbids where body.inner.contains(banned) { found.append("\(function) still uses \(banned)") }
        return found
    }
}

@Suite("Every cleanup site decides on the confirmed reap and names what it could not confirm")
struct ProcessSuiteReapFactSourceTests {
    static let rules: [ReapFactRule] = [
        ReapFactRule(file: "EngineSupervisorTests.swift", function: "endEngineIfLeftRunning",
                     requires: ["ConfirmedEnd.isReaped(", "ConfirmedEnd.wait(", "reportedStatusUnknown"], forbids: ["exitCodes.isEmpty", "exited.wait("]),
        ReapFactRule(file: "RealProcessLauncherTests.swift", function: "endStarted",
                     requires: ["hasReportedExit", "waitReaped("], forbids: ["reported.isEmpty", "waitForExit("]),
        ReapFactRule(file: "RealProcessLauncherTests.swift", function: "signalReachesTheChildsDescendants",
                     requires: ["hasReportedExit", "waitReaped(", "send(SIGKILL)"],
                     forbids: ["reported.isEmpty", "waitForExit(", "kill(", "endRecorded", "RecordedDescendant", "descendantRecord"]),
        ReapFactRule(file: "RealProcessLauncherTests.swift", function: "endNow",
                     requires: ["hasReportedExit", "waitReaped("], forbids: ["reported.isEmpty", "waitForExit("]),
        ReapFactRule(file: "RealProcessLauncherTests.swift", function: "lineArrivesWhileEngineStillRuns",
                     requires: ["ConfirmedEnd.isReaped(", "ConfirmedEnd.wait(", "reportedStatusUnknown"], forbids: ["exited.wait(", "alreadyEnded: false"]),
        ReapFactRule(file: "BoundedProcessRunnerTests.swift", function: "lstart",
                     requires: ["failIfNotEnded("], forbids: []),
        ReapFactRule(file: "BoundedProcessRunnerTests.swift", function: "unsignallableChildIsNotConfirmedEnded",
                     requires: ["ChildCleanup.endRecordedRemovingOnEnd("], forbids: ["removeItem("]),
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
        #expect(checked > 10, "only \(checked) test files were looked at")
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

    @Test("a thrown-away wait or cleanup result is found, an ordinary discarded launch is not")
    func discardsAreFound() {
        #expect(!SourceText.discards(in: "_ = exited.wait(timeout: bound)").isEmpty)
        #expect(!SourceText.discards(in: "_ = started.exits.waitForExit()").isEmpty)
        #expect(!SourceText.discards(in: "_ = ChildCleanup.endHeld(a)").isEmpty)
        #expect(SourceText.discards(in: "_ = try launcher.launch(a)").isEmpty)
        #expect(SourceText.discards(in: "_ = try await withCheckedThrowingContinuation { }").isEmpty)
    }
}
