import Foundation

/// RealProcess wraps a live spawned child and the write end of its stdin
/// lifeline pipe. EngineSupervisor only ever sees it through the
/// RunningProcess protocol. Every write to the pipe and its close run one at
/// a time on stdinQueue, and the lock orders sendInput against terminate(),
/// so a write never reaches a handle that is already closed. The remaining
/// state is immutable, which is what makes the @unchecked Sendable below
/// safe.
final class RealProcess: RunningProcess, @unchecked Sendable {
    private let child: SpawnedChild
    private let stdinHandle: FileHandle
    private let stdinQueue = DispatchQueue(label: "cgmrelay.process.stdin", qos: .utility)
    private let lock = NSLock()
    private var stdinClosed = false

    init(child: SpawnedChild, stdinHandle: FileHandle) {
        self.child = child
        self.stdinHandle = stdinHandle
    }

    /// sendInput queues data to be written to the child's stdin and returns
    /// at once, so a stalled child never blocks the caller. Input sent after
    /// terminate() is dropped. A write the child can no longer take (it
    /// exited or closed its stdin) fails as an ordinary thrown error, since
    /// launch() turns SIGPIPE off for this pipe; the error is ignored: the
    /// child's own exit is reported by its holder. The flag is checked and
    /// the write queued under one lock hold, so terminate() cannot queue its
    /// close between them.
    func sendInput(_ data: Data) {
        lock.withLock {
            guard !stdinClosed else { return }
            stdinQueue.async { [stdinHandle] in
                try? stdinHandle.write(contentsOf: data)
            }
        }
    }

    var processIdentifier: Int32 { child.processIdentifier }

    /// terminate signals the child at once and never waits on a write. The
    /// close is queued behind any input already accepted, so it can never
    /// land under a running write.
    func terminate() {
        lock.withLock {
            guard !stdinClosed else { return }
            stdinClosed = true
            stdinQueue.async { [stdinHandle] in
                try? stdinHandle.close()
            }
        }
        child.signaller.send(SIGTERM)
    }

    /// waitUntilExit returns true only once the child has been reaped and its
    /// exit reported (the holder reports after the reap, under its lock), so
    /// a caller that sees true can rely on both.
    func waitUntilExit(timeout: Duration) async -> Bool {
        let deadline = ContinuousClock.now + timeout
        while !child.hasReportedExit {
            if ContinuousClock.now >= deadline { return false }
            do {
                try await Task.sleep(for: .milliseconds(25))
            } catch {
                return child.hasReportedExit
            }
        }
        return true
    }

    func kill() {
        child.signaller.send(SIGKILL)
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
        let inputPipe = Pipe()
        let errorPipe = Pipe()
        let outputPipe = Pipe()
        disableSIGPIPE(for: inputPipe.fileHandleForWriting.fileDescriptor)

        // onExit gets every real exit code unchanged and a death by signal as
        // the negative of the signal number (see ChildSpawner.exitCode), so a
        // death by signal 3 never reads as
        // EngineSupervisor.storeKeyMismatchExitCode.
        let child = try ChildSpawner.spawn(
            executableURL: executableURL,
            arguments: arguments,
            environment: Self.childEnvironment(from: ProcessInfo.processInfo.environment),
            standardInput: inputPipe.fileHandleForReading.fileDescriptor,
            standardOutput: outputPipe.fileHandleForWriting.fileDescriptor,
            standardError: errorPipe.fileHandleForWriting.fileDescriptor,
            onExit: onExit
        )
        try? inputPipe.fileHandleForReading.close()

        // This end must close here, or the forwarder never sees EOF once
        // the engine exits, since the parent would still hold a writer.
        try? errorPipe.fileHandleForWriting.close()
        EngineLogForwarder.forward(from: errorPipe.fileHandleForReading, to: engineLog)
        try? outputPipe.fileHandleForWriting.close()
        Self.watchForReady(on: outputPipe.fileHandleForReading, onReady: onReady)

        // The input is sent off the calling thread so a stalled child can
        // never block launch() itself. The handle stays open here:
        // RealProcess.terminate() closes it, tying the pipe's life to the
        // app's own intent to stop the engine rather than to this write.
        let process = RealProcess(child: child, stdinHandle: inputPipe.fileHandleForWriting)
        process.sendInput(standardInputData)
        return process
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
