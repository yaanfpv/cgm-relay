import Testing
@testable import CGMRelayCore

@Suite("Settings commit validation")
struct SettingsCommitValidationTests {
    @Test("a port inside range commits", arguments: [1024, 1337, 65535])
    func validPortCommits(_ port: Int) {
        #expect(PortCommitValidation.validate(String(port)) == .valid(port))
    }

    @Test("a non-numeric or out-of-range port is refused with a message", arguments: ["", "abc", "1023", "65536", "-5", "13 37"])
    func invalidPortIsRefused(_ text: String) {
        guard case .invalid = PortCommitValidation.validate(text) else {
            Issue.record("expected .invalid for \(text.debugDescription)")
            return
        }
    }

    @Test("a retention value inside range commits", arguments: [1, 15, 90])
    func validRetentionCommits(_ days: Int) {
        #expect(RetentionCommitValidation.validate(String(days)) == .valid(days))
    }

    @Test("a non-numeric or out-of-range retention entry is refused with a message", arguments: ["", "abc", "0", "91"])
    func invalidRetentionIsRefused(_ text: String) {
        guard case .invalid = RetentionCommitValidation.validate(text) else {
            Issue.record("expected .invalid for \(text.debugDescription)")
            return
        }
    }

    @Test("lowering retention needs confirmation")
    func loweringNeedsConfirmation() {
        #expect(RetentionCommitDecision.decide(current: 15, new: 5) == .needsConfirmation)
    }

    @Test("raising or keeping retention the same commits immediately")
    func raisingOrEqualCommitsImmediately() {
        #expect(RetentionCommitDecision.decide(current: 15, new: 30) == .commitsImmediately)
        #expect(RetentionCommitDecision.decide(current: 15, new: 15) == .commitsImmediately)
    }

    @Test("leaving the pane with a pending entry saves a raise, holds a lowering or invalid text, and ignores an unchanged value")
    func leavingWithPendingEntry() {
        #expect(RetentionLeaveDecision.decide(current: 18, text: "19") == .save(19))
        #expect(RetentionLeaveDecision.decide(current: 18, text: " 90 ") == .save(90))
        #expect(RetentionLeaveDecision.decide(current: 18, text: "18") == .nothing)
        for text in ["13", "1"] {
            guard case .held(let message) = RetentionLeaveDecision.decide(current: 18, text: text) else {
                Issue.record("expected .held for lowering to \(text)")
                continue
            }
            #expect(message.contains("\(text) days was not saved"))
            #expect(message.contains("confirming"))
        }
        for text in ["", "abc", "0", "91"] {
            guard case .held(let message) = RetentionLeaveDecision.decide(current: 18, text: text) else {
                Issue.record("expected .held for \(text.debugDescription)")
                continue
            }
            #expect(message.hasPrefix("Not saved. "))
            #expect(message.contains("\(AppSettings.retentionDaysRange.lowerBound)"))
        }
    }

    @MainActor
    private final class Settled {
        var values: [Int] = []
    }

    @MainActor
    @Test("five quick down-clicks settle once, for the final value, only after the clicks stop")
    func quickClicksSettleOnce() async throws {
        let clock = FakeVirtualClock()
        let settled = Settled()
        let settler = RetentionChangeSettler(clock: clock) { settled.values.append($0) }
        for (index, value) in [14, 13, 12, 11, 10].enumerated() {
            settler.propose(value)
            #expect(await waitUntil { await clock.sleepRequests.count == index + 1 })
            await clock.advance(by: .milliseconds(200))
        }
        // 999 ms after the last click: still waiting, and the first click's
        // own wait (long past) must not have fired.
        await clock.advance(by: .milliseconds(799))
        try await Task.sleep(for: .milliseconds(30))
        #expect(settled.values.isEmpty)
        await clock.advance(by: .milliseconds(1))
        #expect(await waitUntil { await MainActor.run { settled.values == [10] } })
        try await Task.sleep(for: .milliseconds(30))
        #expect(settled.values == [10])
    }

    @MainActor
    @Test("focus leaving the row settles at once, and the cancelled wait never settles again")
    func flushSettlesOnceImmediately() async throws {
        let clock = FakeVirtualClock()
        let settled = Settled()
        let settler = RetentionChangeSettler(clock: clock) { settled.values.append($0) }
        settler.propose(9)
        settler.propose(8)
        settler.flush()
        #expect(settled.values == [8])
        await clock.advance(by: .seconds(5))
        try await Task.sleep(for: .milliseconds(30))
        #expect(settled.values == [8])
        settler.flush()
        #expect(settled.values == [8], "nothing pending, nothing settles")
    }

    @MainActor
    @Test("cancelling drops the pending value")
    func cancelDropsPending() async throws {
        let clock = FakeVirtualClock()
        let settled = Settled()
        let settler = RetentionChangeSettler(clock: clock) { settled.values.append($0) }
        settler.propose(7)
        settler.cancel()
        await clock.advance(by: .seconds(5))
        try await Task.sleep(for: .milliseconds(30))
        #expect(settled.values.isEmpty)
        #expect(settler.pendingValue == nil)
    }
}
