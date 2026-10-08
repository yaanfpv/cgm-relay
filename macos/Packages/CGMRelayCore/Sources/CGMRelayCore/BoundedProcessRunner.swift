import Foundation

/// BoundedProcessResult is the one outcome BoundedProcessRunning reports:
/// the process's own exit code (the negative of the signal number if it
/// died by signal, matching RealProcessLauncher's own convention), or that
/// it never exited within its bound and was terminated, or that it could
/// not even be started.
public enum BoundedProcessResult: Sendable, Equatable {
    case exited(Int32)
    case timedOut
    case failedToLaunch
}

/// BoundedProcessOutput is a bounded run's result together with everything
/// the process wrote to stdout and stderr, for a caller that has to read
/// the process's answer (not only its exit code) and never shows it as is.
public struct BoundedProcessOutput: Sendable, Equatable {
    public var result: BoundedProcessResult
    public var output: Data

    public init(result: BoundedProcessResult, output: Data) {
        self.result = result
        self.output = output
    }
}

/// BoundedProcessRunning runs a short-lived child process to completion:
/// write standardInputData to its stdin, close it, and wait for the
/// process to exit on its own within timeout. Unlike ProcessLauncher,
/// which supervises a process meant to keep running indefinitely, this is
/// for a one-shot command: check-account, or a Tailscale command, whose
/// answer runCapturingOutput also returns.
public protocol BoundedProcessRunning: Sendable {
    func run(
        executableURL: URL,
        arguments: [String],
        standardInputData: Data,
        timeout: Duration
    ) async -> BoundedProcessResult

    /// runCapturingOutput is `run` that also keeps the child's stdout and
    /// stderr, interleaved as written.
    func runCapturingOutput(
        executableURL: URL,
        arguments: [String],
        standardInputData: Data,
        timeout: Duration
    ) async -> BoundedProcessOutput
}

/// RealBoundedProcessRunner runs the process with Foundation.Process,
/// giving it the same minimal, explicit environment RealProcessLauncher
/// gives the supervised engine: a one-shot command needs no more of this
/// app's own environment than the supervised one does. `run` discards the
/// child's stdout and stderr outright; `runCapturingOutput` keeps them for
/// a caller that must read the answer.
public struct RealBoundedProcessRunner: BoundedProcessRunning {
    /// extraEnvironment is added to the minimal child environment, for a
    /// caller whose child needs one variable more than the engine does.
    private let extraEnvironment: [String: String]

    /// terminateGrace is how long a timed-out child gets to exit after
    /// being asked to before it is killed.
    private static let terminateGrace: Duration = .seconds(2)

    public init(extraEnvironment: [String: String] = [:]) {
        self.extraEnvironment = extraEnvironment
    }

    public func run(
        executableURL: URL,
        arguments: [String],
        standardInputData: Data,
        timeout: Duration
    ) async -> BoundedProcessResult {
        await execute(
            executableURL: executableURL,
            arguments: arguments,
            standardInputData: standardInputData,
            timeout: timeout,
            captureOutput: false
        ).result
    }

    public func runCapturingOutput(
        executableURL: URL,
        arguments: [String],
        standardInputData: Data,
        timeout: Duration
    ) async -> BoundedProcessOutput {
        await execute(
            executableURL: executableURL,
            arguments: arguments,
            standardInputData: standardInputData,
            timeout: timeout,
            captureOutput: true
        )
    }

    private func execute(
        executableURL: URL,
        arguments: [String],
        standardInputData: Data,
        timeout: Duration,
        captureOutput: Bool
    ) async -> BoundedProcessOutput {
        let process = Process()
        process.executableURL = executableURL
        process.arguments = arguments
        process.environment = RealProcessLauncher.childEnvironment(from: ProcessInfo.processInfo.environment)
            .merging(extraEnvironment) { _, added in added }
        let outputPipe = captureOutput ? Pipe() : nil
        process.standardOutput = outputPipe ?? FileHandle.nullDevice
        process.standardError = outputPipe ?? FileHandle.nullDevice
        let inputPipe = Pipe()
        process.standardInput = inputPipe
        disableSIGPIPE(for: inputPipe.fileHandleForWriting.fileDescriptor)

        let exitSignal = BoundedProcessExitSignal()
        process.terminationHandler = { finished in
            let exitCode = finished.terminationReason == .uncaughtSignal
                ? -finished.terminationStatus
                : finished.terminationStatus
            Task { await exitSignal.resolve(exitCode) }
        }

        do {
            try process.run()
        } catch {
            return BoundedProcessOutput(result: .failedToLaunch, output: Data())
        }

        // The parent's copy of the write end must close, or the read below
        // never sees end of file after the child exits.
        try? outputPipe?.fileHandleForWriting.close()
        let collectedOutput = outputPipe.map { OutputCollection(reading: $0.fileHandleForReading) }

        let writeHandle = inputPipe.fileHandleForWriting
        do {
            try writeHandle.write(contentsOf: standardInputData)
        } catch {
            // The child exited or closed its stdin before the write
            // landed. disableSIGPIPE above is what keeps this a plain
            // thrown error rather than a fatal signal; the child's own
            // exit is still reported normally below, so nothing further
            // is needed here.
        }
        try? writeHandle.close()

        let result: BoundedProcessResult = await withTaskGroup(of: Int32?.self) { group in
            group.addTask { await exitSignal.wait() }
            group.addTask {
                try? await Task.sleep(for: timeout)
                return nil
            }

            guard let first = await group.next() else {
                return .timedOut
            }
            if let exitCode = first {
                // The process exited first: the sleep task is no longer
                // needed, and cancelling it is safe here since nothing
                // else is still waiting on it.
                group.cancelAll()
                return .exited(exitCode)
            }

            // The timeout fired first. Ask the process to exit, then
            // drain the SAME exit-signal task already in this group --
            // never a second, independent call to exitSignal.wait() --
            // so its one continuation is resumed exactly once rather
            // than being silently replaced and leaked. Its own exit code
            // (ordinarily the negative of SIGTERM's own number, per
            // RealProcessLauncher's convention) is discarded rather than
            // reported as .exited: a caller asked for timeout, not for
            // however this call happened to end the process, and a
            // future change to how it is terminated must never turn
            // .timedOut into .exited under this same test.
            if process.isRunning {
                process.terminate()
            }
            // A child that ignores the request is killed outright after a
            // short grace, so a timed-out run never leaves it running.
            let processID = process.processIdentifier
            let killer = Task {
                try? await Task.sleep(for: Self.terminateGrace)
                if !Task.isCancelled { kill(processID, SIGKILL) }
            }
            _ = await group.next()
            killer.cancel()
            return .timedOut
        }
        return BoundedProcessOutput(result: result, output: await collectedOutput?.data() ?? Data())
    }
}

/// OutputCollection drains a pipe to end of file off the cooperative pool,
/// so a child that writes more than a pipe buffer never blocks on a full
/// pipe while the runner waits for its exit. Once the child is gone,
/// `data()` waits only briefly for the end of file: a descendant that
/// inherited the pipe and outlives it must not hold the caller.
private final class OutputCollection: @unchecked Sendable {
    private static let drainGrace: DispatchTimeInterval = .seconds(2)

    private let done = DispatchSemaphore(value: 0)
    private let lock = NSLock()
    private var collected = Data()

    init(reading handle: FileHandle) {
        DispatchQueue.global().async { [self] in
            while let chunk = try? handle.read(upToCount: 65536), !chunk.isEmpty {
                lock.withLock { collected.append(chunk) }
            }
            done.signal()
        }
    }

    func data() async -> Data {
        await withCheckedContinuation { continuation in
            DispatchQueue.global().async { [self] in
                _ = done.wait(timeout: .now() + Self.drainGrace)
                continuation.resume(returning: lock.withLock { collected })
            }
        }
    }
}

/// BoundedProcessExitSignal lets RealBoundedProcessRunner await a
/// termination handler that fires on an arbitrary thread, resolving once
/// and remembering the result for any later waiter.
private actor BoundedProcessExitSignal {
    private var continuation: CheckedContinuation<Int32, Never>?
    private var result: Int32?

    func resolve(_ code: Int32) {
        result = code
        continuation?.resume(returning: code)
        continuation = nil
    }

    func wait() async -> Int32 {
        if let result { return result }
        return await withCheckedContinuation { continuation = $0 }
    }
}
