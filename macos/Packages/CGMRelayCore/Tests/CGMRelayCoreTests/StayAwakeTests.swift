import Foundation
import Testing
@testable import CGMRelayCore

private let laptopOnAC = PowerSnapshot(isLaptop: true, onACPower: true)
private let laptopOnBattery = PowerSnapshot(isLaptop: true, onACPower: false)
private let desktopOnAC = PowerSnapshot(isLaptop: false, onACPower: true)

// MARK: - Policy

@Suite("StayAwakePolicy")
struct StayAwakePolicyTests {
    @Test("every combination follows the rule; disableSleep only for on + running + laptop + AC")
    func exhaustive() {
        let choices: [StayAwakeChoice?] = [nil, .off, .on]
        for choice in choices {
            for running in [false, true] {
                for isLaptop in [false, true] {
                    for onAC in [false, true] {
                        let power = PowerSnapshot(isLaptop: isLaptop, onACPower: onAC)
                        let target = StayAwakePolicy.decide(choice: choice, relayRunning: running, power: power)
                        let active = choice == .on && running
                        let expected = StayAwakeTarget(
                            holdIdleAssertion: active && onAC,
                            disableSleep: active && isLaptop && onAC
                        )
                        #expect(target == expected, "choice \(String(describing: choice)) running \(running) laptop \(isLaptop) ac \(onAC)")
                    }
                }
            }
        }
    }

    @Test("the rule's named cases: plugged in or on battery, laptop or desktop, relay running or not")
    func namedRows() {
        let off = StayAwakeTarget(holdIdleAssertion: false, disableSleep: false)
        #expect(StayAwakePolicy.decide(choice: .on, relayRunning: true, power: desktopOnAC)
            == StayAwakeTarget(holdIdleAssertion: true, disableSleep: false))
        #expect(StayAwakePolicy.decide(choice: .on, relayRunning: true, power: laptopOnAC)
            == StayAwakeTarget(holdIdleAssertion: true, disableSleep: true))
        #expect(StayAwakePolicy.decide(choice: .on, relayRunning: true, power: laptopOnBattery) == off)
        #expect(StayAwakePolicy.decide(choice: .on, relayRunning: false, power: laptopOnAC) == off)
        #expect(StayAwakePolicy.decide(choice: nil, relayRunning: true, power: laptopOnAC) == off)
        #expect(StayAwakePolicy.decide(choice: .off, relayRunning: true, power: laptopOnAC) == off)
    }
}

// MARK: - Controller

private final class FailureBox: @unchecked Sendable {
    private let lock = NSLock()
    private var seen: [StayAwakeFailure] = []
    func add(_ failure: StayAwakeFailure) { lock.withLock { seen.append(failure) } }
    var all: [StayAwakeFailure] { lock.withLock { seen } }
}

@Suite("StayAwakeController")
struct StayAwakeControllerTests {
    private struct Rig {
        let log = StayAwakeCallLog()
        let power: FakePowerSource
        let idle: FakeIdleSleepAsserter
        let sleep: FakeSleepSettingWriter
        let helper: FakeSleepHelperRegistration
        let rules = FakeSleepRules()
        let controller: StayAwakeController

        init(choice: StayAwakeChoice?, power snapshot: PowerSnapshot, helperStatus: SleepHelperStatus = .enabled) {
            let log = self.log
            power = FakePowerSource(snapshot)
            idle = FakeIdleSleepAsserter(log: log)
            sleep = FakeSleepSettingWriter(log: log)
            helper = FakeSleepHelperRegistration(status: helperStatus)
            controller = StayAwakeController(
                choice: choice, power: power, assertion: idle, sleepSetting: sleep, rules: rules, helper: helper
            )
        }
    }

    @Test("turning keep-awake on from a helper that is not registered registers it once")
    func registersOnTurnOn() {
        for start in [SleepHelperStatus.notRegistered, .notFound] {
            let rig = Rig(choice: nil, power: laptopOnAC, helperStatus: start)
            rig.controller.choiceChanged(.on)
            #expect(rig.helper.registerCount == 1, "\(start)")
            rig.controller.choiceChanged(.on)
            rig.controller.relayStarted()
            rig.controller.launched()
            #expect(rig.helper.registerCount == 1, "\(start): approval is asked once")
        }
    }

    @Test("a launch with the choice already on registers a helper that is missing")
    func registersOnLaunchWhenOn() {
        for start in [SleepHelperStatus.notRegistered, .notFound] {
            let rig = Rig(choice: .on, power: laptopOnAC, helperStatus: start)
            rig.controller.launched()
            #expect(rig.helper.registerCount == 1, "\(start)")
        }
    }

    @Test("an enabled helper, or one waiting for approval, is never registered again")
    func noSecondRegistration() {
        for start in [SleepHelperStatus.enabled, .requiresApproval] {
            let rig = Rig(choice: .on, power: laptopOnAC, helperStatus: start)
            rig.controller.launched()
            rig.controller.choiceChanged(.on)
            rig.controller.choiceChanged(.off)
            rig.controller.choiceChanged(.on)
            rig.controller.relayStarted()
            #expect(rig.helper.registerCount == 0, "\(start)")
        }
    }

    @Test("a Mac with no battery is never asked to approve a helper")
    func noRegistrationOnADesktop() {
        let rig = Rig(choice: nil, power: desktopOnAC, helperStatus: .notRegistered)
        rig.controller.choiceChanged(.on)
        rig.controller.launched()
        rig.controller.relayStarted()
        #expect(rig.helper.registerCount == 0)
    }

    @Test("no registration unless the choice is on")
    func noRegistrationWhenNotOn() {
        for choice in [StayAwakeChoice?.none, .off] {
            let rig = Rig(choice: choice, power: laptopOnAC, helperStatus: .notRegistered)
            rig.controller.launched()
            rig.controller.relayStarted()
            rig.controller.choiceChanged(choice)
            #expect(rig.helper.registerCount == 0, "\(String(describing: choice))")
        }
    }

    @Test("turning off, quitting and willQuit only ever leave the helper registered, and never touch the permission")
    func turnOffRemovesNothing() async {
        let rig = Rig(choice: nil, power: laptopOnAC, helperStatus: .notRegistered)
        for _ in 0..<3 {
            rig.controller.choiceChanged(.on)
            rig.controller.relayStarted()
            rig.controller.choiceChanged(.off)
            rig.controller.relayStopped()
        }
        rig.controller.choiceChanged(.on)
        rig.controller.willQuit()
        await rig.controller.willQuitInBackground()
        #expect(rig.helper.calls == ["register"], "the helper saw one register and nothing else")
        #expect(rig.rules.calls.isEmpty, "the sleep permission is never removed, or touched at all")
        #expect(rig.helper.status != .notRegistered)
    }

    private func sorted(_ events: [String]) -> [String] { events.sorted() }

    @Test("full overnight sequence on a laptop")
    func sequence() {
        let rig = Rig(choice: .on, power: laptopOnAC)
        rig.controller.relayStarted()
        rig.controller.launched()
        let started = rig.log.drain()
        #expect(started.contains("hold"))
        #expect(started.filter { $0 == "hold" }.count == 1, "never holds twice")
        #expect(started.last(where: { $0.hasPrefix("setDisableSleep") }) == "setDisableSleep(true)")

        rig.power.current = laptopOnBattery
        rig.controller.powerChanged(laptopOnBattery)
        #expect(sorted(rig.log.drain()) == ["release", "setDisableSleep(false)"])

        rig.power.current = laptopOnAC
        rig.controller.powerChanged(laptopOnAC)
        #expect(sorted(rig.log.drain()) == ["hold", "setDisableSleep(true)"])

        rig.controller.relayStopped()
        #expect(sorted(rig.log.drain()) == ["release", "setDisableSleep(false)"])

        rig.controller.willQuit()
        #expect(rig.log.drain() == ["setDisableSleep(false)"], "willQuit writes even when already false")
    }

    @Test("writers are called only on a change")
    func onlyOnChange() {
        let rig = Rig(choice: .on, power: laptopOnAC)
        rig.controller.relayStarted()
        _ = rig.log.drain()
        rig.controller.powerChanged(laptopOnAC)
        rig.controller.powerChanged(laptopOnAC)
        #expect(rig.log.drain().isEmpty)
    }

    @Test("desktop on AC holds the idle assertion and never disables sleep")
    func desktop() {
        let rig = Rig(choice: .on, power: desktopOnAC)
        rig.controller.relayStarted()
        let events = rig.log.drain()
        #expect(events.contains("hold"))
        #expect(!events.contains("setDisableSleep(true)"))
    }

    @Test("launched with choice off writes disableSleep false")
    func launchedOff() {
        let rig = Rig(choice: .off, power: laptopOnAC)
        rig.controller.launched()
        #expect(rig.log.drain().contains("setDisableSleep(false)"))
        #expect(!rig.log.events.contains("hold"))
    }

    @Test("launched with nothing chosen writes disableSleep false")
    func launchedUnasked() {
        let rig = Rig(choice: nil, power: laptopOnAC)
        rig.controller.launched()
        #expect(rig.log.drain().contains("setDisableSleep(false)"))
    }

    @Test("choosing off while active releases and clears")
    func choiceOff() {
        let rig = Rig(choice: .on, power: laptopOnAC)
        rig.controller.relayStarted()
        _ = rig.log.drain()
        rig.controller.choiceChanged(.off)
        #expect(sorted(rig.log.drain()) == ["release", "setDisableSleep(false)"])
    }

    @Test("choosing on while the relay runs on a laptop at AC takes effect")
    func choiceOn() {
        let rig = Rig(choice: .off, power: laptopOnAC)
        rig.controller.relayStarted()
        _ = rig.log.drain()
        rig.controller.choiceChanged(.on)
        #expect(sorted(rig.log.drain()) == ["hold", "setDisableSleep(true)"])
    }

    @Test("quit clears disableSleep while active")
    func quitWhileActive() {
        let rig = Rig(choice: .on, power: laptopOnAC)
        rig.controller.relayStarted()
        _ = rig.log.drain()
        rig.controller.willQuit()
        #expect(rig.log.drain().contains("setDisableSleep(false)"))
    }

    @Test("a failed sleep write is retried when the relay changes again, not on a power notification that changed nothing")
    func failedWriteRetries() {
        let rig = Rig(choice: .on, power: laptopOnAC)
        rig.sleep.failNextWrite = true
        rig.controller.relayStarted()
        #expect(rig.sleep.attempts == 1)
        rig.controller.powerChanged(laptopOnAC)
        rig.controller.powerChanged(laptopOnAC)
        #expect(rig.sleep.attempts == 1, "a battery level step does not run the command again")
        rig.controller.relayStarted()
        #expect(rig.sleep.attempts == 2)
        #expect(rig.sleep.setting)
    }

    @Test("a write that keeps failing runs again only when the Mac really changes power source")
    func persistentFailureDoesNotLoop() {
        let rig = Rig(choice: .on, power: laptopOnAC)
        rig.sleep.failEveryWrite = true
        rig.controller.relayStarted()
        for _ in 0..<5 { rig.controller.powerChanged(laptopOnAC) }
        #expect(rig.sleep.attempts == 1)
        rig.controller.powerChanged(laptopOnBattery)
        #expect(rig.sleep.attempts == 2, "pulling the charger is a real change")
        for _ in 0..<5 { rig.controller.powerChanged(laptopOnBattery) }
        #expect(rig.sleep.attempts == 2)
    }

    /// A laptop on power whose launch reset worked, then an enable that took
    /// effect and timed out: the setting reads on, but the app was told the
    /// write failed.
    private func rigWithEnableThatTookEffectThenFailed() -> Rig {
        let rig = Rig(choice: .on, power: laptopOnAC)
        rig.controller.launched()
        rig.sleep.failNextWriteAfterEffect = true
        rig.controller.relayStarted()
        #expect(rig.sleep.setting, "the enable took effect before it reported failure")
        return rig
    }

    @Test("an enable that took effect before it failed is reset when the relay stops")
    func unknownEnableThenRelayStopped() {
        let rig = rigWithEnableThatTookEffectThenFailed()
        rig.controller.relayStopped()
        #expect(!rig.sleep.setting)
    }

    @Test("an enable that took effect before it failed is reset when the Mac goes onto battery")
    func unknownEnableThenBattery() {
        let rig = rigWithEnableThatTookEffectThenFailed()
        rig.power.current = laptopOnBattery
        rig.controller.powerChanged(laptopOnBattery)
        #expect(!rig.sleep.setting)
    }

    @Test("an enable that took effect before it failed is reset when the choice is turned off")
    func unknownEnableThenChoiceOff() {
        let rig = rigWithEnableThatTookEffectThenFailed()
        rig.controller.choiceChanged(.off)
        #expect(!rig.sleep.setting)
    }

    @Test("a choice turned off after such an enable, whose own reset also failed, is cleared on quit", arguments: [false, true])
    func unknownEnableThenChoiceOffThenQuit(inBackground: Bool) async {
        let rig = rigWithEnableThatTookEffectThenFailed()
        rig.sleep.failNextWrite = true
        rig.controller.choiceChanged(.off)
        #expect(rig.sleep.setting, "the reset did not happen")
        if inBackground {
            await rig.controller.willQuitInBackground()
        } else {
            rig.controller.willQuit()
        }
        #expect(!rig.sleep.setting)
    }

    @Test("a failed write does not block quit from clearing the setting")
    func failedWriteThenQuit() {
        let rig = Rig(choice: .on, power: laptopOnAC)
        rig.sleep.failNextWrite = true
        rig.controller.relayStarted()
        _ = rig.log.drain()
        rig.controller.willQuit()
        #expect(rig.log.drain().contains("setDisableSleep(false)"))
    }

    @Test("a failure reported on the quit thread reaches a handler the app set from the main actor, and the handler's hop back to the main actor completes")
    @MainActor
    func failureOnQuitThreadReachesMainActorHandler() async {
        let rig = Rig(choice: .on, power: laptopOnAC)
        rig.controller.launched()
        rig.controller.relayStarted()
        rig.sleep.failNextWrite = true
        // The handler is set from the main actor, the way the app sets it,
        // and does what the app's does: hop to the main actor to record.
        let (updates, deliver) = AsyncStream.makeStream(of: StayAwakeFailure.self)
        rig.controller.onFailure = { failure in
            Task { @MainActor in deliver.yield(failure) }
        }
        // willQuit runs on a thread of its own and its clearing write fails.
        await rig.controller.willQuitInBackground()
        deliver.finish()
        var seen: [StayAwakeFailure] = []
        for await failure in updates { seen.append(failure) }
        #expect(seen == [.sleepSettingNotChanged])
    }

    @Test("the failure the writer threw is the one reported; any other error is sleepSettingNotChanged", arguments: [
        (StayAwakeFailure.permissionNotInstalled as any Error, StayAwakeFailure.permissionNotInstalled),
        (StayAwakeFailure.sleepSettingNotChanged as any Error, StayAwakeFailure.sleepSettingNotChanged),
        (FakeWriteFailure() as any Error, StayAwakeFailure.sleepSettingNotChanged),
    ])
    func reportsTheWritersFailure(thrown: any Error, expected: StayAwakeFailure) {
        let rig = Rig(choice: .on, power: laptopOnAC)
        let seen = FailureBox()
        rig.controller.onFailure = { seen.add($0) }
        rig.sleep.throwError = thrown
        rig.controller.relayStarted()
        #expect(seen.all == [expected], "threw \(thrown)")
    }

    @Test("a failed hold does not stop the sleep setting following the target")
    func failedHold() {
        let rig = Rig(choice: .on, power: laptopOnAC)
        rig.idle.failNextHold = true
        rig.controller.relayStarted()
        #expect(rig.log.drain().contains("setDisableSleep(true)"))
        rig.controller.relayStopped()
        #expect(rig.log.drain().contains("setDisableSleep(false)"))
    }
}

// MARK: - Installer bytes

@Suite("SleepRuleInstaller")
struct SleepRuleInstallerTests {
    private let off = "/usr/bin/pmset -a disablesleep 0"
    private let on = "/usr/bin/pmset -a disablesleep 1"

    @Test("paths are fixed")
    func paths() {
        #expect(SleepRuleInstaller.sudoersPath == "/etc/sudoers.d/cgm-relay-disablesleep")
        #expect(SleepRuleInstaller.bootResetPlistPath == "/Library/LaunchDaemons/com.yaanfpv.cgmrelay.sleep-reset.plist")
    }

    @Test("sudoers rule is exactly the two pmset commands for the user")
    func ruleParsed() {
        let rule = SleepRuleInstaller.sudoersRule(user: "someone")
        let ruleLines = rule.split(separator: "\n", omittingEmptySubsequences: true)
            .map(String.init).filter { !$0.hasPrefix("#") }
        #expect(ruleLines.count == 1)
        let line = ruleLines[0]
        #expect(line.hasPrefix("someone ALL=(root) NOPASSWD: "))
        let commands = line.dropFirst("someone ALL=(root) NOPASSWD: ".count)
            .components(separatedBy: ", ")
        #expect(Set(commands) == [off, on])
        #expect(commands.count == 2)
        #expect(!rule.contains("*"))
        #expect(!commands.contains("ALL"))
    }

    @Test("sudoers rule exact text")
    func ruleExact() {
        let rule = SleepRuleInstaller.sudoersRule(user: "someone")
        let literal = "someone ALL=(root) NOPASSWD: /usr/bin/pmset -a disablesleep 0, /usr/bin/pmset -a disablesleep 1\n"
        #expect(rule.hasSuffix(literal))
        let prefix = rule.dropLast(literal.count)
        for line in prefix.split(separator: "\n") { #expect(line.hasPrefix("#")) }
    }

    @Test("boot reset plist runs one reset at load and nothing else")
    func plist() throws {
        let data = SleepRuleInstaller.bootResetPlist()
        let object = try PropertyListSerialization.propertyList(from: data, options: [], format: nil)
        let dict = try #require(object as? [String: Any])
        #expect(dict["Label"] as? String == "com.yaanfpv.cgmrelay.sleep-reset")
        #expect(dict["ProgramArguments"] as? [String] == ["/usr/bin/pmset", "-a", "disablesleep", "0"])
        #expect(dict["RunAtLoad"] as? Bool == true)
        #expect(dict["KeepAlive"] == nil)
        #expect(dict["StartInterval"] == nil)
    }

    @Test("install script validates the staged rule before anything reaches sudoersPath")
    func installOrder() throws {
        let script = SleepRuleInstaller.installScript(user: "someone")
        let check = try #require(script.range(of: "visudo -c"))
        let target = try #require(script.range(of: SleepRuleInstaller.sudoersPath))
        #expect(check.lowerBound < target.lowerBound, "sudoersPath must not appear before the visudo check")
        #expect(script.contains(on))
        #expect(script.contains(off))
        #expect(script.contains("440"))
        #expect(script.contains("644"))
        #expect(script.components(separatedBy: "root:wheel").count - 1 >= 2)
        #expect(script.contains(SleepRuleInstaller.bootResetPlistPath))
    }
}

// MARK: - Privileged writer

/// CountingRunner records every command it is asked to run. Its async `run`
/// always reports success and counts its use, so a caller that goes through
/// it is told apart from one that uses runOnCallingThread, which answers
/// with `syncResult` and records the thread it was called on.
private final class CountingRunner: BoundedProcessRunning, @unchecked Sendable {
    struct Call: Equatable {
        let executableURL: URL
        let arguments: [String]
        let standardInputData: Data
        let timeout: Duration
    }

    private let lock = NSLock()
    private var recorded: [Call] = []
    private var threads: [mach_port_t] = []
    private var asyncRunCount = 0
    private let syncResult: BoundedProcessResult
    private let asyncResult: BoundedProcessResult

    init(syncResult: BoundedProcessResult = .exited(0), asyncResult: BoundedProcessResult = .exited(0)) {
        self.syncResult = syncResult
        self.asyncResult = asyncResult
    }

    var calls: [[String]] { lock.withLock { recorded.map(\.arguments) } }
    var fullCalls: [Call] { lock.withLock { recorded } }
    var asyncRuns: Int { lock.withLock { asyncRunCount } }
    var callingThreads: [mach_port_t] { lock.withLock { threads } }

    func run(executableURL: URL, arguments: [String], standardInputData: Data, timeout: Duration) async -> BoundedProcessResult {
        lock.withLock {
            asyncRunCount += 1
            recorded.append(Call(executableURL: executableURL, arguments: arguments, standardInputData: standardInputData, timeout: timeout))
        }
        return asyncResult
    }

    func runOnCallingThread(executableURL: URL, arguments: [String], standardInputData: Data, timeout: Duration) -> BoundedProcessResult {
        let thread = pthread_mach_thread_np(pthread_self())
        lock.withLock {
            threads.append(thread)
            recorded.append(Call(executableURL: executableURL, arguments: arguments, standardInputData: standardInputData, timeout: timeout))
        }
        return syncResult
    }

    func runCapturingOutput(executableURL: URL, arguments: [String], standardInputData: Data, timeout: Duration) async -> BoundedProcessOutput {
        BoundedProcessOutput(result: await run(executableURL: executableURL, arguments: arguments, standardInputData: standardInputData, timeout: timeout), output: Data())
    }
}

/// onDedicatedThread runs body on a thread of its own and waits for it
/// without blocking one of Swift's pool threads, the way the app calls the
/// writer: the writer blocks until a pool task has run its command, so
/// calling it from a pool thread can starve that task.
private func onDedicatedThread<T: Sendable>(_ body: @escaping @Sendable () -> T) async -> T {
    await withCheckedContinuation { continuation in
        Thread { continuation.resume(returning: body()) }.start()
    }
}

@Suite("PrivilegedSleepSettingWriter")
struct PrivilegedSleepSettingWriterTests {
    @Test("without the rule file sudo never runs: off is a no-op, on is a clear error")
    func ruleMissing() async {
        let runner = CountingRunner()
        let writer = PrivilegedSleepSettingWriter(runner: runner, ruleExists: { false })
        let failures: [StayAwakeFailure?] = await onDedicatedThread {
            [false, true].map { on in
                do {
                    try writer.setDisableSleep(on)
                    return nil
                } catch {
                    return error as? StayAwakeFailure
                }
            }
        }
        #expect(failures == [nil, .permissionNotInstalled])
        #expect(runner.calls.isEmpty)
    }

    @Test("with the rule file it runs exactly sudo -n pmset -a disablesleep")
    func ruleThere() async throws {
        let runner = CountingRunner()
        let writer = PrivilegedSleepSettingWriter(runner: runner, ruleExists: { true })
        let outcome = await onDedicatedThread { Result { try writer.setDisableSleep(true); try writer.setDisableSleep(false) } }
        try outcome.get()
        #expect(runner.calls == [
            ["-n", "/usr/bin/pmset", "-a", "disablesleep", "1"],
            ["-n", "/usr/bin/pmset", "-a", "disablesleep", "0"],
        ])
    }

    @Test("the command runs on the thread that called the writer, and the runner's async entry is never used")
    func commandRunsOnCallingThread() async {
        let runner = CountingRunner()
        let writer = PrivilegedSleepSettingWriter(runner: runner, ruleExists: { true })
        let writerThread: mach_port_t = await onDedicatedThread {
            try? writer.setDisableSleep(true)
            try? writer.setDisableSleep(false)
            return pthread_mach_thread_np(pthread_self())
        }
        #expect(runner.asyncRuns == 0, "the write went through the async run")
        #expect(runner.callingThreads == [writerThread, writerThread])
    }

    @Test("the write succeeds only when the command itself exited 0", arguments: [
        BoundedProcessResult.exited(0),
        .exited(1),
        .exited(-9),
        .timedOut,
        .failedToLaunch,
    ])
    func outcomeFollowsTheCommandsExit(_ result: BoundedProcessResult) async {
        for on in [true, false] {
            let runner = CountingRunner(syncResult: result)
            let writer = PrivilegedSleepSettingWriter(runner: runner, ruleExists: { true })
            let failure: StayAwakeFailure? = await onDedicatedThread {
                do {
                    try writer.setDisableSleep(on)
                    return nil
                } catch {
                    return error as? StayAwakeFailure
                }
            }
            #expect(failure == (result == .exited(0) ? nil : .sleepSettingNotChanged), "result \(result) on \(on)")
        }
    }

    @Test("the command, its empty stdin and the timeout it was given are passed on unchanged")
    func commandAndTimeoutUnchanged() async {
        let runner = CountingRunner()
        let writer = PrivilegedSleepSettingWriter(runner: runner, timeout: .seconds(7), ruleExists: { true })
        await onDedicatedThread {
            try? writer.setDisableSleep(true)
            try? writer.setDisableSleep(false)
        }
        let sudo = URL(fileURLWithPath: "/usr/bin/sudo")
        #expect(runner.fullCalls == [
            .init(executableURL: sudo, arguments: ["-n", "/usr/bin/pmset", "-a", "disablesleep", "1"], standardInputData: Data(), timeout: .seconds(7)),
            .init(executableURL: sudo, arguments: ["-n", "/usr/bin/pmset", "-a", "disablesleep", "0"], standardInputData: Data(), timeout: .seconds(7)),
        ])
    }
}

@Suite("SleepRuleAdministrator installed check")
struct SleepRuleAdministratorInstalledTests {
    private func administrator(
        _ runner: CountingRunner, sudoers: Bool, plist: Bool
    ) -> SleepRuleAdministrator {
        SleepRuleAdministrator(runner: runner, userName: "tester", fileExists: { path in
            if path == SleepRuleInstaller.sudoersPath { return sudoers }
            if path == SleepRuleInstaller.bootResetPlistPath { return plist }
            return false
        })
    }

    @Test("sudo passes but CGM Relay's rule file is absent: not installed")
    func ruleFileAbsent() async {
        let runner = CountingRunner(asyncResult: .exited(0))
        let installed = await administrator(runner, sudoers: false, plist: true).isInstalled()
        #expect(!installed)
    }

    @Test("sudo passes, rule file present, boot reset job absent: not installed")
    func bootJobAbsent() async {
        let runner = CountingRunner(asyncResult: .exited(0))
        let installed = await administrator(runner, sudoers: true, plist: false).isInstalled()
        #expect(!installed)
    }

    @Test("both files present and sudo passes: installed")
    func bothAndSudoPasses() async {
        let runner = CountingRunner(asyncResult: .exited(0))
        let installed = await administrator(runner, sudoers: true, plist: true).isInstalled()
        #expect(installed)
        #expect(runner.fullCalls.map(\.arguments) == [["-n", "-l", "/usr/bin/pmset", "-a", "disablesleep", "0"]])
    }

    @Test("both files present and sudo fails: not installed", arguments: [
        BoundedProcessResult.exited(1), .timedOut, .failedToLaunch,
    ])
    func bothAndSudoFails(_ result: BoundedProcessResult) async {
        let runner = CountingRunner(asyncResult: result)
        let installed = await administrator(runner, sudoers: true, plist: true).isInstalled()
        #expect(!installed, "\(result)")
    }

    @Test("with either file absent sudo is not launched at all", arguments: [
        (false, false), (false, true), (true, false),
    ])
    func sudoNotRunWhenAFileIsMissing(sudoers: Bool, plist: Bool) async {
        let runner = CountingRunner(asyncResult: .exited(0))
        _ = await administrator(runner, sudoers: sudoers, plist: plist).isInstalled()
        #expect(runner.fullCalls.isEmpty, "sudoers \(sudoers) plist \(plist)")
        #expect(runner.asyncRuns == 0)
    }
}

// MARK: - Install decision

@Suite("SleepRuleSetup")
struct SleepRuleSetupTests {
    @Test("rules that read as not installed get exactly one install, and its outcome comes back", arguments: [
        SleepRuleOutcome.done, .cancelled, .failed,
    ])
    func installsOnceWhenMissing(_ outcome: SleepRuleOutcome) async {
        let rules = FakeSleepRules()
        rules.installed = false
        rules.installOutcome = outcome
        let result = await SleepRuleSetup.ensureInstalled(rules)
        #expect(result == outcome)
        #expect(rules.installCount == 1)
    }

    @Test("rules that read as installed get no install and .done, whatever install would have said", arguments: [
        SleepRuleOutcome.done, .cancelled, .failed,
    ])
    func noInstallWhenPresent(_ outcome: SleepRuleOutcome) async {
        let rules = FakeSleepRules()
        rules.installed = true
        rules.installOutcome = outcome
        let result = await SleepRuleSetup.ensureInstalled(rules)
        #expect(result == .done)
        #expect(rules.installCount == 0)
    }
}

// MARK: - Sleep reset helper

@Suite("SleepResetPolicy")
struct SleepResetPolicyTests {
    private let settings: [Bool?] = [true, false, nil]

    @Test("with the app not running, the setting on or unknown is written off, on power or on battery")
    func notRunningClearsAStuckSetting() {
        for onBattery in [false, true] {
            for disabled in [true, nil] as [Bool?] {
                #expect(
                    SleepResetPolicy.decide(appRunning: false, onBattery: onBattery, sleepDisabled: disabled) == .writeOff,
                    "app not running, onBattery \(onBattery), sleepDisabled \(String(describing: disabled))"
                )
            }
        }
    }

    @Test("with the app not running and the setting already off, nothing is written")
    func notRunningAndAlreadyOff() {
        for onBattery in [false, true] {
            #expect(
                SleepResetPolicy.decide(appRunning: false, onBattery: onBattery, sleepDisabled: false) == .leaveAlone,
                "onBattery \(onBattery)"
            )
        }
    }

    @Test("while the app runs the helper never writes, whatever the power source or the setting")
    func runningIsNeverOverridden() {
        for onBattery in [false, true] {
            for disabled in settings {
                #expect(
                    SleepResetPolicy.decide(appRunning: true, onBattery: onBattery, sleepDisabled: disabled) == .leaveAlone,
                    "app running, onBattery \(onBattery), sleepDisabled \(String(describing: disabled))"
                )
            }
        }
    }
}

@Suite("SleepResetHelper")
struct SleepResetHelperTests {
    @Test("the one command the helper may run is pmset -a disablesleep 0")
    func commandIsFixed() {
        #expect(SleepResetHelper.command == ["/usr/bin/pmset", "-a", "disablesleep", "0"])
    }

    @Test("the helper reads only the process list and the power source")
    func inputsAreTwo() {
        #expect(SleepResetHelper.inputs == [.processList, .powerSource])
    }

    @Test("the boot job runs the same single command as the helper")
    func bootJobMatchesHelper() throws {
        let plist = try #require(
            PropertyListSerialization.propertyList(from: SleepRuleInstaller.bootResetPlist(), format: nil) as? [String: Any]
        )
        #expect(plist["ProgramArguments"] as? [String] == SleepResetHelper.command)
    }
}

@Suite("SleepResetHelper bounded reset")
struct SleepResetHelperBoundedResetTests {
    @Test("the reset is done only for an exit with status 0", arguments: [
        (BoundedProcessResult.exited(0), SleepResetHelper.ResetOutcome.done),
        (.exited(1), .notDone),
        (.exited(-9), .notDone),
        (.timedOut, .notDone),
        (.failedToLaunch, .notDone),
        (.notConfirmedEnded, .mayStillRun),
    ])
    func outcomeFollowsTheRunnersResult(result: BoundedProcessResult, expected: SleepResetHelper.ResetOutcome) {
        let runner = CountingRunner(syncResult: result)
        #expect(SleepResetHelper.runReset(using: runner) == expected, "result \(result)")
    }

    @Test("the fixed command, an empty stdin and the named timeout go to the runner's calling-thread entry, once")
    func commandAndTimeoutPassedOn() {
        let runner = CountingRunner()
        _ = SleepResetHelper.runReset(using: runner)
        #expect(SleepResetHelper.resetTimeout == .seconds(10))
        #expect(runner.fullCalls == [
            .init(
                executableURL: URL(fileURLWithPath: SleepResetHelper.command[0]),
                arguments: Array(SleepResetHelper.command.dropFirst()),
                standardInputData: Data(),
                timeout: SleepResetHelper.resetTimeout
            ),
        ])
        #expect(runner.asyncRuns == 0, "the reset went through the async run")
    }

    private func looks(firstResult: SleepResetHelper.ResetOutcome, sleepDisabled: Bool?) -> Int {
        var look = SleepResetHelper.Look()
        var count = 0
        let command: () -> SleepResetHelper.ResetOutcome = {
            count += 1
            return count == 1 ? firstResult : .done
        }
        for _ in 0..<2 {
            look.run(appRunning: false, onBattery: true, sleepDisabled: sleepDisabled, runCommand: command)
        }
        look.powerSourceChanged()
        look.run(appRunning: false, onBattery: true, sleepDisabled: sleepDisabled, runCommand: command)
        // The app starting and stopping again does not clear it either.
        look.run(appRunning: true, onBattery: true, sleepDisabled: sleepDisabled, runCommand: command)
        look.run(appRunning: false, onBattery: true, sleepDisabled: sleepDisabled, runCommand: command)
        return count
    }

    @Test("after a run that may still be running, no further reset command is started on any later look",
          arguments: [true, false] as [Bool?])
    func noSecondCommandAfterMayStillRun(sleepDisabled: Bool?) {
        // sleepDisabled false never writes, so only the first two cases reach the command at all.
        let expected = (sleepDisabled == false) ? 0 : 1
        #expect(looks(firstResult: .mayStillRun, sleepDisabled: sleepDisabled) == expected)
    }

    @Test("a reset that is not done is tried again on the next look")
    func notDoneRetries() {
        #expect(looks(firstResult: .notDone, sleepDisabled: true) == 4)
    }

    @Test("a done reset with the sleep setting known does not stop later looks from writing")
    func doneKeepsLooking() {
        #expect(looks(firstResult: .done, sleepDisabled: true) == 4)
    }
}

@Suite("SleepResetHelper main.swift")
struct SleepResetHelperMainSourceTests {
    private static func strippingComments(_ source: String) -> String {
        var text = source
        while let open = text.range(of: "/*"), let close = text.range(of: "*/", range: open.upperBound..<text.endIndex) {
            text.removeSubrange(open.lowerBound..<close.upperBound)
        }
        return text.split(separator: "\n", omittingEmptySubsequences: false)
            .map { line -> Substring in
                guard let slashes = line.range(of: "//") else { return line }
                return line[line.startIndex..<slashes.lowerBound]
            }
            .joined(separator: "\n")
    }

    private static func helperSource() throws -> String {
        var url = URL(fileURLWithPath: #filePath)
        for _ in 0..<5 { url.deleteLastPathComponent() }
        let main = url.appendingPathComponent("Helper/main.swift")
        return strippingComments(try String(contentsOf: main, encoding: .utf8))
    }

    @Test("the helper waits on no child without a bound, and runs its reset through the bounded runner")
    func helperUsesTheBoundedRunner() throws {
        let source = try Self.helperSource()
        #expect(!source.contains("waitUntilExit"), "an unbounded wait is left in the helper")
        #expect(!source.contains("Process()"), "the helper starts a process of its own")
        #expect(source.contains("SleepResetHelper.runReset(using: RealBoundedProcessRunner())"))
    }
}

@Suite("SleepResetHelper process list")
struct SleepResetHelperProcessListTests {
    private static let appName = SleepResetHelper.appExecutableName
    private static let appPid: pid_t = 250

    /// listing builds a fake process list. fill mirrors proc_listallpids: it
    /// copies at most buffer.count pids, but never more than `cap`.
    private static func listing(
        population: Int, hint: Int32? = nil, cap: Int = .max, appPid: pid_t?, genuine: Bool = true
    ) -> SleepResetHelper.ProcessListing {
        let pids: [pid_t] = (1...Int32(population)).map { $0 }
        return SleepResetHelper.ProcessListing(
            countHint: { hint ?? Int32(population) },
            fill: { buffer in
                let n = min(buffer.count, cap, pids.count)
                for i in 0..<n { buffer[i] = pids[i] }
                return Int32(n)
            },
            executableName: { $0 == appPid ? appName : "other" },
            isGenuineApp: { $0 == appPid && genuine }
        )
    }

    /// writes feeds one listing through the helper's look three times (first
    /// look, interval, power change), the sleep setting on and the Mac on battery.
    private func writes(_ listing: SleepResetHelper.ProcessListing) -> Int {
        var look = SleepResetHelper.Look()
        var count = 0
        for _ in 0..<3 {
            look.run(
                appRunning: SleepResetHelper.appIsRunning(using: listing),
                onBattery: true, sleepDisabled: true, runCommand: { count += 1; return .done }
            )
        }
        return count
    }

    @Test("a list cut short, with the genuine app beyond the copied part, writes nothing on any look")
    func truncatedListWritesNothing() {
        let cut = Self.listing(population: 300, hint: 120, cap: 184, appPid: Self.appPid)
        #expect(SleepResetHelper.appIsRunning(using: cut) == true)
        #expect(writes(cut) == 0)
    }

    @Test("a list that grew past an honest fill still never writes while the app is beyond the copied part")
    func grownListWritesNothing() {
        let grown = Self.listing(population: 300, hint: 120, appPid: Self.appPid)
        #expect(writes(grown) == 0)
    }

    @Test("a list read whole with the genuine app writes nothing")
    func wholeListWithAppWritesNothing() {
        let whole = Self.listing(population: 120, appPid: 100)
        #expect(SleepResetHelper.appIsRunning(using: whole) == true)
        #expect(writes(whole) == 0)
    }

    @Test("a list read whole with no app allows the write on every look")
    func wholeListWithoutAppWrites() {
        let whole = Self.listing(population: 120, appPid: nil)
        #expect(SleepResetHelper.appIsRunning(using: whole) == false)
        #expect(writes(whole) == 3)
    }

    @Test("a list read whole with a same-named process that fails the signature check allows the write")
    func wholeListWithImpostorWrites() {
        let whole = Self.listing(population: 120, appPid: 100, genuine: false)
        #expect(SleepResetHelper.appIsRunning(using: whole) == false)
        #expect(writes(whole) == 3)
    }

    @Test("a copy that returns nothing after a positive count counts as the app running")
    func failedCopyCountsAsRunning() {
        let failed = SleepResetHelper.ProcessListing(
            countHint: { 120 }, fill: { _ in 0 }, executableName: { _ in nil }, isGenuineApp: { _ in false }
        )
        #expect(SleepResetHelper.appIsRunning(using: failed) == true)
        #expect(writes(failed) == 0)
    }

    @Test("a list that cannot be read at all counts as the app running")
    func unreadableListCountsAsRunning() {
        let none = SleepResetHelper.ProcessListing(
            countHint: { 0 }, fill: { _ in 0 }, executableName: { _ in nil }, isGenuineApp: { _ in false }
        )
        #expect(SleepResetHelper.appIsRunning(using: none) == true)
        #expect(writes(none) == 0)
    }
}

@Suite("StayAwakeCopy")
struct StayAwakeCopyTests {
    /// Every keep-awake string a person can see: the laptop and desktop
    /// explanation, the password line, the approval line and the notice for
    /// each way keeping the Mac awake can fail.
    private static let shown: [(name: String, text: String)] = [
        ("explanation laptop", StayAwakeCopy.explanation(isLaptop: true)),
        ("explanation desktop", StayAwakeCopy.explanation(isLaptop: false)),
        ("permissionNote", StayAwakeCopy.permissionNote),
        ("approvalNeeded", StayAwakeCopy.approvalNeeded),
        ("failure sleepSettingNotChanged", StayAwakeFailure.sleepSettingNotChanged.message),
        ("failure permissionNotInstalled", StayAwakeFailure.permissionNotInstalled.message),
        ("failure assertionNotHeld", StayAwakeFailure.assertionNotHeld.message),
        ("failure helperNotRegistered", StayAwakeFailure.helperNotRegistered.message),
    ]

    private static func sentences(_ text: String) -> [String] {
        var out: [String] = []
        var current = ""
        for ch in text {
            current.append(ch)
            if ch == "." || ch == "!" || ch == "?" {
                out.append(current.trimmingCharacters(in: .whitespaces))
                current = ""
            }
        }
        let rest = current.trimmingCharacters(in: .whitespaces)
        if !rest.isEmpty { out.append(rest) }
        return out
    }

    @Test("each keep-awake string is at most two sentences", arguments: shown.map(\.name))
    func atMostTwoSentences(name: String) {
        let text = Self.shown.first { $0.name == name }!.text
        let count = Self.sentences(text).count
        #expect(count >= 1 && count <= 2, "\(name) has \(count) sentences")
    }

    @Test("each sentence of each keep-awake string is at most 90 characters", arguments: shown.map(\.name))
    func sentencesAreShort(name: String) {
        let text = Self.shown.first { $0.name == name }!.text
        for sentence in Self.sentences(text) {
            #expect(sentence.count <= 90, "\(name): \(sentence.count) characters in \"\(sentence)\"")
        }
    }

    // The Settings footer is composed in the app target (GeneralPaneView),
    // which joins explanation and permissionNote with one space; the setup
    // caption uses the same package strings. So the footer is pinned here by
    // the package strings it joins.
    @Test("the Settings footer with keep-awake off is exactly the explanation then the password line")
    func footerText() {
        let footer = StayAwakeCopy.explanation(isLaptop: true) + " " + StayAwakeCopy.permissionNote
        #expect(footer == "Stays awake while plugged in, even with the lid closed. On battery it sleeps as usual. Asks for your password once.")
        #expect(StayAwakeCopy.approvalNeeded == "Allow CGM Relay in Login Items so this Mac can sleep after a crash.")
        #expect(!footer.contains(StayAwakeCopy.approvalNeeded))
    }

    @Test("the laptop explanation says plugged in, lid closed and sleeping on battery")
    func laptopExplanationClaims() {
        let text = StayAwakeCopy.explanation(isLaptop: true).lowercased()
        #expect(text.contains("plugged in"))
        #expect(text.contains("lid closed"))
        #expect(text.contains("battery"))
        #expect(text.contains("sleeps"))
    }

    @Test("the desktop explanation says the Mac won't sleep while CGM Relay runs")
    func desktopExplanationClaim() {
        #expect(StayAwakeCopy.explanation(isLaptop: false) == "This Mac won't sleep while CGM Relay runs.")
    }

    @Test("the permission note says the password is asked once and offers no way to remove it")
    func permissionNote() {
        let note = StayAwakeCopy.permissionNote.lowercased()
        #expect(note.contains("password"))
        #expect(note.contains("once"))
        #expect(!note.contains("remove"))
        #expect(!note.contains("revoke"))
        #expect(!note.contains("take that permission away"))
    }

    @Test("the approval line names Login Items and the crash case")
    func approvalClaims() {
        #expect(StayAwakeCopy.approvalNeeded.contains("Login Items"))
        #expect(StayAwakeCopy.approvalNeeded.lowercased().contains("crash"))
    }
}
