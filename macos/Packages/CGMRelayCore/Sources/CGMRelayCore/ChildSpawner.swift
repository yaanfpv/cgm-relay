import Foundation

/// SpawnedChild is a child process started by ChildSpawner and held by it
/// until it has ended. Its only way to be signalled is `signaller`.
final class SpawnedChild: @unchecked Sendable {
    let processIdentifier: pid_t
    let signaller: LaunchedChildSignaller
    private let lock = NSLock()
    private var exited = false

    fileprivate init(processIdentifier: pid_t, signaller: LaunchedChildSignaller) {
        self.processIdentifier = processIdentifier
        self.signaller = signaller
    }

    /// hasExited is true once the child has ended and been reaped.
    var hasExited: Bool { lock.withLock { exited } }

    fileprivate func markExited() { lock.withLock { exited = true } }
}

/// ChildSpawner starts every child this package launches and owns it from
/// birth to reap, which is what lets LaunchedChildSignaller bind a signal to
/// that one child (see its comment). One thread per child waits for the
/// child's exit without reaping it, then reaps it inside the sender's lock
/// with sends refused, and reports the exit. Nothing else reaps or waits for
/// a spawned child: no wait for any child, no change to how SIGCHLD is handled.
enum ChildSpawner {
    /// SpawnError is posix_spawn's own error number, for example ENOENT for a
    /// missing executable or EACCES for one that cannot be run.
    struct SpawnError: Error, Equatable { let code: Int32 }

    /// exitCodeWhenUnknown is reported if the child's exit was never observed
    /// or its status cannot be collected, which only happens if something
    /// else reaped it.
    static let exitCodeWhenUnknown: Int32 = 255

    /// spawn starts executableURL with exactly arguments and environment, its
    /// stdin, stdout and stderr being the given descriptors (or /dev/null for
    /// nil; FileHandle.nullDevice has no descriptor to pass) and every other
    /// descriptor this process has open being closed in the child. The caller
    /// keeps its own copies of the descriptors and closes the child's ends.
    /// onExit gets the exit code, or the negative of the signal number for a
    /// death by signal, from the holder thread once the child has been reaped.
    static func spawn(
        executableURL: URL,
        arguments: [String],
        environment: [String: String],
        standardInput: Int32?,
        standardOutput: Int32?,
        standardError: Int32?,
        onExit: @escaping @Sendable (Int32) -> Void
    ) throws -> SpawnedChild {
        var fileActions: posix_spawn_file_actions_t?
        posix_spawn_file_actions_init(&fileActions)
        defer { posix_spawn_file_actions_destroy(&fileActions) }
        for (descriptor, target) in [(standardInput, Int32(0)), (standardOutput, 1), (standardError, 2)] {
            if let descriptor {
                posix_spawn_file_actions_adddup2(&fileActions, descriptor, target)
            } else {
                posix_spawn_file_actions_addopen(&fileActions, target, "/dev/null", O_RDWR, 0)
            }
        }

        var attributes: posix_spawnattr_t?
        posix_spawnattr_init(&attributes)
        defer { posix_spawnattr_destroy(&attributes) }
        var everySignal = sigset_t()
        sigfillset(&everySignal)
        var noSignal = sigset_t()
        sigemptyset(&noSignal)
        posix_spawnattr_setsigdefault(&attributes, &everySignal)
        posix_spawnattr_setsigmask(&attributes, &noSignal)
        // The child leads a process group of its own, made for it, so a stop
        // reaches what the child starts as well (see LaunchedChildSignaller).
        posix_spawnattr_setpgroup(&attributes, 0)
        posix_spawnattr_setflags(&attributes, Int16(POSIX_SPAWN_CLOEXEC_DEFAULT | POSIX_SPAWN_SETSIGDEF | POSIX_SPAWN_SETSIGMASK | POSIX_SPAWN_SETPGROUP))

        let path = executableURL.path
        let argv = ([path] + arguments).map { strdup($0) } + [nil]
        let envp = environment.map { strdup("\($0.key)=\($0.value)") } + [nil]
        defer {
            argv.forEach { free($0) }
            envp.forEach { free($0) }
        }

        var pid: pid_t = 0
        let status = posix_spawn(&pid, path, &fileActions, &attributes, argv, envp)
        guard status == 0 else { throw SpawnError(code: status) }

        // The child cannot have been reaped: only the holder below reaps it,
        // and it starts after this read.
        let child = SpawnedChild(processIdentifier: pid, signaller: LaunchedChildSignaller(pid: pid))
        let holder = Thread { hold(child, onExit: onExit) }
        holder.name = "child-holder-\(pid)"
        holder.start()
        return child
    }

    /// hold waits for the child's exit without reaping it, refuses further
    /// sends, then reaps.
    private static func hold(_ child: SpawnedChild, onExit: @Sendable (Int32) -> Void) {
        let pid = child.processIdentifier
        var info = siginfo_t()
        var observed: Int32
        // An interrupted wait observed nothing: wait again.
        repeat { observed = waitid(P_PID, id_t(pid), &info, WEXITED | WNOWAIT) } while observed != 0 && errno == EINTR

        guard observed == 0, info.si_pid == pid else {
            // The exit was never observed, so its state is unknown. Nothing is
            // reaped on that, no further signal goes out, and the caller is
            // told the status could not be had.
            child.signaller.markTerminated()
            onExit(exitCodeWhenUnknown)
            return
        }

        let status: Int32? = child.signaller.refuseSendsWhile {
            var status: Int32 = 0
            var reaped: pid_t
            repeat { reaped = waitpid(pid, &status, 0) } while reaped < 0 && errno == EINTR
            return reaped == pid ? status : nil
        }
        child.markExited()
        onExit(status.map(exitCode(fromWaitStatus:)) ?? exitCodeWhenUnknown)
    }

    /// exitCode maps a wait status: the exit code for a normal exit, the
    /// negative of the signal number for a death by signal, so every real
    /// exit code (never negative) stays distinguishable from a signal death.
    static func exitCode(fromWaitStatus status: Int32) -> Int32 {
        let signal = status & 0x7f
        return signal == 0 ? (status >> 8) & 0xff : -signal
    }
}
