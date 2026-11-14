import Foundation

/// ProcessStart is the moment a process started, at microsecond
/// resolution, as the process table records it.
struct ProcessStart: Equatable, Sendable {
    let seconds: Int
    let microseconds: Int
}

/// ProcessRecord is what the process table says about one process: its pid,
/// its parent's pid and when it started.
struct ProcessRecord: Equatable, Sendable {
    let pid: pid_t
    let parentPID: pid_t
    let start: ProcessStart
}

/// LaunchedChildSignaller is the one place this package sends a signal to a
/// child it launched. A bare pid says nothing about who holds the number: once
/// a child has been reaped the system may hand its number to an unrelated
/// process, and a signal sent late would end that process instead.
///
/// The binding is by construction. ChildSpawner starts the child itself,
/// builds this sender before its holder thread can reap, and reads the child's
/// record (pid, parent, start time) while the child is necessarily unreaped,
/// so the record cannot belong to a replacement. The holder observes the
/// child's exit without reaping it, then reaps inside refuseSendsWhile: under
/// the lock every send takes, after setting the mark. So every kill this
/// sender makes lands before the reap, while the child's number is still
/// reserved to it, and a send requested earlier but not yet run is refused
/// once the reap is done. A held child therefore has no gap between the check
/// and the send.
///
/// The child leads its own process group (ChildSpawner), and a send goes to
/// that group, never to a bare pid: kill(-pid), only while the leader is
/// unreaped. It signals the members the group has at that moment; a member
/// that left the group (setsid, setpgid) is not reached, and none is signalled
/// once the leader's exit has been observed.
///
/// Two refusals sit on top of that. A record is accepted at launch only when
/// it is for this pid and names ownParentPID as the parent; otherwise no
/// identity is stored and every send is refused. And before each send a fresh
/// read must still show the same pid and start time, which is a second check,
/// not the one the guarantee rests on. A read that cannot be made counts as a
/// refusal.
///
/// A sender built over a pid this process does not hold (as the tests do for
/// a scripted process table) has the ordinary gap that no kernel call closes:
/// a process that ends and has its number reused between the comparison and
/// the kill can still be signalled.
final class LaunchedChildSignaller: @unchecked Sendable {
    /// ProcessTableReader returns the process table's record for a pid, or
    /// nil when there is none or it cannot be read in full.
    typealias ProcessTableReader = @Sendable (pid_t) -> ProcessRecord?

    private let lock = NSLock()
    private let launched: ProcessRecord?
    private let readProcessTable: ProcessTableReader
    private var terminated = false

    /// init records the identity of the child with this pid, read now.
    /// readProcessTable defaults to the system's process table.
    init(
        pid: pid_t,
        ownParentPID: pid_t = getpid(),
        readProcessTable: @escaping ProcessTableReader = LaunchedChildSignaller.systemProcessTable
    ) {
        self.readProcessTable = readProcessTable
        if let record = readProcessTable(pid), record.pid == pid, record.parentPID == ownParentPID {
            launched = record
        } else {
            launched = nil
        }
    }

    /// markTerminated refuses every later send. It returns only once a send
    /// already in progress has finished.
    func markTerminated() {
        lock.withLock { terminated = true }
    }

    /// refuseSendsWhile refuses every later send and runs body, the reap,
    /// while holding the lock every send takes. A send that was waiting
    /// before the reap therefore finds the mark when it gets the lock and
    /// sends nothing; none can run during or after the reap.
    func refuseSendsWhile<T>(_ body: () -> T) -> T {
        lock.withLock {
            terminated = true
            return body()
        }
    }

    /// send delivers signal to the child's process group, which the child
    /// leads, so what the child started is signalled too, and returns true
    /// only when kill returned 0. The group's number is the child's pid, kept
    /// while the child is unreaped, and is never 0, 1 or negative. It returns
    /// false, having sent nothing, when the child's exit has been observed,
    /// when no identity was accepted at launch, when the system has no record
    /// of the pid, or when the pid now belongs to a process with a different
    /// start time.
    @discardableResult
    func send(_ signal: Int32) -> Bool {
        lock.withLock {
            guard !terminated, let launched, launched.pid > 1,
                  let current = readProcessTable(launched.pid),
                  current.pid == launched.pid, current.start == launched.start
            else { return false }
            return kill(-launched.pid, signal) == 0
        }
    }

    /// systemProcessTable reads pid's record from the system, or returns nil
    /// when there is none. A process that has exited but is not yet reaped
    /// has none either.
    static let systemProcessTable: ProcessTableReader = { pid in
        var info = proc_bsdinfo()
        let size = Int32(MemoryLayout<proc_bsdinfo>.size)
        guard proc_pidinfo(pid, PROC_PIDTBSDINFO, 0, &info, size) == size else { return nil }
        return ProcessRecord(
            pid: pid_t(info.pbi_pid),
            parentPID: pid_t(info.pbi_ppid),
            start: ProcessStart(seconds: Int(info.pbi_start_tvsec), microseconds: Int(info.pbi_start_tvusec))
        )
    }
}
