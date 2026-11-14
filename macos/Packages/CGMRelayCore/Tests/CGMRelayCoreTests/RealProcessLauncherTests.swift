import Testing
import Foundation
@testable import CGMRelayCore

@Suite("RealProcessLauncher")
struct RealProcessLauncherTests {
    /// Case names one shell command and the exit code RealProcessLauncher
    /// must report for it through onExit.
    struct Case: Sendable {
        let shellCommand: String
        let wantExitCode: Int32
    }

    /// exitCode launches /bin/sh with `-c shellCommand` through the real
    /// RealProcessLauncher and waits for its onExit callback, returning
    /// whatever code it reports. This is the only place the operating
    /// system's own termination reporting -- an ordinary exit status
    /// against a death by signal -- can actually be observed; every other
    /// test in this package launches a fake that never runs anything.
    private func exitCode(forShellCommand shellCommand: String, standardInputData: Data = Data()) async throws -> Int32 {
        let launcher = RealProcessLauncher()
        return try await withCheckedThrowingContinuation { continuation in
            do {
                _ = try launcher.launch(
                    executableURL: URL(fileURLWithPath: "/bin/sh"),
                    arguments: ["-c", shellCommand],
                    standardInputData: standardInputData,
                    onReady: {}
                ) { exitCode in
                    continuation.resume(returning: exitCode)
                }
            } catch {
                continuation.resume(throwing: error)
            }
        }
    }

    @Test(
        "onExit reports an ordinary exit status unchanged, and a death by signal as the negative of the signal number",
        arguments: [
            Case(shellCommand: "exit 3", wantExitCode: 3),
            Case(shellCommand: "kill -QUIT $$", wantExitCode: -3),
        ]
    )
    func onExitReportsTheRealTerminationReasonCorrectlySigned(_ testCase: Case) async throws {
        let got = try await exitCode(forShellCommand: testCase.shellCommand)
        #expect(got == testCase.wantExitCode)
    }

    @Test("a child that exits immediately without reading a stdin payload larger than a pipe buffer never raises SIGPIPE into this process")
    func childExitingWithoutReadingLargePayloadNeverRaisesSIGPIPE() async throws {
        // Well over one pipe buffer (64 KB): without the per-descriptor
        // SIGPIPE guard, writing this on the background queue after
        // `exit 9` has already closed the read end kills the whole test
        // process outright rather than failing one test.
        let largePayload = Data(repeating: 0x42, count: 200_000)
        let got = try await exitCode(forShellCommand: "exit 9", standardInputData: largePayload)
        #expect(got == 9)
    }

    /// EnvironmentCase names one shell command that exits 0 when the
    /// child process's environment is exactly what it should be, and
    /// something else otherwise -- either an unlisted variable this test
    /// process carries reaching the child (it must not), or an allowed
    /// one failing to (it must).
    struct EnvironmentCase: Sendable {
        let label: String
        let shellCommand: String
    }

    /// This test process sets a synthetic variable of its own before
    /// each case and clears it after, so the two cases below can run
    /// against the exact same real launch() path the rest of this suite
    /// does, never a fake. Serialized because both cases share that one
    /// process-wide variable.
    @Test(
        "the engine child process gets an explicit, minimal environment: nothing this test process happens to carry beyond the allowlist, and every allowed variable still arrives",
        .serialized,
        arguments: [
            EnvironmentCase(label: "an unlisted variable never reaches the child", shellCommand: "[ -z \"$CGMRELAY_TEST_SENTINEL\" ]"),
            EnvironmentCase(label: "an allowed variable still reaches the child", shellCommand: "[ -n \"$HOME\" ]"),
        ]
    )
    func childEnvironmentCases(_ testCase: EnvironmentCase) async throws {
        setenv("CGMRELAY_TEST_SENTINEL", "present", 1)
        defer { unsetenv("CGMRELAY_TEST_SENTINEL") }

        let got = try await exitCode(forShellCommand: testCase.shellCommand)
        #expect(got == 0, "\(testCase.label): shell command \"\(testCase.shellCommand)\" exited \(got)")
    }

    /// LineCollector gathers the lines the launcher forwards.
    private final class LineCollector: @unchecked Sendable {
        private let lock = NSLock()
        private var stored: [String] = []
        private let arrived = DispatchSemaphore(value: 0)
        var lines: [String] { lock.withLock { stored } }
        func add(_ line: String) {
            lock.withLock { stored.append(line) }
            arrived.signal()
        }
        /// waitForLine waits on the arrival of the next unconsumed line, up
        /// to the hang ceiling, and says whether one arrived.
        func waitForLine() -> Bool {
            arrived.wait(timeout: .now() + .milliseconds(Int(TestChild.hangCeilingMilliseconds))) == .success
        }
    }

    /// forwardedLines runs shellCommand through a launcher whose log sink is
    /// a collector, waits for the child to exit and its stderr to drain,
    /// and returns every line forwarded.
    private func forwardedLines(forShellCommand shellCommand: String, standardInputData: Data = Data()) async throws -> [String] {
        let collector = LineCollector()
        let launcher = RealProcessLauncher(engineLog: { collector.add($0) })
        _ = try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Int32, Error>) in
            do {
                _ = try launcher.launch(
                    executableURL: URL(fileURLWithPath: "/bin/sh"),
                    arguments: ["-c", shellCommand],
                    standardInputData: standardInputData,
                    onReady: {}
                ) { continuation.resume(returning: $0) }
            } catch {
                continuation.resume(throwing: error)
            }
        }
        // The exit callback can precede the last stderr read by a moment.
        for _ in 0..<200 where collector.lines.count < 3 {
            try await Task.sleep(for: .milliseconds(25))
        }
        return collector.lines
    }

    @Test("every complete line the engine writes to stderr is forwarded whole, with CRLF stripped and an unterminated last line kept")
    func engineStderrLinesAreForwardedWhole() async throws {
        let got = try await forwardedLines(
            forShellCommand: "printf 'poller: first\\n' >&2; printf 'poller: second\\r\\n\\n' >&2; printf 'poller: no newline' >&2"
        )

        #expect(got == ["poller: first", "poller: second", "poller: no newline"])
    }

    @Test("a line the engine writes is forwarded while the engine is still running, not when it exits")
    func lineArrivesWhileEngineStillRuns() throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("launcher-line-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        let fifo = dir.appendingPathComponent("release").path
        try #require(mkfifo(fifo, 0o600) == 0)
        // Read-write open never blocks on a FIFO; holding it keeps the child's own open from blocking too.
        let releaseFD = open(fifo, O_RDWR | O_CLOEXEC)
        try #require(releaseFD >= 0)
        defer { close(releaseFD) }

        let collector = LineCollector()
        let exited = DispatchSemaphore(value: 0)
        let launcher = RealProcessLauncher(engineLog: { collector.add($0) })
        // The child writes its line, then stays running until the test writes
        // to the FIFO, and then exits on its own. No signal is ever sent.
        let process = try launcher.launch(
            executableURL: URL(fileURLWithPath: "/bin/sh"),
            arguments: ["-c", "printf 'poller: alive\\n' >&2; read _ < \"$1\"", "sh", fifo],
            standardInputData: Data(),
            onReady: {}
        ) { _ in exited.signal() }
        let pid = process.processIdentifier
        // Registered right after the launch: release the child, then observe its exit.
        defer {
            _ = write(releaseFD, "x\n", 2)
            if exited.wait(timeout: .now() + .milliseconds(Int(TestChild.hangCeilingMilliseconds))) != .success {
                Issue.record("engine child pid \(pid) may still be running, outcome unknown; it was not signalled, end it by hand")
            }
        }

        // The child cannot exit before the defer above releases it, so a line
        // that arrives now arrived while it was still running.
        #expect(collector.waitForLine(), "no line arrived within \(TestChild.hangCeilingMilliseconds) ms")
        #expect(collector.lines == ["poller: alive"])
    }

    @Test("a line longer than the bound is cut to it, and the lines after it still arrive")
    func overlongLineIsBounded() async throws {
        let got = try await forwardedLines(
            forShellCommand: "head -c 20000 /dev/zero | tr '\\0' 'x' >&2; printf '\\npoller: after\\npoller: last\\n' >&2"
        )
        #expect(got.count == 3)
        #expect(got.first?.utf8.count == EngineLineSplitter.maxLineBytes)
        #expect(Array(got.dropFirst()) == ["poller: after", "poller: last"])
    }

    /// ReadyCounter counts onReady calls from the launcher's background queue.
    private final class ReadyCounter: @unchecked Sendable {
        private let lock = NSLock()
        private var stored = 0
        var count: Int { lock.withLock { stored } }
        func increment() { lock.withLock { stored += 1 } }
    }

    /// readyWindow is how long after the child exits onReady calls are still
    /// counted. The stdout reader can trail the exit callback on a busy
    /// machine, so a late right call must still count; the same window
    /// applies to every case, so a wrong call (a second one, or one for
    /// output that holds no ready line) arriving within it is counted too.
    private static let readyWindow: Duration = .seconds(3)

    /// readyCount runs shellCommand, waits for it to exit, keeps counting
    /// onReady calls for readyWindow, and returns how many there were.
    private func readyCount(forShellCommand shellCommand: String) async throws -> Int {
        let counter = ReadyCounter()
        let launcher = RealProcessLauncher()
        let exit = try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Int32, Error>) in
            do {
                _ = try launcher.launch(
                    executableURL: URL(fileURLWithPath: "/bin/sh"),
                    arguments: ["-c", shellCommand],
                    standardInputData: Data(),
                    onReady: { counter.increment() }
                ) { continuation.resume(returning: $0) }
            } catch {
                continuation.resume(throwing: error)
            }
        }
        #expect(exit == 0)
        try await Task.sleep(for: Self.readyWindow)
        return counter.count
    }

    @Test(
        "onReady fires once for the engine's ready line, never for other stdout, and a flood of stdout never blocks the child",
        arguments: [
            ReadyCase(shellCommand: "printf 'ready\\n'", wantCount: 1),
            ReadyCase(shellCommand: "printf 'rea'; sleep 0.1; printf 'dy\\nready\\n'", wantCount: 1),
            ReadyCase(shellCommand: "printf 'not ready\\nreadyx\\nready'", wantCount: 0),
            ReadyCase(shellCommand: "head -c 500000 /dev/zero | tr '\\0' 'x'; printf '\\nready\\n'", wantCount: 1),
        ]
    )
    func readyLineFiresOnReady(_ testCase: ReadyCase) async throws {
        #expect(try await readyCount(forShellCommand: testCase.shellCommand) == testCase.wantCount, "\(testCase.shellCommand)")
    }

    struct ReadyCase: Sendable {
        let shellCommand: String
        let wantCount: Int
    }

    /// ScannerCase feeds ReadyLineScanner a stream in the given chunks and
    /// names how many times append must return true across all of them.
    struct ScannerCase: Sendable, CustomTestStringConvertible {
        let chunks: [String]
        let wantReady: Int

        /// A short label for the test report. Without it the report names each
        /// case by printing its chunks whole, so the 500,000-character flood
        /// case alone adds about half a megabyte to it and slows the run.
        var testDescription: String {
            let shown = chunks.map { $0.count > 40 ? "<\($0.count) characters>" : $0.debugDescription }
            return "\(shown.joined(separator: " + ")) -> \(wantReady)"
        }
    }

    /// The launcher calls onReady only when append returns true, so the
    /// scanner's own count is checked here directly, with no process and no
    /// clock, on the same streams and on splits and near misses the process
    /// table cannot produce reliably. The process table above checks the
    /// calls that actually reach onReady through a real pipe.
    @Test(
        "the ready-line scanner reports the ready line exactly once and never for other output",
        arguments: [
            ScannerCase(chunks: ["ready\n"], wantReady: 1),
            ScannerCase(chunks: ["rea", "dy\nready\n"], wantReady: 1),
            ScannerCase(chunks: ["ready\nready\nready\n"], wantReady: 1),
            ScannerCase(chunks: ["ready\n", "ready\n", "ready\n"], wantReady: 1),
            ScannerCase(chunks: ["not ready\nreadyx\nready"], wantReady: 0),
            ScannerCase(chunks: ["xready\n", " ready\n", "ready \n", "READY\n"], wantReady: 0),
            ScannerCase(chunks: [String(repeating: "x", count: 500_000), "\nready\n"], wantReady: 1),
        ]
    )
    func scannerReportsTheReadyLineExactlyOnce(_ testCase: ScannerCase) {
        var scanner = ReadyLineScanner()
        let got = testCase.chunks.reduce(0) { count, chunk in count + (scanner.append(Data(chunk.utf8)) ? 1 : 0) }
        #expect(got == testCase.wantReady, "\(testCase.chunks.map { String($0.prefix(40)) })")
    }

    // MARK: Signals reach only the launched child

    /// ExitRecord collects what a spawned child's onExit reported.
    private final class ExitRecord: @unchecked Sendable {
        private let lock = NSLock()
        private var codes: [Int32] = []
        let exited = DispatchSemaphore(value: 0)

        func record(_ code: Int32) {
            lock.withLock { codes.append(code) }
            exited.signal()
        }

        var reported: [Int32] { lock.withLock { codes } }

        /// waitForExit waits for one report, up to the repo's hang ceiling.
        func waitForExit() -> Bool {
            exited.wait(timeout: .now() + .milliseconds(Int(TestChild.hangCeilingMilliseconds))) == .success
        }
    }

    private func spawn(_ executable: String, _ arguments: [String] = []) throws -> (child: SpawnedChild, input: FileHandle, exits: ExitRecord) {
        let inputPipe = Pipe()
        let exits = ExitRecord()
        let child = try ChildSpawner.spawn(
            executableURL: URL(fileURLWithPath: executable),
            arguments: arguments,
            environment: ["PATH": "/usr/bin:/bin"],
            standardInput: inputPipe.fileHandleForReading.fileDescriptor,
            standardOutput: nil,
            standardError: nil
        ) { exits.record($0) }
        try inputPipe.fileHandleForReading.close()
        return (child, inputPipe.fileHandleForWriting, exits)
    }

    /// startedCat spawns /bin/cat, which stays alive until its stdin closes.
    private func startedCat() throws -> (child: SpawnedChild, input: FileHandle, exits: ExitRecord) {
        try spawn("/bin/cat")
    }

    @Test("a signal sent while the launched child lives reaches it")
    func signalReachesALiveChild() throws {
        let started = try startedCat()
        // Closing its input ends cat on its own if the signal never lands.
        defer { try? started.input.close() }
        #expect(started.child.signaller.send(SIGTERM) == true)
        try #require(started.exits.waitForExit(), "child pid \(started.child.processIdentifier) did not end after the signal")
        #expect(started.exits.reported == [-SIGTERM])
        #expect(started.child.hasExited)
    }

    @Test("once the child has ended and been reaped, a send is refused and reports that it sent nothing")
    func sendAfterTheChildEndedIsRefused() throws {
        let started = try startedCat()
        try started.input.close()
        try #require(started.exits.waitForExit())
        #expect(started.exits.reported == [0])
        #expect(started.child.signaller.send(SIGTERM) == false)
        #expect(started.child.signaller.send(SIGKILL) == false)
    }

    @Test("a send is refused for a child that has been reaped even by a sender that was never told it ended")
    func sendAfterTheChildWasReapedIsRefusedWithoutBeingTold() throws {
        let started = try startedCat()
        // A second sender over the same live child, which nothing tells about its end.
        let untold = LaunchedChildSignaller(pid: started.child.processIdentifier)
        try started.input.close()
        try #require(started.exits.waitForExit())
        #expect(untold.send(SIGTERM) == false)
        #expect(untold.send(SIGKILL) == false)
    }

    @Test("once the sender has been told the child ended, a send is refused even while that child is still alive")
    func sendAfterBeingToldTheChildEndedIsRefusedWhileItLives() throws {
        let started = try startedCat()
        // Closing its input ends cat on its own if a refused send is wrongly delivered or the test fails early.
        defer { try? started.input.close() }
        let pid = started.child.processIdentifier
        started.child.signaller.markTerminated()
        #expect(started.child.signaller.send(SIGTERM) == false)
        #expect(started.child.signaller.send(SIGKILL) == false)
        errno = 0
        let probe = kill(pid, 0)
        let probeErrno = errno
        #expect(probe == 0, "kill(\(pid), 0) returned \(probe), errno \(probeErrno): a refused send still ended the child")
        try started.input.close()
        try #require(started.exits.waitForExit())
        #expect(started.exits.reported == [0])
    }

    @Test("children that end at once, or while sends race their end, are reported exactly once with their own status and refuse every later send")
    func endingRacesWithSends() throws {
        for _ in 0..<25 {
            // A child that may already have ended by the time the sender reads its record.
            let quick = try spawn("/usr/bin/true")
            try #require(quick.exits.waitForExit())
            #expect(quick.exits.reported == [0])
            #expect(quick.child.signaller.send(SIGTERM) == false)
        }
        for _ in 0..<25 {
            let racing = try startedCat()
            let racerDone = DispatchSemaphore(value: 0)
            DispatchQueue.global().async {
                // Send until a send is refused: it must be refused once the child is reaped.
                while racing.child.signaller.send(SIGTERM) {}
                racerDone.signal()
            }
            try racing.input.close()
            try #require(racing.exits.waitForExit())
            try #require(racerDone.wait(timeout: .now() + .milliseconds(Int(TestChild.hangCeilingMilliseconds))) == .success)
            let reported = racing.exits.reported
            #expect(reported == [0] || reported == [-SIGTERM], "reported \(reported)")
            #expect(racing.child.signaller.send(SIGTERM) == false)
        }
    }

    @Test("a stop ends what the child started as well: it leads its own group and the signal goes to the group")
    func signalReachesTheChildsDescendants() throws {
        let outputPipe = Pipe()
        let exits = ExitRecord()
        let child = try ChildSpawner.spawn(
            executableURL: URL(fileURLWithPath: "/bin/sh"),
            arguments: ["-c", "sleep 30 & echo $!; wait"],
            environment: ["PATH": "/usr/bin:/bin"],
            standardInput: nil,
            standardOutput: outputPipe.fileHandleForWriting.fileDescriptor,
            standardError: nil
        ) { exits.record($0) }
        try outputPipe.fileHandleForWriting.close()
        let pid = child.processIdentifier
        #expect(getpgid(pid) == pid, "the child is not the leader of its own group")

        // The child itself reports its background process's pid, once it exists.
        let gotLine = DispatchSemaphore(value: 0)
        let line = LockedText()
        outputPipe.fileHandleForReading.readabilityHandler = { handle in
            let data = handle.availableData
            guard !data.isEmpty else { return }
            line.append(String(decoding: data, as: UTF8.self))
            gotLine.signal()
        }
        defer { outputPipe.fileHandleForReading.readabilityHandler = nil }
        try #require(gotLine.wait(timeout: .now() + .milliseconds(Int(TestChild.hangCeilingMilliseconds))) == .success, "the child never reported its background process")
        let descendantPID = try #require(pid_t(line.value.trimmingCharacters(in: .whitespacesAndNewlines)), "child reported \"\(line.value)\"")
        let descendant = try #require(LaunchedChildSignaller.systemProcessTable(descendantPID), "no record for the child's background process \(descendantPID)")
        #expect(descendant.parentPID == pid)
        #expect(getpgid(descendantPID) == pid, "the background process is not in the child's group")

        #expect(child.signaller.send(SIGTERM) == true)
        try #require(exits.waitForExit(), "child \(pid) did not end after the signal")
        #expect(exits.reported == [-SIGTERM])
        // Gone means no process with that pid and start time any more; the
        // wait is on the descendant's own end, which no event reports to us.
        let deadline = ContinuousClock.now + .milliseconds(Int(TestChild.hangCeilingMilliseconds))
        var stillThere = true
        while stillThere && ContinuousClock.now < deadline {
            let now = LaunchedChildSignaller.systemProcessTable(descendantPID)
            stillThere = now?.start == descendant.start
            if stillThere { usleep(10_000) }
        }
        #expect(!stillThere, "the background process \(descendantPID) was not ended by the stop")
    }

    private final class LockedText: @unchecked Sendable {
        private let lock = NSLock()
        private var text = ""
        func append(_ more: String) { lock.withLock { text += more } }
        var value: String { lock.withLock { text } }
    }

    /// FactsCase scripts what the process table says at launch and just
    /// before a send, for one real child, and what must then happen.
    struct FactsCase: Sendable, CustomTestStringConvertible {
        enum Later: Sendable { case sameFacts, sameFactsOtherStart, noRecord, otherPid }
        let label: String
        let launchParentIsUs: Bool
        let later: Later
        let markedEnded: Bool
        let wantSent: Bool
        var testDescription: String { label }
    }

    @Test(
        "a signal goes to the child only while the process table still shows the facts read at launch, and never when launch did not show the child as ours",
        arguments: [
            FactsCase(label: "same pid, start and parent as at launch: the child is signalled", launchParentIsUs: true, later: .sameFacts, markedEnded: false, wantSent: true),
            FactsCase(label: "the same pid now has another start time", launchParentIsUs: true, later: .sameFactsOtherStart, markedEnded: false, wantSent: false),
            FactsCase(label: "the pid has no record", launchParentIsUs: true, later: .noRecord, markedEnded: false, wantSent: false),
            FactsCase(label: "the record is for another pid", launchParentIsUs: true, later: .otherPid, markedEnded: false, wantSent: false),
            FactsCase(label: "the facts match but the child's exit has been observed", launchParentIsUs: true, later: .sameFacts, markedEnded: true, wantSent: false),
            FactsCase(label: "the launch read shows a parent that is not this process", launchParentIsUs: false, later: .sameFacts, markedEnded: false, wantSent: false),
        ]
    )
    func signalFollowsTheFactsReadAtLaunch(_ testCase: FactsCase) throws {
        let started = try startedCat()
        // Closing its input ends cat on its own if the test stops early.
        defer { try? started.input.close() }
        let pid = started.child.processIdentifier

        // The real record of this live child gives start A; B is one microsecond later.
        let real = try #require(LaunchedChildSignaller.systemProcessTable(pid), "no process-table record for the live child \(pid)")
        #expect(real.parentPID == getpid(), "a spawned child's parent is this process")
        let startA = real.start
        let startB = ProcessStart(seconds: startA.seconds, microseconds: startA.microseconds + 1)
        let atLaunch = ProcessRecord(pid: pid, parentPID: testCase.launchParentIsUs ? getpid() : getpid() + 1, start: startA)
        let beforeSend: ProcessRecord? = switch testCase.later {
        case .sameFacts: atLaunch
        case .sameFactsOtherStart: ProcessRecord(pid: pid, parentPID: getpid(), start: startB)
        case .noRecord: nil
        case .otherPid: ProcessRecord(pid: pid + 1, parentPID: getpid(), start: startA)
        }
        let table = ScriptedProcessTable(atLaunch: atLaunch, beforeSend: beforeSend)
        // A second sender over the held child, driven by the scripted table.
        let signaller = LaunchedChildSignaller(pid: pid, readProcessTable: table.reader)
        if testCase.markedEnded { signaller.markTerminated() }

        #expect(signaller.send(SIGTERM) == testCase.wantSent)
        if testCase.wantSent {
            try #require(started.exits.waitForExit(), "child \(pid) did not end after the signal")
            #expect(started.exits.reported == [-SIGTERM])
        } else {
            errno = 0
            let probe = kill(pid, 0)
            let probeErrno = errno
            #expect(probe == 0, "kill(\(pid), 0) returned \(probe), errno \(probeErrno): a refused send still affected the child")
            try started.input.close()
            try #require(started.exits.waitForExit())
            #expect(started.exits.reported == [0])
        }
    }

    /// ScriptedProcessTable answers the signaller's process-table reads from
    /// a script: the first read is the launch read, every later one is the
    /// read just before a send.
    private final class ScriptedProcessTable: @unchecked Sendable {
        private let lock = NSLock()
        private var reads = 0
        private let atLaunch: ProcessRecord?
        private let beforeSend: ProcessRecord?

        init(atLaunch: ProcessRecord?, beforeSend: ProcessRecord?) {
            self.atLaunch = atLaunch
            self.beforeSend = beforeSend
        }

        var reader: LaunchedChildSignaller.ProcessTableReader {
            { _ in
                self.lock.withLock {
                    self.reads += 1
                    return self.reads == 1 ? self.atLaunch : self.beforeSend
                }
            }
        }
    }

    /// SignalCase names one launcher stop and how the child must end for it.
    struct StopCase: Sendable, CustomTestStringConvertible {
        let label: String
        let script: String
        let hardStop: Bool
        let wantExitCode: Int32
        var testDescription: String { label }
    }

    @Test(
        "the launcher's stop and hard stop still reach a running child",
        arguments: [
            StopCase(label: "terminate ends an ordinary child by SIGTERM", script: "sleep 30", hardStop: false, wantExitCode: -SIGTERM),
            StopCase(label: "kill ends a child that ignores SIGTERM by SIGKILL", script: "$SIG{TERM}='IGNORE'; sleep 30", hardStop: true, wantExitCode: -SIGKILL),
        ]
    )
    func launcherStopsReachARunningChild(_ testCase: StopCase) async throws {
        let launcher = RealProcessLauncher()
        let started = DispatchSemaphore(value: 0)
        let got = try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Int32, Error>) in
            do {
                let process = try launcher.launch(
                    executableURL: URL(fileURLWithPath: "/usr/bin/perl"),
                    arguments: ["-e", testCase.script],
                    standardInputData: Data(),
                    onReady: {}
                ) { continuation.resume(returning: $0) }
                _ = started
                if testCase.hardStop { process.kill() } else { process.terminate() }
            } catch {
                continuation.resume(throwing: error)
            }
        }
        #expect(got == testCase.wantExitCode)
    }
}
