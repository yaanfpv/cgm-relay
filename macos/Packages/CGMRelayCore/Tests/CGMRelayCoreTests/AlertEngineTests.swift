import Testing
import Foundation
@testable import CGMRelayCore

@Suite("AlertEngine")
struct AlertEngineTests {
    @Test("the no-reading alert fires once at the threshold, not again during the same gap, fires again after recovery and a second gap")
    func noReadingAlertFiresOncePerEpisode() async throws {
        let clock = FakeVirtualClock()
        let engine = AlertEngine(clock: clock)
        await engine.setNoReadingAlert(enabled: true, minutes: 20)

        let firstReading = Date(timeIntervalSince1970: 1_800_000_000)
        let status = EngineStatus(running: true, lastReadingTime: firstReading, lastReadingMgDl: 100)

        // The gap opens: the same reading keeps being reported as the clock advances.
        #expect(await engine.handleStatusUpdate(status).isEmpty)
        await clock.advance(by: .seconds(19 * 60))
        #expect(await engine.handleStatusUpdate(status).isEmpty, "must not fire before the threshold")

        await clock.advance(by: .seconds(2 * 60))
        let fired = await engine.handleStatusUpdate(status)
        #expect(fired == [.noReading])

        // Continued gap: no second alert.
        await clock.advance(by: .seconds(30 * 60))
        #expect(await engine.handleStatusUpdate(status).isEmpty, "must not fire twice for the same gap")

        // Recovery: a new reading arrives.
        let secondReading = firstReading.addingTimeInterval(25 * 60)
        let recovered = EngineStatus(running: true, lastReadingTime: secondReading, lastReadingMgDl: 105)
        #expect(await engine.handleStatusUpdate(recovered).isEmpty)

        // Second gap: the same reading keeps being reported again.
        await clock.advance(by: .seconds(21 * 60))
        let secondFired = await engine.handleStatusUpdate(recovered)
        #expect(secondFired == [.noReading], "a fresh gap must fire its own alert")
    }

    @Test("the no-reading alert never fires while disabled")
    func noReadingAlertNeverFiresWhileDisabled() async throws {
        let clock = FakeVirtualClock()
        let engine = AlertEngine(clock: clock)

        let status = EngineStatus(running: true, lastReadingTime: Date(), lastReadingMgDl: 100)
        #expect(await engine.handleStatusUpdate(status).isEmpty)
        await clock.advance(by: .seconds(2 * 3600))
        #expect(await engine.handleStatusUpdate(status).isEmpty)
    }

    @Test("turning the no-reading alert back on starts counting a fresh gap")
    func reEnablingStartsAFreshGap() async throws {
        let clock = FakeVirtualClock()
        let engine = AlertEngine(clock: clock)
        await engine.setNoReadingAlert(enabled: true, minutes: 20)

        let status = EngineStatus(running: true, lastReadingTime: Date(timeIntervalSince1970: 1_800_000_000), lastReadingMgDl: 100)
        // Establishes the gap from elapsed time zero, exactly as
        // production would: a status update reaches AppModel roughly
        // every 30s, long before any real gap could open.
        #expect(await engine.handleStatusUpdate(status).isEmpty)

        await clock.advance(by: .seconds(25 * 60))
        #expect(await engine.handleStatusUpdate(status) == [.noReading])

        await engine.setNoReadingAlert(enabled: false, minutes: 20)
        await engine.setNoReadingAlert(enabled: true, minutes: 20)

        // Immediately after re-enabling, the gap must not already be past
        // the threshold merely because the clock kept advancing while it
        // was off: the very next call starts a fresh gap at the current
        // elapsed time, so it must not fire again right away.
        #expect(await engine.handleStatusUpdate(status).isEmpty)
    }

    @Test("the sign-in alert fires once per episode: fails, continues failing (no second alert), recovers, fails again (second alert)")
    func signInAlertFiresOncePerEpisode() async throws {
        let clock = FakeVirtualClock()
        let engine = AlertEngine(clock: clock)
        await engine.setSignInFailingAlert(enabled: true)

        let failing = EngineStatus(running: true, signInFailing: true)
        let ok = EngineStatus(running: true, signInFailing: false)

        #expect(await engine.handleStatusUpdate(failing) == [.signInFailing])
        #expect(await engine.handleStatusUpdate(failing).isEmpty, "must not fire twice for the same episode")
        #expect(await engine.handleStatusUpdate(ok).isEmpty, "recovery itself never fires an alert")
        #expect(await engine.handleStatusUpdate(failing) == [.signInFailing], "a fresh failure after recovery must fire again")
    }

    @Test("the sign-in alert never fires while disabled")
    func signInAlertNeverFiresWhileDisabled() async throws {
        let clock = FakeVirtualClock()
        let engine = AlertEngine(clock: clock)

        let failing = EngineStatus(running: true, signInFailing: true)
        #expect(await engine.handleStatusUpdate(failing).isEmpty)
    }

    @Test("pausing for a deliberate stop suspends the no-reading gap even across nil statuses, and resuming starts a fresh gap")
    func pauseForStopSuspendsNoReadingGap() async throws {
        let clock = FakeVirtualClock()
        let engine = AlertEngine(clock: clock)
        await engine.setNoReadingAlert(enabled: true, minutes: 20)

        let reading = Date(timeIntervalSince1970: 1_800_000_000)
        let status = EngineStatus(running: true, lastReadingTime: reading, lastReadingMgDl: 100)
        #expect(await engine.handleStatusUpdate(status).isEmpty)
        await clock.advance(by: .seconds(15 * 60))

        await engine.pauseForEngineStop()

        // While paused, even far past the threshold and with no readings
        // at all (nil statuses, exactly what a stopped engine's failed
        // polls report), nothing fires.
        await clock.advance(by: .seconds(60 * 60))
        #expect(await engine.handleStatusUpdate(nil).isEmpty, "must not fire while paused for a deliberate stop")
        #expect(await engine.handleStatusUpdate(nil).isEmpty)

        await engine.resumeAfterEngineStart()

        // Immediately after resuming, the gap must not already be past
        // the threshold merely because the clock kept advancing while
        // paused.
        #expect(await engine.handleStatusUpdate(nil).isEmpty)

        await clock.advance(by: .seconds(21 * 60))
        #expect(await engine.handleStatusUpdate(nil) == [.noReading], "a fresh gap after resuming must still fire once it reopens")
    }

    @Test("a nil status (a failed poll) never resets or fires the no-reading gap on its own")
    func nilStatusNeitherResetsNorFires() async throws {
        let clock = FakeVirtualClock()
        let engine = AlertEngine(clock: clock)
        await engine.setNoReadingAlert(enabled: true, minutes: 20)

        let status = EngineStatus(running: true, lastReadingTime: Date(), lastReadingMgDl: 100)
        #expect(await engine.handleStatusUpdate(status).isEmpty)

        await clock.advance(by: .seconds(10 * 60))
        #expect(await engine.handleStatusUpdate(nil).isEmpty)

        await clock.advance(by: .seconds(11 * 60))
        #expect(await engine.handleStatusUpdate(nil) == [.noReading], "the gap that started at the last real reading must still fire")
    }
}
