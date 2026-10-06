import Foundation

/// RunningProcess is the subset of a live child process EngineSupervisor
/// needs: enough to terminate it, and to identify it for a caller that
/// wants to prove no engine process is left behind.
public protocol RunningProcess: Sendable {
    var processIdentifier: Int32 { get }
    /// terminate asks the process to exit (SIGTERM), which the engine
    /// treats as a request for a clean shutdown, and closes its stdin
    /// lifeline: either is enough on its own to stop the engine, and
    /// doing both costs nothing.
    func terminate()
    /// waitUntilExit returns true once the process has exited, or false if
    /// it is still running after timeout.
    func waitUntilExit(timeout: Duration) async -> Bool
    /// kill ends the process at once (SIGKILL), for one that ignored
    /// terminate() past its timeout.
    func kill()
}

/// ProcessLauncher starts the engine as a child process. Production code
/// uses RealProcessLauncher, backed by Foundation.Process; tests use a
/// fake that records the launch and lets the test decide when and how the
/// fake process exits.
public protocol ProcessLauncher: Sendable {
    /// launch starts executableURL with arguments, writes
    /// standardInputData to its stdin, and keeps stdin open for as long as
    /// the process runs: it is a lifeline the engine watches for EOF, so
    /// this process's own end -- however it happens -- reaches the engine
    /// even with no signal involved. terminate() on the returned
    /// RunningProcess closes it. onReady is called at most once, when the
    /// process has written its one "ready" line to stdout, which it does
    /// only after its listeners are bound. onExit is called exactly once, whenever
    /// the process terminates for any reason, with its exit code -- or,
    /// if it was killed by a signal rather than exiting on its own, the
    /// negative of that signal number, so a signal number can never be
    /// mistaken for one of the engine's own defined exit codes. The
    /// started process gets an explicit, minimal environment rather than
    /// this app's own: nothing it needs ever arrives that way, since its
    /// whole configuration is exactly standardInputData.
    func launch(
        executableURL: URL,
        arguments: [String],
        standardInputData: Data,
        onReady: @escaping @Sendable () -> Void,
        onExit: @escaping @Sendable (Int32) -> Void
    ) throws -> any RunningProcess
}
