import Testing
import Foundation
@testable import CGMRelayCore

@Suite("MenuDisplayState mapping")
struct MenuDisplayStateTests {
    static let now = Date(timeIntervalSince1970: 1_800_000_000)

    @Test("setup needed takes priority over every other input")
    func setupNeeded() {
        let state = MenuDisplayState.make(
            credentialsConfigured: false,
            engineState: .running,
            status: EngineStatus(running: true, lastReadingTime: Self.now, lastReadingMgDl: 120),
            now: Self.now
        )
        #expect(state.dot == .grey)
        #expect(state.statusLine == "Setup needed")
    }

    @Test("engine stopped shows red even with a recent reading on file")
    func engineStopped() {
        let status = EngineStatus(running: true, lastReadingTime: Self.now.addingTimeInterval(-30), lastReadingMgDl: 110)
        let state = MenuDisplayState.make(credentialsConfigured: true, engineState: .stopped, status: status, now: Self.now)
        #expect(state.dot == .red)
        #expect(state.statusLine == "Stopped")
        #expect(state.readingLine.contains("110 mg/dL"))
    }

    @Test("starting never shows Stopped: it shows its own amber state, keeping any reading already on file")
    func starting() {
        let status = EngineStatus(running: true, lastReadingTime: Self.now.addingTimeInterval(-30), lastReadingMgDl: 110)
        let state = MenuDisplayState.make(credentialsConfigured: true, engineState: .starting, status: status, now: Self.now)
        #expect(state.dot == .amber)
        #expect(state.statusLine == "Starting…")
        #expect(state.statusLine != "Stopped")
        #expect(state.readingLine.contains("110 mg/dL"))
    }

    @Test("waiting to restart never shows Stopped: it shows its own state, keeping any reading already on file")
    func waitingToRestart() {
        let status = EngineStatus(running: true, lastReadingTime: Self.now.addingTimeInterval(-30), lastReadingMgDl: 110)
        let state = MenuDisplayState.make(
            credentialsConfigured: true,
            engineState: .waitingToRestart(attempt: 1, delay: .seconds(2)),
            status: status,
            now: Self.now
        )
        #expect(state.dot == .red)
        #expect(state.statusLine == "Restarting…")
        #expect(state.statusLine != "Stopped")
        #expect(state.readingLine.contains("110 mg/dL"))
    }

    @Test("a permanently failed store key mismatch names the problem in plain words, never engine jargon or the exit status")
    func storeKeyMismatchFailure() {
        let state = MenuDisplayState.make(credentialsConfigured: true, engineState: .failed(.storeKeyMismatch), status: nil, now: Self.now)
        #expect(state.dot == .red)
        #expect(state.statusLine == "Saved readings can't be opened")
        #expect(state.readingLine == "They were saved with a key this Mac no longer has.")
        for forbidden in ["engine", "store", "key mismatch", "exit status", "exit code"] {
            #expect(!state.statusLine.lowercased().contains(forbidden))
            #expect(!state.readingLine.lowercased().contains(forbidden))
        }
    }

    @Test("a saved configuration that can't be read names the problem in plain words, never engine jargon or the exit status")
    func configurationUnreadableFailure() {
        let state = MenuDisplayState.make(credentialsConfigured: true, engineState: .failed(.configurationUnreadable), status: nil, now: Self.now)
        #expect(state.dot == .red)
        #expect(state.statusLine == "Can't read your saved settings")
        #expect(state.readingLine == "Try again. If it keeps happening, quit and reopen CGM Relay.")
        for forbidden in ["engine", "store", "keychain item", "configuration", "exit"] {
            #expect(!state.statusLine.lowercased().contains(forbidden))
            #expect(!state.readingLine.lowercased().contains(forbidden))
        }
    }

    @Test("a failed recovery move names the problem in plain words, never engine jargon or the exit status")
    func recoveryMoveFailedFailure() {
        let state = MenuDisplayState.make(credentialsConfigured: true, engineState: .failed(.recoveryMoveFailed), status: nil, now: Self.now)
        #expect(state.dot == .red)
        #expect(state.statusLine == "Couldn't move the saved readings aside")
        #expect(state.readingLine == "Check that CGM Relay can write to its own folder, then try Start Fresh again.")
        for forbidden in ["engine", "store", "keychain item", "configuration", "exit"] {
            #expect(!state.statusLine.lowercased().contains(forbidden))
            #expect(!state.readingLine.lowercased().contains(forbidden))
        }
    }

    @Test("another copy already holding the database names the problem in terms of another copy of the app, never lock jargon or the exit status")
    func storeInUseFailure() {
        let state = MenuDisplayState.make(credentialsConfigured: true, engineState: .failed(.storeInUse), status: nil, now: Self.now)
        #expect(state.dot == .red)
        #expect(state.statusLine == "CGM Relay is already running")
        #expect(state.readingLine == "Another copy is using your saved readings. Quit this one.")
        for forbidden in ["engine", "store", "lock", "flock", "exit status", "exit code"] {
            #expect(!state.statusLine.lowercased().contains(forbidden))
            #expect(!state.readingLine.lowercased().contains(forbidden))
        }
    }

    @Test("a damaged saved readings file names the problem in plain words, never engine jargon, SQLite terms, or the exit status")
    func storeDamagedFailure() {
        let state = MenuDisplayState.make(credentialsConfigured: true, engineState: .failed(.storeDamaged), status: nil, now: Self.now)
        #expect(state.dot == .red)
        #expect(state.statusLine == "Saved readings can't be read")
        #expect(state.readingLine == "The file is damaged.")
        for forbidden in ["engine", "store", "sqlite", "corrupt", "exit status", "exit code"] {
            #expect(!state.statusLine.lowercased().contains(forbidden))
            #expect(!state.readingLine.lowercased().contains(forbidden))
        }
    }

    @Test("engine stopped with no status ever fetched still says no reading yet, never claiming one existed")
    func engineStoppedWithNoStatusEver() {
        let state = MenuDisplayState.make(credentialsConfigured: true, engineState: .stopped, status: nil, now: Self.now)
        #expect(state.dot == .red)
        #expect(state.statusLine == "Stopped")
        #expect(state.readingLine == "No reading yet")
    }

    @Test("running with no status yet shows amber connecting")
    func connecting() {
        let state = MenuDisplayState.make(credentialsConfigured: true, engineState: .running, status: nil, now: Self.now)
        #expect(state.dot == .amber)
        #expect(state.statusLine == "Connecting…")
        #expect(state.readingLine == "No reading yet")
    }

    @Test("sign-in failing shows red with a plain instruction, never the engine's own error text")
    func signInFailing() {
        let status = EngineStatus(running: true, signInFailing: true, lastError: "invalid credentials")
        let state = MenuDisplayState.make(credentialsConfigured: true, engineState: .running, status: status, now: Self.now)
        #expect(state.dot == .red)
        #expect(state.statusLine == "Sign-in failing. Check your LibreLinkUp email and password in Settings.")
    }

    @Test("no reading fetched yet, engine healthy, shows amber")
    func noReadingYet() {
        let status = EngineStatus(running: true)
        let state = MenuDisplayState.make(credentialsConfigured: true, engineState: .running, status: status, now: Self.now)
        #expect(state.dot == .amber)
        #expect(state.statusLine == "Waiting for a reading")
        #expect(state.readingLine == "No reading yet")
    }

    @Test("a reading inside the fresh window shows green")
    func freshReading() {
        let status = EngineStatus(running: true, lastReadingTime: Self.now.addingTimeInterval(-120), lastReadingMgDl: 142)
        let state = MenuDisplayState.make(credentialsConfigured: true, engineState: .running, status: status, now: Self.now)
        #expect(state.dot == .green)
        #expect(state.statusLine == "Reading is current")
        #expect(state.readingLine == "142 mg/dL (2 min ago)")
    }

    @Test("a reading exactly at the fresh window boundary is still green")
    func freshBoundary() {
        let status = EngineStatus(running: true, lastReadingTime: Self.now.addingTimeInterval(-MenuDisplayState.freshWindow), lastReadingMgDl: 100)
        let state = MenuDisplayState.make(credentialsConfigured: true, engineState: .running, status: status, now: Self.now)
        #expect(state.dot == .green)
    }

    @Test("a reading past the fresh window shows amber, stale")
    func staleReading() {
        let status = EngineStatus(running: true, lastReadingTime: Self.now.addingTimeInterval(-600), lastReadingMgDl: 95)
        let state = MenuDisplayState.make(credentialsConfigured: true, engineState: .running, status: status, now: Self.now)
        #expect(state.dot == .amber)
        #expect(state.statusLine == "Reading is stale")
        #expect(state.readingLine == "95 mg/dL (10 min ago)")
    }

    @Test("no follower app has ever polled")
    func noFollowerYet() {
        let status = EngineStatus(running: true, lastReadingTime: Self.now.addingTimeInterval(-60), lastReadingMgDl: 100, clients: [:])
        let state = MenuDisplayState.make(credentialsConfigured: true, engineState: .running, status: status, now: Self.now)
        #expect(state.lastPolledLine == "No follower app has polled yet")
    }

    @Test("the most recently polled follower's time is reported")
    func mostRecentFollower() {
        let status = EngineStatus(
            running: true,
            lastReadingTime: Self.now.addingTimeInterval(-60),
            lastReadingMgDl: 100,
            clients: [
                "xDrip4iOS": Self.now.addingTimeInterval(-90),
                "LoopFollow": Self.now.addingTimeInterval(-15),
            ]
        )
        let state = MenuDisplayState.make(credentialsConfigured: true, engineState: .running, status: status, now: Self.now)
        #expect(state.lastPolledLine == "Last polled just now")
    }

    @Test("a reading present without an mg/dL value reports as unavailable rather than a false zero")
    func missingMgDl() {
        let status = EngineStatus(running: true, lastReadingTime: Self.now.addingTimeInterval(-60), lastReadingMgDl: nil)
        let state = MenuDisplayState.make(credentialsConfigured: true, engineState: .running, status: status, now: Self.now)
        #expect(state.readingLine == "Reading unavailable")
    }
}
