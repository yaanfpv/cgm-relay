import Testing
import Foundation

/// ObservedHelper runs a short helper program a test uses to observe
/// something (the process table's start time of a pid, for one) and reads its
/// standard output. The helper is a child like any other: whatever happens, it
/// is ended through the handle that started it and collected before `read`
/// returns, so it can never outlive the call.
///
/// A helper is signalled only on its identity: the start time the kernel shows
/// for its pid is recorded right after the launch and read again just before
/// every signal, and a signal is sent only when both reads agree. A start that
/// cannot be read, or that changed, sends nothing and the helper is reported as
/// not confirmed ended.
///
/// The helper's output is read only after it has exited, so it must write
/// less than a pipe buffer before it does; one that writes more is treated as
/// a helper that did not finish, and is ended.
enum ObservedHelper {
    struct Observation {
        /// The helper's trimmed standard output, only when it exited with
        /// status 0 within the bound.
        let output: String?
        /// The helper's pid, or nil when it could not be started.
        let helperPid: Int32?
        /// True when no helper is left running: its exit was observed, or none
        /// was started. False only when its end could not be confirmed.
        let helperEnded: Bool
    }

    /// `readStart` and `send` are the kernel read and the signal; tests pass
    /// stand-ins to check what is sent when the identity does not hold.
    static func read(
        executable: String,
        arguments: [String],
        waitingMilliseconds: Int32,
        readStart: (Int32) -> String? = { ChildCleanup.launchStart(pid: $0) },
        send: (Int32, Int32) -> Void = { _ = kill($0, $1) }
    ) -> Observation {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: executable)
        process.arguments = arguments
        let pipe = Pipe()
        process.standardOutput = pipe
        process.standardError = FileHandle.nullDevice
        let exited = DispatchSemaphore(value: 0)
        process.terminationHandler = { _ in exited.signal() }
        do {
            try process.run()
        } catch {
            try? pipe.fileHandleForReading.close()
            try? pipe.fileHandleForWriting.close()
            return Observation(output: nil, helperPid: nil, helperEnded: true)
        }
        let pid = process.processIdentifier
        let launchStart = readStart(pid)

        var ended = exited.wait(timeout: .now() + .milliseconds(Int(max(0, waitingMilliseconds)))) == .success
        var output: String?
        if ended {
            if process.terminationReason == .exit, process.terminationStatus == 0 {
                let data = pipe.fileHandleForReading.readDataToEndOfFile()
                output = String(decoding: data, as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines)
            }
        } else {
            ended = end(pid: pid, launchStart: launchStart, exited: exited, readStart: readStart, send: send)
        }
        try? pipe.fileHandleForReading.close()
        return Observation(output: output, helperPid: pid, helperEnded: ended)
    }

    /// end ends a helper that did not finish in time: terminate, then kill if
    /// it is still there, each followed by a wait on its exit event bounded by
    /// the hang ceiling. Before each signal the helper's start is read again and
    /// must equal the one recorded at launch; otherwise nothing is sent and the
    /// end is not confirmed. It says whether the exit was observed.
    private static func end(
        pid: Int32,
        launchStart: String?,
        exited: DispatchSemaphore,
        readStart: (Int32) -> String?,
        send: (Int32, Int32) -> Void
    ) -> Bool {
        let bound = Int(TestChild.hangCeilingMilliseconds)
        func signalIfSame(_ signal: Int32) -> Bool {
            guard let launchStart, readStart(pid) == launchStart else { return false }
            send(pid, signal)
            return true
        }
        guard signalIfSame(SIGTERM) else { return false }
        if exited.wait(timeout: .now() + .milliseconds(bound)) == .success { return true }
        guard signalIfSame(SIGKILL) else { return false }
        return exited.wait(timeout: .now() + .milliseconds(bound)) == .success
    }
}
