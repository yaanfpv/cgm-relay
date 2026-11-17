import Testing
import Foundation
@testable import CGMRelayCore

/// ObservedHelper runs a short helper program a test uses to observe
/// something (the process table's start time of a pid, for one) and reads its
/// standard output.
///
/// The helper is started through ChildSpawner, which holds it from birth: its
/// start time is read before the holder thread that reaps it exists, and every
/// signal goes through that held signaller, which sends only while the helper
/// is unreaped and its start still matches. A signal is never sent to a bare
/// number.
///
/// What holds when `read` returns:
/// - `helperEnded` is true only when the helper's reap was confirmed (the
///   holder reaped it and finished reporting), or when no helper was started.
/// - `helperEnded` false means the end was not confirmed: the helper may still
///   be running. It is then named by `helperPid` and `birthStart`, and
///   `helper` holds it so the caller can end it through the same handle. A
///   caller must treat that as a failure, never as an empty answer.
///
/// The helper's output is read only after it has been reaped, so it must write
/// less than a pipe buffer before it exits; one that writes more does not
/// finish, and goes down the unconfirmed path above.
enum ObservedHelper {
    struct Observation {
        /// The helper's trimmed standard output, only when it exited with
        /// status 0 and its reap was confirmed within the bound.
        let output: String?
        /// The helper's pid, or nil when it could not be started.
        let helperPid: Int32?
        /// The start time the process table showed when the helper was born.
        let birthStart: String?
        /// True when no helper is known to be left: its reap was confirmed, or
        /// none was started.
        let helperEnded: Bool
        /// The held helper, nil when none was started.
        let helper: HeldChild?

        /// failIfNotEnded fails the test, naming the helper by pid and birth
        /// start, when its end was not confirmed. A caller that uses the output
        /// calls it first, so an unresolved helper is never read as "no answer".
        func failIfNotEnded() {
            guard !helperEnded else { return }
            Issue.record("observing helper \(ChildCleanup.describe(pid: helperPid ?? 0, start: birthStart)) was not confirmed ended, it may still be running")
        }
    }

    /// `readProcessTable` is the read the helper's signaller binds its
    /// identity with; tests pass one that shows a replacement or nothing, to
    /// check that no signal is sent on an identity that does not hold.
    static func read(
        executable: String,
        arguments: [String],
        waitingMilliseconds: Int32,
        readProcessTable: @escaping LaunchedChildSignaller.ProcessTableReader = LaunchedChildSignaller.systemProcessTable
    ) -> Observation {
        let pipe = Pipe()
        let helper: HeldChild
        do {
            helper = try HeldChild.start(
                executable: executable, arguments: arguments,
                standardOutput: pipe.fileHandleForWriting.fileDescriptor,
                readProcessTable: readProcessTable
            )
        } catch {
            try? pipe.fileHandleForReading.close()
            try? pipe.fileHandleForWriting.close()
            return Observation(output: nil, helperPid: nil, birthStart: nil, helperEnded: true, helper: nil)
        }
        // The helper has its own copy; this one must close for the read to see its end.
        try? pipe.fileHandleForWriting.close()

        var ended = helper.waitReaped(milliseconds: waitingMilliseconds)
        var output: String?
        if ended {
            if helper.watch.reported == [0] {
                let data = pipe.fileHandleForReading.readDataToEndOfFile()
                output = String(decoding: data, as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines)
            }
        } else {
            // Not finished in time: TERM, then KILL, each only through the held
            // signaller. A refused send, or a reap not seen, leaves it unconfirmed.
            ended = helper.end(signals: [SIGTERM, SIGKILL]) == .ended
        }
        try? pipe.fileHandleForReading.close()
        return Observation(
            output: output, helperPid: helper.processIdentifier, birthStart: helper.birthStart,
            helperEnded: ended, helper: helper
        )
    }
}
