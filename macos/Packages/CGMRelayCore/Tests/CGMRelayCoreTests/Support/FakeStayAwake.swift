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

final class FakeSleepSettingWriter: SleepSettingWriting {
    let log: StayAwakeCallLog
    var failNextWrite = false
    init(log: StayAwakeCallLog) { self.log = log }
    func setDisableSleep(_ on: Bool) throws {
        if failNextWrite {
            failNextWrite = false
            throw FakeWriteFailure()
        }
        log.append("setDisableSleep(\(on))")
    }
}
