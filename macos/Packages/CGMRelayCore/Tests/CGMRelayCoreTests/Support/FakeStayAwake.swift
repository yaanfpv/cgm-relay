import Foundation
@testable import CGMRelayCore

/// One ordered record of every call the stay-awake fakes receive.
final class StayAwakeCallLog {
    private(set) var events: [String] = []
    func append(_ event: String) { events.append(event) }
    /// Returns what was recorded since the last drain and clears it.
    func drain() -> [String] {
        defer { events = [] }
        return events
    }
}

struct FakeWriteFailure: Error {}

final class FakePowerSource: PowerSourceReading {
    var current: PowerSnapshot
    init(_ snapshot: PowerSnapshot) { current = snapshot }
    func snapshot() -> PowerSnapshot { current }
}

final class FakeIdleSleepAsserter: IdleSleepAsserting {
    let log: StayAwakeCallLog
    var failNextHold = false
    init(log: StayAwakeCallLog) { self.log = log }
    func hold() throws {
        if failNextHold {
            failNextHold = false
            throw FakeWriteFailure()
        }
        log.append("hold")
    }
    func release() { log.append("release") }
}

/// FakeSleepSettingWriter keeps the setting it was last told, as the system
/// would, so a test can read what the Mac would end up doing. A write can
/// fail without having happened (a command that never launched), or take
/// effect and then throw (a command that timed out after it ran).
final class FakeSleepSettingWriter: SleepSettingWriting {
    let log: StayAwakeCallLog
    var failNextWrite = false
    var failNextWriteAfterEffect = false
    var failEveryWrite = false
    private(set) var setting = false
    private(set) var attempts = 0
    init(log: StayAwakeCallLog) { self.log = log }
    func setDisableSleep(_ on: Bool) throws {
        attempts += 1
        if failEveryWrite {
            throw FakeWriteFailure()
        }
        if failNextWrite {
            failNextWrite = false
            throw FakeWriteFailure()
        }
        setting = on
        if failNextWriteAfterEffect {
            failNextWriteAfterEffect = false
            throw FakeWriteFailure()
        }
        log.append("setDisableSleep(\(on))")
    }
}
