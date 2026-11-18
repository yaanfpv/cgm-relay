import Foundation

/// ProcessExitCode names the one value onExit can carry that is not an exit.
public enum ProcessExitCode {
    /// statusUnknown is reported instead of an exit code when the child's exit
    /// could not be observed, so the child may still be running. No exit
    /// status (0 to 255) and no negated signal number can equal it.
    public static let statusUnknown = Int32.min
}

/// RunningProcess is the subset of a live child process EngineSupervisor
/// needs: enough to terminate it, and to identify it for a caller that
/// wants to prove no engine process is left behind.
public protocol RunningProcess: Sendable {
    var processIdentifier: Int32 { get }
    /// terminate asks the process to exit (SIGTERM), which the engine
    /// treats as a request for a clean shutdown, and closes its stdin
    /// lifeline: either is enough on its own to stop the engine, and
    /// doing both costs nothing. It never waits for input still being
    /// written, and input not yet written when it is called is still
    /// delivered before the close; none is written after it.
    func terminate()
    /// waitUntilExit returns true once the process has exited, or false if
    /// it is still running after timeout.
    func waitUntilExit(timeout: Duration) async -> Bool
    /// kill ends the process at once (SIGKILL), for one that ignored
    /// terminate() past its timeout.
    func kill()
}

/// ProcessLauncher starts the engine as a child process. Production code
/// uses RealProcessLauncher, which starts the child through ChildSpawner; tests use a
/// fake that records the launch and lets the test decide when and how the
/// fake process exits.
public protocol ProcessLauncher: Sendable {
    /// launch starts executableURL with arguments, writes
    /// standardInputData to its stdin (in the background, so it may still be
    /// in flight when launch returns), and keeps stdin open for as long as
    /// the process runs: it is a lifeline the engine watches for EOF, so
    /// this process's own end -- however it happens -- reaches the engine
    /// even with no signal involved. terminate() on the returned
    /// RunningProcess closes it. onReady is called at most once, when the
    /// process has written its one "ready" line to stdout, which it does
    /// only after its listeners are bound. onExit is called exactly once, whenever
    /// the process terminates for any reason, with its exit code -- or,
    /// if it was killed by a signal rather than exiting on its own, the
    /// negative of that signal number, so a signal number can never be
    /// mistaken for one of the engine's own defined exit codes. If the exit
    /// could not be observed, it is called with
    /// ProcessExitCode.statusUnknown instead. The
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
