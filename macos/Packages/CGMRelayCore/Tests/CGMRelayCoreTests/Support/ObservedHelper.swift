import Testing
import Foundation

/// ObservedHelper runs a short helper program a test uses to observe
/// something (the process table's start time of a pid, for one) and reads its
/// standard output. The helper is a child like any other: whatever happens, it
/// is ended through the handle that started it and collected before `read`
/// returns, so it can never outlive the call.
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

    static func read(executable: String, arguments: [String], waitingMilliseconds: Int32) -> Observation {
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

        var ended = exited.wait(timeout: .now() + .milliseconds(Int(max(0, waitingMilliseconds)))) == .success
        var output: String?
        if ended {
            if process.terminationReason == .exit, process.terminationStatus == 0 {
                let data = pipe.fileHandleForReading.readDataToEndOfFile()
                output = String(decoding: data, as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines)
            }
        } else {
            ended = end(process, exited: exited)
        }
        try? pipe.fileHandleForReading.close()
        return Observation(output: output, helperPid: pid, helperEnded: ended)
    }

    /// end ends a helper that did not finish in time, through its own handle:
    /// terminate, then kill if it is still running, each followed by a wait on
    /// its exit event bounded by the hang ceiling. It says whether the exit was
    /// observed.
    private static func end(_ process: Process, exited: DispatchSemaphore) -> Bool {
        let bound = Int(TestChild.hangCeilingMilliseconds)
        if process.isRunning { process.terminate() }
        if exited.wait(timeout: .now() + .milliseconds(bound)) == .success { return true }
        if process.isRunning { kill(process.processIdentifier, SIGKILL) }
        return exited.wait(timeout: .now() + .milliseconds(bound)) == .success
    }
}
