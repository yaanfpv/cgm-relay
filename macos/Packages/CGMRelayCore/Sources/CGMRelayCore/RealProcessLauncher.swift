import Foundation

/// RealProcess wraps a live Foundation.Process and the write end of its
/// stdin lifeline pipe. Access to both is never shared outside this file:
/// EngineSupervisor only ever sees it through the RunningProcess protocol,
/// so the @unchecked Sendable below is safe -- nothing here reads or
/// writes this state from more than one place at a time.
final class RealProcess: RunningProcess, @unchecked Sendable {
    private let process: Process
    private let stdinHandle: FileHandle

    init(process: Process, stdinHandle: FileHandle) {
        self.process = process
        self.stdinHandle = stdinHandle
    }

    var processIdentifier: Int32 { process.processIdentifier }

    func terminate() {
        try? stdinHandle.close()
        process.terminate()
    }

    func waitUntilExit(timeout: Duration) async -> Bool {
        let deadline = ContinuousClock.now + timeout
        while process.isRunning {
            if ContinuousClock.now >= deadline { return false }
            try? await Task.sleep(for: .milliseconds(25))
        }
        return true
    }

    func kill() {
        Foundation.kill(process.processIdentifier, SIGKILL)
    }
}

/// ReadyLineScanner finds the engine's one "ready" line in its stdout. Any
/// other line, and any line too long to be it, is ignored, and it reports
/// the line at most once.
struct ReadyLineScanner {
    static let readyLine = Data("ready".utf8)

    private var pending = Data()
    private var overflowed = false
    private var found = false

    /// append returns true exactly once: when the chunk completes the ready
    /// line.
    mutating func append(_ chunk: Data) -> Bool {
        for byte in chunk {
            if byte == UInt8(ascii: "\n") {
                let isReady = !overflowed && pending == Self.readyLine
                pending.removeAll(keepingCapacity: true)
                overflowed = false
                if isReady && !found {
                    found = true
                    return true
                }
            } else if pending.count < Self.readyLine.count {
                pending.append(byte)
            } else {
                overflowed = true
            }
        }
        return false
    }
}

/// RealProcessLauncher starts the engine binary as an ordinary child
/// process, writing its configuration to stdin exactly as the `serve
/// --config-stdin` contract requires (no secret ever goes in an argument
/// or an environment variable), and keeps that pipe open afterward as a
/// lifeline: the engine watches it for EOF, so this app's own end --
/// crash, force quit, or an ordinary stop -- reaches the engine even with
/// no signal delivered at all, since the OS closes every pipe a dead
/// process still held open. The engine's stderr, where it writes its log
/// lines, is read line by line and handed to engineLog, by default the
/// system log (subsystem com.yaanfpv.cgmrelay, category engine). Its stdout
/// carries only the "ready" line, which is passed to onReady; the rest is
/// read and dropped so the pipe can never fill and block the engine.
public struct RealProcessLauncher: ProcessLauncher {
    private let engineLog: EngineLogSink

    public init(engineLog: @escaping EngineLogSink = EngineLogForwarder.unifiedLog) {
        self.engineLog = engineLog
    }

    public func launch(
        executableURL: URL,
        arguments: [String],
        standardInputData: Data,
        onReady: @escaping @Sendable () -> Void,
        onExit: @escaping @Sendable (Int32) -> Void
    ) throws -> any RunningProcess {
        let process = Process()
        process.executableURL = executableURL
        process.arguments = arguments
        process.environment = Self.childEnvironment(from: ProcessInfo.processInfo.environment)

        let inputPipe = Pipe()
        process.standardInput = inputPipe
        let errorPipe = Pipe()
        process.standardError = errorPipe
        let outputPipe = Pipe()
        process.standardOutput = outputPipe
        disableSIGPIPE(for: inputPipe.fileHandleForWriting.fileDescriptor)
        process.terminationHandler = { finished in
            // terminationStatus is the SIGNAL number, not an exit code,
            // when terminationReason is .uncaughtSignal -- reporting it
            // unchanged would let a death by signal 3 read as
            // EngineSupervisor.storeKeyMismatchExitCode. Negating it
            // keeps every real exit code (always >= 0) distinguishable
            // from every signal death (always reported as <= 0 here).
            let exitCode = finished.terminationReason == .uncaughtSignal
                ? -finished.terminationStatus
                : finished.terminationStatus
            onExit(exitCode)
        }

        try process.run()

        // This end must close here, or the forwarder never sees EOF once
        // the engine exits, since the parent would still hold a writer.
        try? errorPipe.fileHandleForWriting.close()
        EngineLogForwarder.forward(from: errorPipe.fileHandleForReading, to: engineLog)
        try? outputPipe.fileHandleForWriting.close()
        Self.watchForReady(on: outputPipe.fileHandleForReading, onReady: onReady)

        // The write happens off the calling thread so a stalled or slow
        // child (never expected for a small JSON handshake, but not ruled
        // out) can never block launch() itself. The handle is not closed
        // here: RealProcess.terminate() closes it, tying the pipe's life
        // to the app's own intent to stop the engine rather than to this
        // one write.
        let writeHandle = inputPipe.fileHandleForWriting
        DispatchQueue.global(qos: .utility).async {
            do {
                try writeHandle.write(contentsOf: standardInputData)
            } catch {
                // The child exited or closed its stdin before the write
                // landed. disableSIGPIPE above is what keeps this a
                // plain thrown error rather than a fatal signal; the
                // child's own exit still reaches onExit normally through
                // terminationHandler, so nothing further is needed here.
            }
        }

        return RealProcess(process: process, stdinHandle: writeHandle)
    }

    /// watchForReady reads handle until its writer closes it, calling onReady
    /// when the ready line arrives, and always drains the pipe.
    private static func watchForReady(on handle: FileHandle, onReady: @escaping @Sendable () -> Void) {
        DispatchQueue.global(qos: .utility).async {
            var scanner = ReadyLineScanner()
            var buffer = [UInt8](repeating: 0, count: 4096)
            while true {
                let count = read(handle.fileDescriptor, &buffer, buffer.count)
                if count < 0 && errno == EINTR { continue }
                guard count > 0 else { break }
                if scanner.append(Data(buffer[..<count])) { onReady() }
            }
            try? handle.close()
        }
    }

    /// passthroughVariableNames names every variable childEnvironment
    /// copies from this process's own environment when present there,
    /// rather than fixing a value for it the way PATH gets one: HOME,
    /// TMPDIR, USER and LOGNAME are ordinary process identity, and the
    /// engine's whole configuration -- the LibreLinkUp account, the
    /// bearer token, the store's encryption key -- arrives on its stdin
    /// instead, so nothing here needs any of the caller's own secrets to
    /// do its job.
    static let passthroughVariableNames = ["HOME", "TMPDIR", "USER", "LOGNAME"]

    /// proxyVariableNames names the one deliberate exception:
    /// upper- and lowercase HTTP_PROXY/HTTPS_PROXY/NO_PROXY, passed
    /// through only when this process has them set, because the engine's
    /// own outbound requests honour them. A proxy URL can itself carry a
    /// credential, so this is a real trade-off, made once here rather
    /// than somewhere less visible.
    static let proxyVariableNames = [
        "HTTP_PROXY", "HTTPS_PROXY", "NO_PROXY",
        "http_proxy", "https_proxy", "no_proxy",
    ]

    /// childEnvironment builds the only environment the engine child
    /// process ever sees: an explicit, small allowlist, never this
    /// process's whole environment. Foundation.Process inherits the
    /// caller's complete environment when left unset, which is how the
    /// engine used to end up carrying whatever this app process happened
    /// to have -- every value the caller passes here is examined by name
    /// only, never printed or logged.
    static func childEnvironment(from callerEnvironment: [String: String]) -> [String: String] {
        var result: [String: String] = ["PATH": "/usr/bin:/bin:/usr/sbin:/sbin"]
        for name in passthroughVariableNames + proxyVariableNames {
            if let value = callerEnvironment[name] {
                result[name] = value
            }
        }
        return result
    }
}
