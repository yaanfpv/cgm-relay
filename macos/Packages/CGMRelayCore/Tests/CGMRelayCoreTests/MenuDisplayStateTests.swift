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
        #expect(state.statusLine == "Couldn't start fresh")
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

    @Test("mg/dL is the default unit when none is given")
    func defaultsToMgDl() {
        let status = EngineStatus(running: true, lastReadingTime: Self.now.addingTimeInterval(-60), lastReadingMgDl: 142)
        let state = MenuDisplayState.make(credentialsConfigured: true, engineState: .running, status: status, now: Self.now)
        #expect(state.readingLine == "142 mg/dL (1 min ago)")
    }

    @Test("mmol/L renders the same reading converted, to one decimal place")
    func mmolLConvertsTheReading() {
        let status = EngineStatus(running: true, lastReadingTime: Self.now.addingTimeInterval(-60), lastReadingMgDl: 142)
        let state = MenuDisplayState.make(credentialsConfigured: true, engineState: .running, status: status, now: Self.now, units: .mmolL)
        #expect(state.readingLine == "7.9 mmol/L (1 min ago)")
    }

    /// readingValue, readingUnit and readingAge are built by the same
    /// mapping as readingLine, so this table repeats every distinct
    /// readingLine shape the standalone tests above already exercise and
    /// checks the split fields agree with it: populated together exactly
    /// when readingLine carries a reading, and nil together exactly when
    /// it falls back to a plain sentence.
    @Test("readingValue, readingUnit and readingAge match readingLine for every state readingLine covers")
    func readingFieldsMatchReadingLine() {
        struct Case {
            let name: String
            let engineState: EngineSupervisor.RunState
            let status: EngineStatus?
            let units: GlucoseUnit
            let expectedLine: String
            let expectedValue: String?
            let expectedUnit: String?
            let expectedAge: String?
        }

        let freshStatus = EngineStatus(running: true, lastReadingTime: Self.now.addingTimeInterval(-30), lastReadingMgDl: 110)
        let staleStatus = EngineStatus(running: true, lastReadingTime: Self.now.addingTimeInterval(-600), lastReadingMgDl: 95)
        let mmolStatus = EngineStatus(running: true, lastReadingTime: Self.now.addingTimeInterval(-60), lastReadingMgDl: 142)
        let missingMgDlStatus = EngineStatus(running: true, lastReadingTime: Self.now.addingTimeInterval(-60), lastReadingMgDl: nil)

        let cases: [Case] = [
            Case(name: "stopped with a reading on file", engineState: .stopped, status: freshStatus, units: .mgDl,
                 expectedLine: "110 mg/dL (just now)", expectedValue: "110", expectedUnit: "mg/dL", expectedAge: "just now"),
            Case(name: "starting with a reading on file", engineState: .starting, status: freshStatus, units: .mgDl,
                 expectedLine: "110 mg/dL (just now)", expectedValue: "110", expectedUnit: "mg/dL", expectedAge: "just now"),
            Case(name: "waiting to restart with a reading on file", engineState: .waitingToRestart(attempt: 1, delay: .seconds(2)), status: freshStatus, units: .mgDl,
                 expectedLine: "110 mg/dL (just now)", expectedValue: "110", expectedUnit: "mg/dL", expectedAge: "just now"),
            Case(name: "running, sign-in failing, with a reading on file", engineState: .running, status: EngineStatus(running: true, lastReadingTime: Self.now.addingTimeInterval(-30), lastReadingMgDl: 110, signInFailing: true), units: .mgDl,
                 expectedLine: "110 mg/dL (just now)", expectedValue: "110", expectedUnit: "mg/dL", expectedAge: "just now"),
            Case(name: "running, fresh", engineState: .running, status: freshStatus, units: .mgDl,
                 expectedLine: "110 mg/dL (just now)", expectedValue: "110", expectedUnit: "mg/dL", expectedAge: "just now"),
            Case(name: "running, stale", engineState: .running, status: staleStatus, units: .mgDl,
                 expectedLine: "95 mg/dL (10 min ago)", expectedValue: "95", expectedUnit: "mg/dL", expectedAge: "10 min ago"),
            Case(name: "running, mmol/L conversion", engineState: .running, status: mmolStatus, units: .mmolL,
                 expectedLine: "7.9 mmol/L (1 min ago)", expectedValue: "7.9", expectedUnit: "mmol/L", expectedAge: "1 min ago"),
            Case(name: "a reading present without an mg/dL value", engineState: .running, status: missingMgDlStatus, units: .mgDl,
                 expectedLine: "Reading unavailable", expectedValue: nil, expectedUnit: nil, expectedAge: nil),
            Case(name: "stopped with no status ever fetched", engineState: .stopped, status: nil, units: .mgDl,
                 expectedLine: "No reading yet", expectedValue: nil, expectedUnit: nil, expectedAge: nil),
            Case(name: "running, connecting, no status yet", engineState: .running, status: nil, units: .mgDl,
                 expectedLine: "No reading yet", expectedValue: nil, expectedUnit: nil, expectedAge: nil),
            Case(name: "running, waiting for a reading", engineState: .running, status: EngineStatus(running: true), units: .mgDl,
                 expectedLine: "No reading yet", expectedValue: nil, expectedUnit: nil, expectedAge: nil),
            Case(name: "a permanently failed store key mismatch", engineState: .failed(.storeKeyMismatch), status: nil, units: .mgDl,
                 expectedLine: "They were saved with a key this Mac no longer has.", expectedValue: nil, expectedUnit: nil, expectedAge: nil),
            Case(name: "a permanently failed recovery move", engineState: .failed(.recoveryMoveFailed), status: nil, units: .mgDl,
                 expectedLine: "Check that CGM Relay can write to its own folder, then try Start Fresh again.", expectedValue: nil, expectedUnit: nil, expectedAge: nil),
        ]

        for testCase in cases {
            let state = MenuDisplayState.make(credentialsConfigured: true, engineState: testCase.engineState, status: testCase.status, now: Self.now, units: testCase.units)
            #expect(state.readingLine == testCase.expectedLine, "\(testCase.name): readingLine")
            #expect(state.readingValue == testCase.expectedValue, "\(testCase.name): readingValue")
            #expect(state.readingUnit == testCase.expectedUnit, "\(testCase.name): readingUnit")
            #expect(state.readingAge == testCase.expectedAge, "\(testCase.name): readingAge")
        }
    }

    /// shortStatus, statusAge and statusDetail are the pieces
    /// MenuContentView's one secondary line renders with no string
    /// matching of its own: this table drives every distinct state the
    /// standalone tests above already cover and checks all three
    /// directly, plus the 30-character bar every shortStatus (and the
    /// permanent-failure statusLine headlines, which double as their own
    /// shortStatus) is held to.
    @Test("shortStatus, statusAge and statusDetail are correct and short for every state")
    func secondaryLineFieldsAreCorrectAndShort() {
        struct Case {
            let name: String
            let engineState: EngineSupervisor.RunState
            let status: EngineStatus?
            let expectedShortStatus: String
            let expectedStatusAge: String?
            let expectedStatusDetail: String?
        }

        let freshStatus = EngineStatus(running: true, lastReadingTime: Self.now.addingTimeInterval(-30), lastReadingMgDl: 110)
        let staleStatus = EngineStatus(running: true, lastReadingTime: Self.now.addingTimeInterval(-600), lastReadingMgDl: 95)
        let signInFailingWithReading = EngineStatus(running: true, lastReadingTime: Self.now.addingTimeInterval(-30), lastReadingMgDl: 110, signInFailing: true)
        let noReadingYet = EngineStatus(running: true)

        let cases: [Case] = [
            Case(name: "stopped, no reading ever fetched", engineState: .stopped, status: nil,
                 expectedShortStatus: "Stopped", expectedStatusAge: nil, expectedStatusDetail: nil),
            Case(name: "stopped, with a reading on file", engineState: .stopped, status: freshStatus,
                 expectedShortStatus: "Stopped", expectedStatusAge: "last reading just now", expectedStatusDetail: nil),
            Case(name: "starting, with a reading on file", engineState: .starting, status: freshStatus,
                 expectedShortStatus: "Starting…", expectedStatusAge: "last reading just now", expectedStatusDetail: nil),
            Case(name: "waiting to restart, with a reading on file", engineState: .waitingToRestart(attempt: 1, delay: .seconds(2)), status: freshStatus,
                 expectedShortStatus: "Restarting…", expectedStatusAge: "last reading just now", expectedStatusDetail: nil),
            Case(name: "running, connecting, no status yet", engineState: .running, status: nil,
                 expectedShortStatus: "Connecting…", expectedStatusAge: nil, expectedStatusDetail: nil),
            Case(name: "running, waiting for a reading", engineState: .running, status: noReadingYet,
                 expectedShortStatus: "Waiting for a reading", expectedStatusAge: nil, expectedStatusDetail: nil),
            Case(name: "running, sign-in failing, with a reading on file", engineState: .running, status: signInFailingWithReading,
                 expectedShortStatus: "Sign-in failing", expectedStatusAge: "last reading just now",
                 expectedStatusDetail: "Check your LibreLinkUp email and password in Settings."),
            Case(name: "running, fresh", engineState: .running, status: freshStatus,
                 expectedShortStatus: "Current", expectedStatusAge: "just now", expectedStatusDetail: nil),
            Case(name: "running, stale", engineState: .running, status: staleStatus,
                 expectedShortStatus: "Stale", expectedStatusAge: "10 min ago", expectedStatusDetail: nil),
            Case(name: "a permanently failed store key mismatch", engineState: .failed(.storeKeyMismatch), status: nil,
                 expectedShortStatus: "Saved readings can't be opened", expectedStatusAge: nil, expectedStatusDetail: nil),
            Case(name: "a permanently failed recovery move", engineState: .failed(.recoveryMoveFailed), status: nil,
                 expectedShortStatus: "Couldn't start fresh", expectedStatusAge: nil, expectedStatusDetail: nil),
        ]

        for testCase in cases {
            let state = MenuDisplayState.make(credentialsConfigured: true, engineState: testCase.engineState, status: testCase.status, now: Self.now)
            #expect(state.shortStatus == testCase.expectedShortStatus, "\(testCase.name): shortStatus")
            #expect(state.statusAge == testCase.expectedStatusAge, "\(testCase.name): statusAge")
            #expect(state.statusDetail == testCase.expectedStatusDetail, "\(testCase.name): statusDetail")
            #expect(state.shortStatus.count <= 30, "\(testCase.name): shortStatus is \(state.shortStatus.count) characters")
        }

        let setupNeededState = MenuDisplayState.make(credentialsConfigured: false, engineState: .running, status: nil, now: Self.now)
        #expect(setupNeededState.shortStatus == "Setup needed")
        #expect(setupNeededState.statusAge == nil)
    }
}
