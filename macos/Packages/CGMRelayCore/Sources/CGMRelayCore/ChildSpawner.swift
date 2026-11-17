import Foundation

/// SpawnedChild is a child process started by ChildSpawner and held by it
/// until it has ended. Its only way to be signalled is `signaller`.
final class SpawnedChild: @unchecked Sendable {
    let processIdentifier: pid_t
    let signaller: LaunchedChildSignaller
    private let lock = NSLock()
    private var exited = false
    private var reported = false

    fileprivate init(processIdentifier: pid_t, signaller: LaunchedChildSignaller) {
        self.processIdentifier = processIdentifier
        self.signaller = signaller
    }

    /// hasExited is true once the child has ended and been reaped.
    var hasExited: Bool { lock.withLock { exited } }

    /// hasReportedExit is true once the child has been reaped and its exit
    /// handed to onExit, which returned. It is never true before the reap.
    var hasReportedExit: Bool { lock.withLock { reported } }

    fileprivate func markExited() { lock.withLock { exited = true } }
    fileprivate func markReported() { lock.withLock { reported = true } }
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

    /// ReapResult is what one non-blocking reap attempt found.
    private enum ReapResult {
        case reaped(Int32)
        case unavailable
    }

    /// hold waits for the child's exit without reaping it, refuses further
    /// sends, then reaps. A child that is only stopped (or continued) has not
    /// exited: that state is consumed without reaping and the wait goes on.
    private static func hold(_ child: SpawnedChild, onExit: @Sendable (Int32) -> Void) {
        let pid = child.processIdentifier
        while true {
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

            let ended = info.si_code == CLD_EXITED || info.si_code == CLD_KILLED || info.si_code == CLD_DUMPED
            guard ended else {
                // A stop is reported again by every wait until it is consumed.
                // WNOHANG with no WEXITED never reaps.
                var consumed = siginfo_t()
                repeat {
                    observed = waitid(P_PID, id_t(pid), &consumed, WSTOPPED | WCONTINUED | WNOHANG)
                } while observed != 0 && errno == EINTR
                if observed != 0 || consumed.si_pid != pid {
                    // Nothing was consumed, so the next wait would report the
                    // same state at once. Pause so this does not spin.
                    usleep(50_000)
                }
                continue
            }

            // The child has ended and is a zombie, so this reap returns at
            // once and never waits while holding the sender's lock.
            let result: ReapResult? = child.signaller.refuseSendsWhile {
                var status: Int32 = 0
                var reaped: pid_t
                repeat { reaped = waitpid(pid, &status, WNOHANG) } while reaped < 0 && errno == EINTR
                if reaped == pid { return .reaped(status) }
                return reaped == 0 ? nil : .unavailable
            }
            switch result {
            case nil:
                continue
            case .reaped(let status)?:
                child.markExited()
                onExit(exitCode(fromWaitStatus: status))
                child.markReported()
            case .unavailable?:
                child.markExited()
                onExit(exitCodeWhenUnknown)
                child.markReported()
            }
            return
        }
    }

    /// exitCode maps a wait status: the exit code for a normal exit, the
    /// negative of the signal number for a death by signal, so every real
    /// exit code (never negative) stays distinguishable from a signal death.
    static func exitCode(fromWaitStatus status: Int32) -> Int32 {
        // WIFEXITED / WEXITSTATUS and WIFSIGNALED / WTERMSIG as the system
        // header defines them.
        let signal = status & 0x7f
        if signal == 0 { return (status >> 8) & 0xff }
        return -signal
    }
}
