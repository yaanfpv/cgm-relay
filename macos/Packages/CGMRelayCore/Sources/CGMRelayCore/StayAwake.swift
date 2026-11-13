import Foundation

/// PowerSnapshot is what the Mac says about its power right now: whether it
/// is a laptop (it has an internal battery) and whether it is running on
/// mains power. A desktop is always on mains power, since it has no battery
/// to protect.
public struct PowerSnapshot: Equatable, Sendable {
    public var isLaptop: Bool
    public var onACPower: Bool

    public init(isLaptop: Bool, onACPower: Bool) {
        self.isLaptop = isLaptop
        self.onACPower = onACPower
    }
}

/// PowerSourceReading reads the Mac's current power state.
public protocol PowerSourceReading {
    func snapshot() -> PowerSnapshot
}

/// IdleSleepAsserting holds and releases the assertion that keeps the Mac
/// from going to sleep on its own while it is not being used. Holding twice
/// is the same as holding once.
public protocol IdleSleepAsserting {
    func hold() throws
    func release()
}

/// SleepSettingWriting changes the system's "disable sleep" setting, which
/// is what keeps a laptop awake with its lid closed. It may block for a
/// few seconds, and throws when the change was not made.
public protocol SleepSettingWriting {
    func setDisableSleep(_ on: Bool) throws
}

/// StayAwakeTarget is what the Mac should be doing about sleep.
public struct StayAwakeTarget: Equatable, Sendable {
    public var holdIdleAssertion: Bool
    public var disableSleep: Bool

    public init(holdIdleAssertion: Bool, disableSleep: Bool) {
        self.holdIdleAssertion = holdIdleAssertion
        self.disableSleep = disableSleep
    }
}

/// StayAwakePolicy is the one rule for staying awake: only while the person
/// chose it, the relay is running and the Mac is on mains power. The idle
/// assertion follows that on any Mac; the setting that survives a closed
/// lid applies only to a laptop.
public enum StayAwakePolicy {
    public static func decide(choice: StayAwakeChoice?, relayRunning: Bool, power: PowerSnapshot) -> StayAwakeTarget {
        let active = choice == .on && relayRunning && power.onACPower
        return StayAwakeTarget(holdIdleAssertion: active, disableSleep: active && power.isLaptop)
    }
}

/// StayAwakeFailure is why the Mac could not be kept awake as chosen, for
/// the app to explain.
public enum StayAwakeFailure: Error, Equatable, Sendable {
    /// The sleep setting could not be changed: the command did not finish
    /// or was refused.
    case sleepSettingNotChanged
    /// The permission CGM Relay asks for at setup is not installed.
    case permissionNotInstalled
    /// The idle sleep assertion could not be taken.
    case assertionNotHeld

    public var message: String {
        switch self {
        case .sleepSettingNotChanged:
            "CGM Relay isn't allowed to change the sleep setting, so the Mac may sleep with its lid closed. Turn Keep this Mac awake off and on again to allow it."
        case .permissionNotInstalled:
            "CGM Relay doesn't have permission to change the sleep setting, so the Mac may sleep with its lid closed. Turn Keep this Mac awake off and on again to allow it."
        case .assertionNotHeld:
            "The Mac couldn't be kept awake right now. CGM Relay tries again whenever something changes."
        }
    }
}

/// StayAwakeController applies StayAwakePolicy through its two writers
/// whenever anything it depends on changes, and calls a writer only when
/// what it wants differs from what it last managed to apply. A write that
/// failed is not counted as applied, so the next change tries it again.
///
/// It is told what happened (the relay started or stopped, the power source
/// changed, the person changed the choice, the app launched or is quitting)
/// and does no observing of its own. Calls are serialized by a lock, so
/// willQuitInBackground may run off the main thread while the power
/// watcher keeps calling on it; onFailure is called with that lock held and
/// must only hand the failure on. "The relay is running" includes the engine restarting by itself;
/// the caller reports a stop only when the relay really stops.
public final class StayAwakeController: @unchecked Sendable {
    private let lock = NSLock()
    private var choice: StayAwakeChoice?
    private var relayRunning = false
    private var snapshot: PowerSnapshot

    private let power: any PowerSourceReading
    private let assertion: any IdleSleepAsserting
    private let sleepSetting: any SleepSettingWriting

    private var holding = false
    /// appliedDisableSleep is the last value written successfully, nil
    /// before any write.
    private var appliedDisableSleep: Bool?

    /// onFailure hears each failure while the person's choice is on; with
    /// the choice off or unasked, a failure changes nothing for them and is
    /// not reported.
    public var onFailure: ((StayAwakeFailure) -> Void)?

    public init(
        choice: StayAwakeChoice?,
        power: any PowerSourceReading,
        assertion: any IdleSleepAsserting,
        sleepSetting: any SleepSettingWriting
    ) {
        self.choice = choice
        self.power = power
        self.assertion = assertion
        self.sleepSetting = sleepSetting
        snapshot = power.snapshot()
    }

    /// relayStarted: the relay is running, or running again after a
    /// restart of its own.
    public func relayStarted() {
        lock.lock(); defer { lock.unlock() }
        relayRunning = true
        apply(refreshingPower: true)
    }

    /// relayStopped: the person stopped the relay, or it gave up.
    public func relayStopped() {
        lock.lock(); defer { lock.unlock() }
        relayRunning = false
        apply(refreshingPower: true)
    }

    /// powerChanged: the power source changed to snapshot.
    public func powerChanged(_ snapshot: PowerSnapshot) {
        lock.lock(); defer { lock.unlock() }
        self.snapshot = snapshot
        apply(refreshingPower: false)
    }

    /// choiceChanged: the person answered the stay-awake question.
    public func choiceChanged(_ choice: StayAwakeChoice?) {
        lock.lock(); defer { lock.unlock() }
        self.choice = choice
        apply(refreshingPower: true)
    }

    /// launched: the app has started and has its saved choice. With the
    /// choice on and the relay already running this sets everything again;
    /// otherwise it makes sure the setting is off.
    public func launched() {
        lock.lock(); defer { lock.unlock() }
        apply(refreshingPower: true)
    }

    /// willQuit: the app is really quitting. Everything is released, and
    /// the setting is written off even when it already reads off, so a
    /// write that failed earlier cannot leave it on.
    public func willQuit() {
        lock.lock(); defer { lock.unlock() }
        relayRunning = false
        let wrote = apply(refreshingPower: true)
        let mayBeOn = appliedDisableSleep == true
        if !wrote, mayBeOn || (choice == .on && snapshot.isLaptop) {
            write(false)
        }
    }

    /// willQuitInBackground is willQuit run off the calling thread and
    /// awaited, so a slow privileged write never holds the main thread. Its
    /// time is bounded by the writer's.
    public func willQuitInBackground() async {
        await Task.detached { self.willQuit() }.value
    }

    /// apply returns whether it wrote the sleep setting.
    @discardableResult
    private func apply(refreshingPower: Bool) -> Bool {
        if refreshingPower { snapshot = power.snapshot() }
        let target = StayAwakePolicy.decide(choice: choice, relayRunning: relayRunning, power: snapshot)

        if target.holdIdleAssertion != holding {
            if target.holdIdleAssertion {
                do {
                    try assertion.hold()
                    holding = true
                } catch {
                    report(.assertionNotHeld)
                }
            } else {
                assertion.release()
                holding = false
            }
        }

        // A Mac with no battery never needed the setting changed, so with
        // nothing written yet there is nothing to put back.
        let known = appliedDisableSleep ?? (snapshot.isLaptop ? nil : false)
        guard known != target.disableSleep else { return false }
        write(target.disableSleep)
        return true
    }

    private func write(_ on: Bool) {
        do {
            try sleepSetting.setDisableSleep(on)
            appliedDisableSleep = on
        } catch {
            report(.sleepSettingNotChanged)
        }
    }

    private func report(_ failure: StayAwakeFailure) {
        if choice == .on { onFailure?(failure) }
    }
}
