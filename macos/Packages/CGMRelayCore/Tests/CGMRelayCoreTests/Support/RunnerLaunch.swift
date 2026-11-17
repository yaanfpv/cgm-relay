import Testing
import Foundation
@testable import CGMRelayCore

/// HeldFifo is a FIFO the test keeps open for reading and writing, in a
/// directory the test owns. A fixture process that blocks reading it has no end
/// of its own: it goes on only when the test calls `release`, whatever the run
/// returned and however late the caller is. The test opens it first, so the
/// fixture's own open never blocks.
final class HeldFifo: @unchecked Sendable {
    let path: String
    private let descriptor: Int32
    private let lock = NSLock()
    private var released = false

    /// How many lines release writes: one per reader that may be blocked on it.
    private static let lines = 64

    init(in directory: URL, name: String = "release") throws {
        path = directory.appendingPathComponent(name).path
        guard mkfifo(path, 0o600) == 0 else { throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO) }
        // Read-write open never blocks on a FIFO.
        let fd = Darwin.open(path, O_RDWR)
        guard fd >= 0 else { throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO) }
        descriptor = fd
    }

    deinit { Darwin.close(descriptor) }

    /// release lets every fixture process blocked on the FIFO go on. It is made
    /// once, whatever state the fixtures are in, and again does nothing.
    func release() {
        lock.withLock {
            guard !released else { return }
            released = true
            let text = Array(String(repeating: "x\n", count: Self.lines).utf8)
            _ = text.withUnsafeBufferPointer { Darwin.write(descriptor, $0.baseAddress, $0.count) }
        }
    }
}

/// RunnerLaunch builds a real bounded runner whose launch read is recorded: the
/// identity the signaller took of every child the runner started, while that
/// child was necessarily unreaped. The read itself is the real one, so the
/// runner signals and reaps as it does in the app. One value serves any number
/// of launches, so a test that runs several commands names every child.
final class RunnerLaunch: @unchecked Sendable {
    private let lock = NSLock()
    private var launches: [StoppedChildSupport.RecordedProcess] = []
    private let extraEnvironment: [String: String]
    private let showsIdentityToRunner: Bool

    /// `showsIdentityToRunner` false hands the runner no record after noting
    /// the child, so no identity is accepted and every send is refused.
    init(extraEnvironment: [String: String] = [:], showsIdentityToRunner: Bool = true) {
        self.extraEnvironment = extraEnvironment
        self.showsIdentityToRunner = showsIdentityToRunner
    }

    /// recorded is every child started so far, in the order first seen.
    var recorded: [StoppedChildSupport.RecordedProcess] { lock.withLock { launches } }

    private func note(_ record: ProcessRecord) {
        lock.withLock {
            guard !launches.contains(where: { $0.pid == record.pid && $0.start == record.start }) else { return }
            launches.append(StoppedChildSupport.RecordedProcess(pid: record.pid, start: record.start))
        }
    }

    var runner: RealBoundedProcessRunner {
        RealBoundedProcessRunner(extraEnvironment: extraEnvironment, readProcessTable: { [self] pid in
            let real = LaunchedChildSignaller.systemProcessTable(pid)
            if let real, real.parentPID == getpid() { note(real) }
            return showsIdentityToRunner ? real : nil
        })
    }

    private static func text(_ recorded: StoppedChildSupport.RecordedProcess) -> String {
        "\(recorded.start.seconds).\(recorded.start.microseconds)"
    }

    private func unknownLaunch(_ directory: URL) {
        Issue.record("test child \(ChildCleanup.describe(pid: 0, start: nil)) was not confirmed ended, it may still be running; no identity was recorded at launch and the launch was not reported failed, so \(directory.path) was kept")
    }

    /// endChildren ends every child the runner launched that is still there,
    /// and removes `directory` only once every one is confirmed ended. A child
    /// is signalled only while its number still shows the start recorded at
    /// launch. One not confirmed ended fails the test naming it and keeps the
    /// directory. A launch with no recorded identity counts as "nothing started"
    /// only when the runner reported that the launch itself failed; otherwise a
    /// child may be running, so the directory is kept and the test fails naming
    /// the unknown.
    func endChildren(removing directory: URL, launchFailed: Bool) {
        let children = recorded
        guard !children.isEmpty else {
            if launchFailed { try? FileManager.default.removeItem(at: directory) } else { unknownLaunch(directory) }
            return
        }
        var allEnded = true
        for child in children {
            let outcome = ChildCleanup.endRecordedRecordingNotConfirmed(
                pid: child.pid, start: Self.text(child),
                readStart: { ChildCleanup.startNow(pid: $0) },
                exists: { !StoppedChildSupport.isGone(pid: $0) },
                send: { _, signal in StoppedChildSupport.signal(child, signal) },
                waitingMilliseconds: TestChild.hangCeilingMilliseconds
            )
            if outcome != .ended { allEnded = false }
        }
        if allEnded { try? FileManager.default.removeItem(at: directory) }
    }

    /// endChildrenAfterRelease is for fixtures that block on an input the test
    /// holds. It releases that input first, on every path, whatever the run
    /// returned, then confirms each child's end by read only: it sends nothing.
    /// `directory` is removed only once every child is confirmed gone. A child
    /// whose end is not seen, or whose record cannot be read, fails the test
    /// naming it and the directory stays.
    func endChildrenAfterRelease(removing directory: URL, launchFailed: Bool, release: () -> Void) {
        release()
        let children = recorded
        guard !children.isEmpty else {
            if launchFailed { try? FileManager.default.removeItem(at: directory) } else { unknownLaunch(directory) }
            return
        }
        var allEnded = true
        for child in children {
            let gone = DescendantCheck.requireGone(pid: child.pid, start: child.start, read: { readProcessTable($0) })
            if !gone {
                allEnded = false
                Issue.record("test child \(ChildCleanup.describe(pid: child.pid, start: Self.text(child))) was not confirmed ended after its input was released, it may still be running; \(directory.path) was kept")
            }
        }
        if allEnded { try? FileManager.default.removeItem(at: directory) }
    }

    /// requireEnded fails the test, naming each child, unless the typed table
    /// read shows it gone now: absent, or present with another start. A child
    /// still there, or a record that cannot be read, is not an end.
    func requireEnded() {
        let children = recorded
        guard !children.isEmpty else {
            Issue.record("no identity was recorded for the launched child, so its end could not be checked")
            return
        }
        for child in children {
            let read = readProcessTable(child.pid)
            let verdict = DescendantCheck.verdict(read, of: child.start)
            #expect(verdict == .gone, "the child \(child.pid) was not shown ended after the run returned: \(verdict) (read \(read))")
        }
    }
}
