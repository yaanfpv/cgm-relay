import Testing
import Foundation
@testable import CGMRelayCore

/// ChildCleanup ends the children a test started and says plainly when it
/// could not confirm an end. `.ended` means the child's exit was observed, or
/// that no process with the recorded identity exists any more. Anything else
/// is `.notConfirmed`, and the recording forms turn it into a test failure
/// that names the child and the start time recorded for it.
///
/// A child is signalled only in two cases: the caller still holds it (the
/// `send` closure goes through its own handle), or it is known by the pid and
/// start text recorded at its launch and the number still shows that start
/// just before the send. A start that cannot be read, or that differs, sends
/// nothing.
enum ChildCleanup {
    enum Outcome: Equatable {
        case ended
        case notConfirmed(pid: Int32, start: String?)
    }

    /// The pause between two looks at a child that was just signalled. It only
    /// spaces the looks; the wait ends at the child's end or the given bound.
    private static let lookIntervalMicroseconds: UInt32 = 20_000

    /// describe names a child the way every failure message does.
    static func describe(pid: Int32, start: String?) -> String {
        "pid \(pid) (start \(start ?? "not recorded"))"
    }

    /// launchStart reads the start time of a child just launched and still
    /// held, as text, for the failure message of a held child.
    static func launchStart(pid: Int32) -> String? {
        LaunchedChildSignaller.systemProcessTable(pid).map { "\($0.start.seconds).\($0.start.microseconds)" }
    }

    // MARK: A child the caller holds

    /// endHeld ends a child the caller still holds. It does nothing and returns
    /// `.ended` when the exit was already seen. Otherwise it runs `send`, which
    /// must go through the child's own handle, then `waitForEnd`, which says
    /// whether the exit event was observed within the bound.
    static func endHeld(
        pid: Int32,
        start: String?,
        alreadyEnded: Bool,
        send: () -> Void,
        waitForEnd: (Int32) -> Bool,
        waitingMilliseconds: Int32
    ) -> Outcome {
        if alreadyEnded { return .ended }
        send()
        return waitForEnd(waitingMilliseconds) ? .ended : .notConfirmed(pid: pid, start: start)
    }

    /// endHeldRecordingNotConfirmed is endHeld that fails the test, naming the
    /// child, when its end was not observed.
    @discardableResult
    static func endHeldRecordingNotConfirmed(
        pid: Int32,
        start: String?,
        alreadyEnded: Bool,
        send: () -> Void,
        waitForEnd: (Int32) -> Bool,
        waitingMilliseconds: Int32
    ) -> Outcome {
        let outcome = endHeld(
            pid: pid, start: start, alreadyEnded: alreadyEnded,
            send: send, waitForEnd: waitForEnd, waitingMilliseconds: waitingMilliseconds
        )
        recordIfNotConfirmed(outcome)
        return outcome
    }

    // MARK: A child known by the identity recorded at its launch

    /// endRecorded ends a child known only by the pid and start text recorded
    /// at its launch. The child counts as gone when `exists` says no process has
    /// the number, or `readStart` shows another start. A start that cannot be
    /// read while the number still exists sends nothing and is not confirmed.
    /// After a send it looks again until the child is gone or the bound runs out.
    static func endRecorded(
        pid: Int32,
        start: String,
        readStart: (Int32) -> String?,
        exists: (Int32) -> Bool,
        send: (Int32, Int32) -> Void,
        waitingMilliseconds: Int32
    ) -> Outcome {
        guard exists(pid) else { return .ended }
        guard let current = readStart(pid) else { return .notConfirmed(pid: pid, start: start) }
        guard current == start else { return .ended }
        send(pid, SIGKILL)

        func gone() -> Bool {
            if !exists(pid) { return true }
            if let now = readStart(pid), now != start { return true }
            return false
        }
        let deadline = DispatchTime.now() + .milliseconds(Int(max(0, waitingMilliseconds)))
        while true {
            if gone() { return .ended }
            if DispatchTime.now() >= deadline { return .notConfirmed(pid: pid, start: start) }
            usleep(lookIntervalMicroseconds)
        }
    }

    /// endRecordedRecordingNotConfirmed is endRecorded that fails the test,
    /// naming the child, when its end was not confirmed.
    @discardableResult
    static func endRecordedRecordingNotConfirmed(
        pid: Int32,
        start: String,
        readStart: (Int32) -> String?,
        exists: (Int32) -> Bool,
        send: (Int32, Int32) -> Void,
        waitingMilliseconds: Int32
    ) -> Outcome {
        let outcome = endRecorded(
            pid: pid, start: start, readStart: readStart, exists: exists,
            send: send, waitingMilliseconds: waitingMilliseconds
        )
        recordIfNotConfirmed(outcome)
        return outcome
    }

    /// endRecordedChild reads the record a test child wrote about itself, its
    /// pid on the first line and its start text on the second, and ends it as
    /// endRecorded does. It deletes `directory` only when the child is
    /// confirmed ended; otherwise it fails the test naming the child and keeps
    /// the record. A directory with no record file holds no known child and is
    /// deleted.
    @discardableResult
    static func endRecordedChild(
        pidFile: URL,
        removingOnEnd directory: URL,
        readStart: (Int32) -> String?,
        exists: (Int32) -> Bool,
        send: (Int32, Int32) -> Void,
        waitingMilliseconds: Int32
    ) -> Outcome {
        guard FileManager.default.fileExists(atPath: pidFile.path) else {
            try? FileManager.default.removeItem(at: directory)
            return .ended
        }
        let lines = (try? String(contentsOf: pidFile, encoding: .utf8))
            .map { $0.split(separator: "\n", omittingEmptySubsequences: false).map(String.init) } ?? []
        let pid = lines.first.flatMap { Int32($0.trimmingCharacters(in: .whitespaces)) }
        let start = lines.dropFirst().first?.trimmingCharacters(in: .whitespaces) ?? ""
        guard let pid, !start.isEmpty else {
            let outcome = Outcome.notConfirmed(pid: pid ?? 0, start: start.isEmpty ? nil : start)
            recordIfNotConfirmed(outcome, detail: "its record at \(pidFile.path) could not be read, so no child could be ended; the record was kept")
            return outcome
        }
        let outcome = endRecorded(
            pid: pid, start: start, readStart: readStart, exists: exists,
            send: send, waitingMilliseconds: waitingMilliseconds
        )
        if outcome == .ended {
            try? FileManager.default.removeItem(at: directory)
        } else {
            recordIfNotConfirmed(outcome, detail: "its record at \(pidFile.path) was kept")
        }
        return outcome
    }

    private static func recordIfNotConfirmed(_ outcome: Outcome, detail: String? = nil) {
        guard case .notConfirmed(let pid, let start) = outcome else { return }
        let extra = detail.map { "; \($0)" } ?? ""
        Issue.record("test child \(describe(pid: pid, start: start)) was not confirmed ended, it may still be running\(extra)")
    }
}
