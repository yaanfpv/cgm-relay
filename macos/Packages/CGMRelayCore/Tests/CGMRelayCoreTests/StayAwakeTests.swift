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

@Suite("StayAwakeController")
struct StayAwakeControllerTests {
    private struct Rig {
        let log = StayAwakeCallLog()
        let power: FakePowerSource
        let idle: FakeIdleSleepAsserter
        let sleep: FakeSleepSettingWriter
        let controller: StayAwakeController

        init(choice: StayAwakeChoice?, power snapshot: PowerSnapshot) {
            let log = self.log
            power = FakePowerSource(snapshot)
            idle = FakeIdleSleepAsserter(log: log)
            sleep = FakeSleepSettingWriter(log: log)
            controller = StayAwakeController(choice: choice, power: power, assertion: idle, sleepSetting: sleep)
        }
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

    @Test("remove script resets sleep before removing either path")
    func removeOrder() throws {
        let script = SleepRuleInstaller.removeScript()
        let reset = try #require(script.range(of: "pmset -a disablesleep 0"))
        let rule = try #require(script.range(of: SleepRuleInstaller.sudoersPath))
        let plist = try #require(script.range(of: SleepRuleInstaller.bootResetPlistPath))
        #expect(reset.lowerBound < rule.lowerBound)
        #expect(reset.lowerBound < plist.lowerBound)
    }
}

// MARK: - Privileged writer

private final class CountingRunner: BoundedProcessRunning, @unchecked Sendable {
    private let lock = NSLock()
    private var recorded: [[String]] = []
    var calls: [[String]] { lock.withLock { recorded } }

    func run(executableURL: URL, arguments: [String], standardInputData: Data, timeout: Duration) async -> BoundedProcessResult {
        lock.withLock { recorded.append(arguments) }
        return .exited(0)
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
}
