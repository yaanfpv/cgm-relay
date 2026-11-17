import Testing
import Foundation

/// These checks are the contract of TestChild (Support/TestChild.swift), the
/// test-target routine the credential lock test uses to end its child: it ends the child by
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
//         struct Observation { let output: String?; let helperPid: Int32?; let helperEnded: Bool }
//         // Starts the helper, waits on its exit event for at most the bound and
//         // returns its trimmed standard output only when it exited with status 0
//         // in time. Whatever happened, a helper it started is ended through its
//         // own handle and collected before this returns, and helperEnded says so.
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

/// HeldSleeper is a real /bin/sleep child this test holds and ends itself.
private final class HeldSleeper: @unchecked Sendable {
    let pid: Int32
    private let process: Process
    private let exited: DispatchSemaphore
    private let lock = NSLock()
    private var observed = false

    init() throws {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/bin/sleep")
        process.arguments = ["30"]
        let exited = DispatchSemaphore(value: 0)
        process.terminationHandler = { _ in exited.signal() }
        try process.run()
        self.process = process
        self.exited = exited
        self.pid = process.processIdentifier
    }

    var isRunning: Bool { process.isRunning }

    func terminate() { process.terminate() }

    /// waitForEnd waits on the exit event for at most the given bound.
    func waitForEnd(milliseconds: Int32) -> Bool {
        if lock.withLock({ observed }) { return true }
        guard exited.wait(timeout: .now() + .milliseconds(Int(max(0, milliseconds)))) == .success else { return false }
        lock.withLock { observed = true }
        return true
    }

    /// endNow ends the child this test holds and says whether its exit was seen.
    func endNow() -> Bool {
        if !lock.withLock({ observed }) && process.isRunning { process.terminate() }
        return waitForEnd(milliseconds: TestChild.hangCeilingMilliseconds)
    }
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

@Suite("ChildCleanup ends a child the caller holds and says plainly when it could not confirm the end")
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

@Suite("ObservedHelper ends and collects the helper process it starts, whatever the observation returns")
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

    @Test("a helper that cannot be started gives no output and has no process to end")
    func unstartableHelperGivesNothing() {
        let observation = ObservedHelper.read(executable: "/no/such/helper-cgmrelay-test", arguments: [], waitingMilliseconds: TestChild.hangCeilingMilliseconds)
        #expect(observation.output == nil)
        #expect(observation.helperPid == nil)
    }
}

@Suite("ChildSurvivors names every child the suites started and left alive")
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
            #expect(!(try SourceText.load(file)).contains("Process()"), "\(file) starts a Process by hand")
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

    @Test("a thrown-away wait or cleanup result is found, an ordinary discarded launch is not")
    func discardsAreFound() {
        #expect(!SourceText.discards(in: "_ = exited.wait(timeout: bound)").isEmpty)
        #expect(!SourceText.discards(in: "_ = started.exits.waitForExit()").isEmpty)
        #expect(!SourceText.discards(in: "_ = ChildCleanup.endHeld(a)").isEmpty)
        #expect(SourceText.discards(in: "_ = try launcher.launch(a)").isEmpty)
        #expect(SourceText.discards(in: "_ = try await withCheckedThrowingContinuation { }").isEmpty)
    }
}
