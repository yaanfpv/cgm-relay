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
}

/// RealProcessLauncher starts the engine binary as an ordinary child
/// process, writing its configuration to stdin exactly as the `serve
/// --config-stdin` contract requires (no secret ever goes in an argument
/// or an environment variable), and keeps that pipe open afterward as a
/// lifeline: the engine watches it for EOF, so this app's own end --
/// crash, force quit, or an ordinary stop -- reaches the engine even with
/// no signal delivered at all, since the OS closes every pipe a dead
/// process still held open.
public struct RealProcessLauncher: ProcessLauncher {
    public init() {}

    public func launch(
        executableURL: URL,
        arguments: [String],
        standardInputData: Data,
        onExit: @escaping @Sendable (Int32) -> Void
    ) throws -> any RunningProcess {
        let process = Process()
        process.executableURL = executableURL
        process.arguments = arguments
        process.environment = Self.childEnvironment(from: ProcessInfo.processInfo.environment)

        let inputPipe = Pipe()
        process.standardInput = inputPipe
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

        // The write happens off the calling thread so a stalled or slow
        // child (never expected for a small JSON handshake, but not ruled
        // out) can never block launch() itself. The handle is not closed
        // here: RealProcess.terminate() closes it, tying the pipe's life
        // to the app's own intent to stop the engine rather than to this
        // one write.
        let writeHandle = inputPipe.fileHandleForWriting
        DispatchQueue.global(qos: .utility).async {
            writeHandle.write(standardInputData)
        }

        return RealProcess(process: process, stdinHandle: writeHandle)
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
