import Testing
import Foundation

/// ChildSurvivors names the direct children of this process that a group of
/// suites started and left alive. It reads them from the kernel. A child that
/// ended and was collected is not in the list; one that is still there, or
/// ended but was never collected, is. A process a child started and left
/// behind is not a child of this one, so it is not seen here.
enum ChildSurvivors {
    struct Child: Equatable, Sendable {
        let pid: Int32
        /// The start time the process table shows for the child, as text, or
        /// nil when it cannot be read (a child that ended but was not collected).
        let start: String?
    }

    /// liveChildren lists the direct children of this process, read from the
    /// kernel. A listing that fails is a failure of the test that asked, not an
    /// empty list.
    static func liveChildren() -> [Child] {
        var capacity = 64
        while true {
            var pids = [Int32](repeating: 0, count: capacity)
            let bytes = proc_listpids(UInt32(PROC_PPID_ONLY), UInt32(getpid()), &pids, Int32(capacity * MemoryLayout<Int32>.size))
            guard bytes >= 0 else {
                Issue.record("the kernel's list of this process's children could not be read (errno \(errno)), so survivors could not be counted")
                return []
            }
            let count = Int(bytes) / MemoryLayout<Int32>.size
            if count >= capacity {
                capacity *= 2
                continue
            }
            return pids.prefix(count).filter { $0 > 0 }.map { Child(pid: $0, start: startText(pid: $0)) }
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
        private let census: @Sendable () -> [Child]
        private let lock = NSLock()
        private var active = 0
        private var baseline: [Child] = []

        init(census: @escaping @Sendable () -> [Child]) {
            self.census = census
        }

        func enter() {
            lock.withLock {
                if active == 0 { baseline = census() }
                active += 1
            }
        }

        /// exit returns the survivors when this is the last exit, and an empty
        /// list otherwise.
        func exit() -> [Child] {
            lock.withLock {
                active = max(0, active - 1)
                guard active == 0 else { return [] }
                return ChildSurvivors.new(since: baseline, now: census())
            }
        }
    }

    /// The accounting every suite carrying `.noSurvivingChildren` shares.
    static let shared = Accounting(census: { liveChildren() })
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
