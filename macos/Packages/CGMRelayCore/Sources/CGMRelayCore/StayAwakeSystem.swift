import Foundation
import IOKit.ps
import IOKit.pwr_mgt

/// SystemPowerSource reads the power state from IOKit: a Mac is a laptop
/// when it has an internal battery, and runs on mains power when that is
/// what provides its power. A Mac without a battery is always on mains
/// power.
public struct SystemPowerSource: PowerSourceReading {
    public init() {}

    public func snapshot() -> PowerSnapshot {
        guard let info = IOPSCopyPowerSourcesInfo()?.takeRetainedValue(),
              let list = IOPSCopyPowerSourcesList(info)?.takeRetainedValue() as? [CFTypeRef]
        else {
            return PowerSnapshot(isLaptop: false, onACPower: true)
        }
        let isLaptop = list.contains { source in
            guard let description = IOPSGetPowerSourceDescription(info, source)?.takeUnretainedValue() as? [String: Any] else {
                return false
            }
            return description[kIOPSTypeKey] as? String == kIOPSInternalBatteryType
        }
        guard isLaptop else { return PowerSnapshot(isLaptop: false, onACPower: true) }
        let providing = IOPSGetProvidingPowerSourceType(info)?.takeUnretainedValue() as String?
        return PowerSnapshot(isLaptop: true, onACPower: providing == kIOPSACPowerValue)
    }
}

/// SystemIdleSleepAssertion holds the system's "prevent idle sleep"
/// assertion, which keeps the Mac awake while nobody is using it. It does
/// not keep a laptop awake with its lid closed; the sleep setting does.
public final class SystemIdleSleepAssertion: IdleSleepAsserting {
    private var assertionID = IOPMAssertionID(kIOPMNullAssertionID)

    public init() {}

    public func hold() throws {
        guard assertionID == IOPMAssertionID(kIOPMNullAssertionID) else { return }
        var created = IOPMAssertionID(kIOPMNullAssertionID)
        let status = IOPMAssertionCreateWithName(
            kIOPMAssertPreventUserIdleSystemSleep as CFString,
            IOPMAssertionLevel(kIOPMAssertionLevelOn),
            "CGM Relay is relaying readings" as CFString,
            &created
        )
        guard status == kIOReturnSuccess else { throw StayAwakeFailure.assertionNotHeld }
        assertionID = created
    }

    public func release() {
        guard assertionID != IOPMAssertionID(kIOPMNullAssertionID) else { return }
        IOPMAssertionRelease(assertionID)
        assertionID = IOPMAssertionID(kIOPMNullAssertionID)
    }

    deinit { release() }
}

/// PrivilegedSleepSettingWriter changes the sleep setting through the
/// sudoers rule SleepRuleInstaller put in place, using `sudo -n` so a
/// missing rule is an error at once and never a password prompt waiting for
/// a keyboard. Without the rule file sudo is not run at all: turning the
/// setting off then needs nothing (nothing could have turned it on), and
/// turning it on is an error. Otherwise the call blocks until the command
/// finishes or its time is up: at most the timeout, plus the runner's 2 s
/// to end a child that ignores the request, plus a 1 s margin before this
/// stops waiting.
public struct PrivilegedSleepSettingWriter: SleepSettingWriting {
    private let runner: any BoundedProcessRunning
    private let timeout: Duration
    private let ruleExists: @Sendable () -> Bool

    public init(
        runner: any BoundedProcessRunning = RealBoundedProcessRunner(),
        timeout: Duration = .seconds(3),
        ruleExists: @escaping @Sendable () -> Bool = {
            FileManager.default.fileExists(atPath: SleepRuleInstaller.sudoersPath)
        }
    ) {
        self.runner = runner
        self.timeout = timeout
        self.ruleExists = ruleExists
    }

    public func setDisableSleep(_ on: Bool) throws {
        guard ruleExists() else {
            if on { throw StayAwakeFailure.permissionNotInstalled }
            return
        }
        let runner = runner
        let timeout = timeout
        let arguments = ["-n", "/usr/bin/pmset", "-a", "disablesleep", on ? "1" : "0"]
        let outcome = BlockingResult()
        Task.detached {
            let result = await runner.run(
                executableURL: URL(fileURLWithPath: "/usr/bin/sudo"),
                arguments: arguments,
                standardInputData: Data(),
                timeout: timeout
            )
            outcome.finish(result)
        }
        guard outcome.wait(seconds: Double(timeout.components.seconds) + 3) == .exited(0) else { throw StayAwakeFailure.sleepSettingNotChanged }
    }
}

/// BlockingResult hands one value from a task to a thread that waits for it.
private final class BlockingResult: @unchecked Sendable {
    private let done = DispatchSemaphore(value: 0)
    private let lock = NSLock()
    private var value: BoundedProcessResult = .failedToLaunch

    func finish(_ result: BoundedProcessResult) {
        lock.withLock { value = result }
        done.signal()
    }

    func wait(seconds: Double) -> BoundedProcessResult {
        guard done.wait(timeout: .now() + seconds) == .success else { return .timedOut }
        return lock.withLock { value }
    }
}

/// PowerSourceWatcher calls its handler on the main thread whenever the
/// power source changes (a charger plugged in or pulled out, a battery
/// level step). It reads nothing itself.
@MainActor
public final class PowerSourceWatcher {
    private var source: CFRunLoopSource?
    private let handler: @MainActor () -> Void

    public init(handler: @escaping @MainActor () -> Void) {
        self.handler = handler
    }

    public func start() {
        guard source == nil else { return }
        let context = Unmanaged.passUnretained(self).toOpaque()
        guard let created = IOPSNotificationCreateRunLoopSource({ context in
            guard let context else { return }
            let watcher = Unmanaged<PowerSourceWatcher>.fromOpaque(context)
            MainActor.assumeIsolated { watcher.takeUnretainedValue().handler() }
        }, context)?.takeRetainedValue() else { return }
        CFRunLoopAddSource(CFRunLoopGetMain(), created, .commonModes)
        source = created
    }

    public func stop() {
        guard let source else { return }
        CFRunLoopRemoveSource(CFRunLoopGetMain(), source, .commonModes)
        self.source = nil
    }
}

/// SleepRuleOutcome is how running an installer script ended.
public enum SleepRuleOutcome: Equatable, Sendable {
    case done
    /// The person closed the password prompt.
    case cancelled
    case failed
}

/// SleepRuleManaging installs and removes the permission, and says whether
/// it is there.
public protocol SleepRuleManaging: Sendable {
    func isInstalled() async -> Bool
    func install() async -> SleepRuleOutcome
    func remove() async -> SleepRuleOutcome
}

/// SleepRuleAdministrator runs SleepRuleInstaller's scripts as root through
/// one administrator prompt, and only when called, which the app does on the
/// person's click.
public struct SleepRuleAdministrator: SleepRuleManaging {
    private let runner: any BoundedProcessRunning
    private let userName: String

    /// The prompt waits for a person to type, so its time is generous.
    private static let promptTimeout: Duration = .seconds(180)

    public init(runner: any BoundedProcessRunning = RealBoundedProcessRunner(), userName: String = NSUserName()) {
        self.runner = runner
        self.userName = userName
    }

    /// isInstalled asks sudo, without a password, whether it would run the
    /// command the app uses.
    public func isInstalled() async -> Bool {
        let result = await runner.run(
            executableURL: URL(fileURLWithPath: "/usr/bin/sudo"),
            arguments: ["-n", "-l", "/usr/bin/pmset", "-a", "disablesleep", "0"],
            standardInputData: Data(),
            timeout: .seconds(5)
        )
        return result == .exited(0)
    }

    public func install() async -> SleepRuleOutcome {
        guard SleepRuleInstaller.isSafeUserName(userName) else { return .failed }
        return await runAsAdministrator(SleepRuleInstaller.installScript(user: userName))
    }

    public func remove() async -> SleepRuleOutcome {
        await runAsAdministrator(SleepRuleInstaller.removeScript())
    }

    private func runAsAdministrator(_ script: String) async -> SleepRuleOutcome {
        let output = await runner.runCapturingOutput(
            executableURL: URL(fileURLWithPath: "/usr/bin/osascript"),
            arguments: ["-e", Self.appleScript(running: script)],
            standardInputData: Data(),
            timeout: Self.promptTimeout
        )
        switch output.result {
        case .exited(0):
            return .done
        case .exited:
            // AppleScript reports a closed prompt as error -128.
            return String(decoding: output.output, as: UTF8.self).contains("-128") ? .cancelled : .failed
        case .timedOut, .failedToLaunch:
            return .failed
        }
    }

    /// appleScript is the one `do shell script` line that runs script as
    /// root, with backslashes and quotes escaped for an AppleScript string.
    static func appleScript(running script: String) -> String {
        let escaped = script
            .replacingOccurrences(of: "\\", with: "\\\\")
            .replacingOccurrences(of: "\"", with: "\\\"")
        return "do shell script \"\(escaped)\" with administrator privileges"
    }
}
