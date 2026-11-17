import Testing
import Foundation

/// ChildSurvivors names the direct children of this process that a group of
/// suites started and left alive. It reads them from the kernel. A child that
/// ended and was collected is not in the list; one that is still there, or
/// ended but was never collected, is. A process a child started and left
/// behind is not a child of this one, so it is not seen here.
/// Census is what a read of a parent's children came back with: the pids, or
/// the errno of a read that failed. A failed read is not an empty list.
enum Census: Equatable, Sendable {
    case listed([pid_t])
    case failed(Int32)
}

enum ChildSurvivors {
    struct Child: Equatable, Sendable {
        let pid: Int32
        /// The start time the process table shows for the child, as text, or
        /// nil when it cannot be read (a child that ended but was not collected).
        let start: String?
    }

    /// ListPids has proc_listpids's own shape. libproc returns 0 both for an
    /// empty list and for a call the kernel refused, and sets errno only for
    /// the refusal, so a reader of it must clear errno first and look at it
    /// after a 0.
    typealias ListPids = @Sendable (_ type: UInt32, _ typeinfo: UInt32, _ buffer: UnsafeMutableRawPointer?, _ byteCount: Int32) -> Int32

    /// The kernel's own list, through libproc.
    static let systemListPids: ListPids = { type, typeinfo, buffer, byteCount in
        proc_listpids(type, typeinfo, buffer, byteCount)
    }

    /// census lists the direct children of `parent` as the kernel reports them,
    /// or says the read failed, with the errno it failed with. It never turns a
    /// failure into an empty list.
    ///
    /// What the kernel does with a buffer that is too small, read from
    /// bsd/kern/proc_info.c in apple-oss-distributions/xnu (main branch, file
    /// sha256 557092f14fbad3341100f59e0391d2e812c54b79a7404c89b2af97471ad67082,
    /// read on 17 November 2026; the branch may differ from the macOS in use):
    /// a call with no buffer is a size query that answers with
    /// `*retval = ((nprocs + 20) * sizeof(int));` and returns 0. With a buffer,
    /// the number of pids it will return is capped at the room given:
    /// `wantpids = buffersize / sizeof(int);` then `if (numprocs > wantpids) {`
    /// sets `numprocs = wantpids;`. The walk of the process list stops at
    /// `if (n >= numprocs) {`, so a list longer than the buffer is cut short
    /// with no error, and the result is `*retval = (n * sizeof(int));`: a full
    /// buffer is the only sign that more may exist. A buffer smaller than one
    /// int is ENOMEM. So: read again with a larger buffer whenever the result
    /// fills the one given. libproc.c (libsyscall/wrappers/libproc, same
    /// branch) returns 0 where the system call returned -1, so errno, cleared
    /// before each call, is the only channel for a failure.
    static func census(parent: pid_t, listPids: ListPids = systemListPids) -> Census {
        let width = MemoryLayout<pid_t>.size
        let type = UInt32(PROC_PPID_ONLY)
        let typeinfo = UInt32(bitPattern: Int32(parent))

        errno = 0
        let sized = listPids(type, typeinfo, nil, 0)
        if sized < 0 || (sized == 0 && errno != 0) { return .failed(errno) }
        var capacity = max(64, Int(sized) / width)
        while true {
            var pids = [pid_t](repeating: 0, count: capacity)
            errno = 0
            let bytes = pids.withUnsafeMutableBytes { listPids(type, typeinfo, $0.baseAddress, Int32($0.count)) }
            if bytes < 0 || (bytes == 0 && errno != 0) { return .failed(errno) }
            let count = Int(bytes) / width
            if count >= capacity {
                capacity *= 2
                continue
            }
            return .listed(pids.prefix(count).filter { $0 > 0 })
        }
    }

    private static func startText(pid: Int32) -> String? {
        var info = proc_bsdinfo()
        let size = Int32(MemoryLayout<proc_bsdinfo>.size)
        guard proc_pidinfo(pid, PROC_PIDTBSDINFO, 0, &info, size) == size else { return nil }
        return "\(info.pbi_start_tvsec).\(info.pbi_start_tvusec)"
    }

    /// new lists the children in `now` that were not in `before`. The same
    /// number with another start time is another process.
    static func new(since before: [Child], now: [Child]) -> [Child] {
        now.filter { !before.contains($0) }
    }

    /// recordSurvivors fails the test once per survivor, naming its pid and start.
    static func recordSurvivors(_ survivors: [Child]) {
        for survivor in survivors {
            Issue.record("test child \(ChildCleanup.describe(pid: survivor.pid, start: survivor.start)) was left alive when the suites ended")
        }
    }

    /// Accounting counts the suites that are running at once. The first to
    /// enter takes the census every later one is measured against, and the
    /// last to exit gets the children new since then, so suites that run side
    /// by side never see each other's children as survivors.
    final class Accounting: @unchecked Sendable {
        private let census: @Sendable () -> Census
        private let lock = NSLock()
        private var active = 0
        private var baseline: [Child]?

        init(census: @escaping @Sendable () -> Census) {
            self.census = census
        }

        private static func children(_ pids: [pid_t]) -> [Child] {
            pids.map { Child(pid: $0, start: ChildSurvivors.startText(pid: $0)) }
        }

        /// enter takes the baseline when it is the first. A baseline that could
        /// not be read fails the test naming the read, and leaves the suites
        /// with no baseline, so the exit does not blame them for children that
        /// were already there.
        func enter() {
            lock.withLock {
                if active == 0 {
                    switch census() {
                    case .listed(let pids):
                        baseline = Self.children(pids)
                    case .failed(let code):
                        baseline = nil
                        Issue.record("the census of this process's children at the start could not be read (errno \(code)), so survivors could not be counted")
                    }
                }
                active += 1
            }
        }

        /// exit returns the survivors when this is the last exit, and an empty
        /// list otherwise. A census at the last exit that could not be read
        /// fails the test naming the read; it is never reported as no survivors.
        func exit() -> [Child] {
            lock.withLock {
                active = max(0, active - 1)
                guard active == 0 else { return [] }
                switch census() {
                case .listed(let pids):
                    guard let baseline else { return [] }
                    return ChildSurvivors.new(since: baseline, now: Self.children(pids))
                case .failed(let code):
                    Issue.record("the census of this process's children at the end could not be read (errno \(code)), so survivors could not be counted")
                    return []
                }
            }
        }
    }

    /// The accounting every suite carrying `.noSurvivingChildren` shares.
    static let shared = Accounting(census: { census(parent: getpid()) })
}

/// NoSurvivingChildrenTrait fails a suite's run when it, or the suites that
/// ran beside it, left a child of this process alive.
struct NoSurvivingChildrenTrait: SuiteTrait, TestScoping {
    func provideScope(for test: Test, testCase: Test.Case?, performing function: @Sendable () async throws -> Void) async throws {
        ChildSurvivors.shared.enter()
        var failure: (any Error)?
        do { try await function() } catch { failure = error }
        ChildSurvivors.recordSurvivors(ChildSurvivors.shared.exit())
        if let failure { throw failure }
    }
}

extension SuiteTrait where Self == NoSurvivingChildrenTrait {
    /// A suite that starts children carries this: after its tests, no child
    /// they started may be left alive.
    static var noSurvivingChildren: Self { NoSurvivingChildrenTrait() }
}
