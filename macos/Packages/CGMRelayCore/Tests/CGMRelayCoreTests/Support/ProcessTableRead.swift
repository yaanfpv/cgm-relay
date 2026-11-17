import Testing
import Foundation
@testable import CGMRelayCore

/// TableRead is what a read of one process's table record came back with. The
/// product's reader returns nil for every case but the first; a test that must
/// tell "there is no such process" from "the read failed" uses this one.
enum TableRead: Equatable {
    /// the full record.
    case present(ProcessRecord)
    /// the kernel said there is no such process (ESRCH): none, or an exited
    /// child not yet reaped, read with arg 0.
    case absent
    /// any other failure or a short read; carries the errno the thread held.
    case unreadable(Int32)
}

/// ProcPidInfo has proc_pidinfo(pid, PROC_PIDTBSDINFO, 0, buffer, size)'s
/// shape. libproc returns 0 for a failed call and sets errno only then.
typealias ProcPidInfo = @Sendable (_ pid: pid_t, _ buffer: UnsafeMutableRawPointer, _ byteCount: Int32) -> Int32

let systemProcPidInfo: ProcPidInfo = { pid, buffer, byteCount in
    proc_pidinfo(pid, PROC_PIDTBSDINFO, 0, buffer, byteCount)
}

/// readProcessTable reads pid's record and says which of three things came
/// back. errno is cleared first, since libproc returns 0 for a failed call
/// without touching errno otherwise: a record is present only when the call
/// returns the full size of proc_bsdinfo; absent only for a 0 with ESRCH; every
/// other result (another errno, a short count, a 0 that set none) is unreadable.
/// For PROC_PIDTBSDINFO bsd/kern/proc_info.c (apple-oss-distributions/xnu) gives
/// ESRCH when no process has the pid, and, with arg 0, for an exited child not
/// yet reaped; the result is otherwise the size or an error, never a short count.
func readProcessTable(_ pid: pid_t, pidInfo: ProcPidInfo = systemProcPidInfo) -> TableRead {
    var info = proc_bsdinfo()
    let size = Int32(MemoryLayout<proc_bsdinfo>.size)
    errno = 0
    let returned = withUnsafeMutableBytes(of: &info) { pidInfo(pid, $0.baseAddress!, size) }
    let code = errno
    if returned == size {
        return .present(ProcessRecord(
            pid: pid_t(info.pbi_pid),
            parentPID: pid_t(info.pbi_ppid),
            start: ProcessStart(seconds: Int(info.pbi_start_tvsec), microseconds: Int(info.pbi_start_tvusec))
        ))
    }
    if returned == 0 && code == ESRCH { return .absent }
    return .unreadable(code)
}

/// DescendantCheck decides whether a process that was seen alive is gone, from
/// reads that can fail.
enum DescendantCheck {
    enum Verdict: Equatable { case stillThere, gone, unreadable(Int32) }

    /// verdict says what one read shows about the process that had `start`:
    /// still there with the same start, gone when there is none or another
    /// start (the number was handed on), and unreadable when the read failed,
    /// which is never gone.
    static func verdict(_ read: TableRead, of start: ProcessStart) -> Verdict {
        switch read {
        case .present(let record): return record.start == start ? .stillThere : .gone
        case .absent: return .gone
        case .unreadable(let code): return .unreadable(code)
        }
    }

    /// requireGone polls `read` until the process with `start` is gone, for at
    /// most `milliseconds`. It returns true only for gone. The first unreadable
    /// read ends the check, without reading again, and records a failure naming
    /// the pid and the errno. The wait is on the process's own end, which no
    /// event reports to the caller, so it polls.
    @discardableResult
    static func requireGone(pid: pid_t, start: ProcessStart, read: (pid_t) -> TableRead, milliseconds: Int32 = TestChild.hangCeilingMilliseconds) -> Bool {
        let deadline = ContinuousClock.now + .milliseconds(Int(milliseconds))
        while true {
            switch verdict(read(pid), of: start) {
            case .gone: return true
            case .unreadable(let code):
                Issue.record("the record of process \(pid) could not be read (errno \(code)), so it was not counted as ended")
                return false
            case .stillThere:
                guard ContinuousClock.now < deadline else { return false }
                usleep(10_000)
            }
        }
    }
}
