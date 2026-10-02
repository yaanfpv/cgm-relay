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

    @Test("the menu bar mark is plain while current, coloured for what needs attention (grey only while setup is unfinished and nothing is wrong), and every state is said in words")
    func menuBarItemStates() {
        let fresh = EngineStatus(running: true, lastReadingTime: Self.now, lastReadingMgDl: 142, lastReadingTrend: "FortyFiveUp")
        let stale = EngineStatus(running: true, lastReadingTime: Self.now.addingTimeInterval(-600), lastReadingMgDl: 142, lastReadingTrend: "Flat")
        let failing = EngineStatus(running: true, lastReadingTime: Self.now, lastReadingMgDl: 142, lastReadingTrend: "Flat", signInFailing: true)

        struct Case {
            let name: String
            let credentialsConfigured: Bool
            let needsSetup: Bool
            let engineState: EngineSupervisor.RunState
            let status: EngineStatus?
            let tint: MenuBarItemState.Tint
            let label: String
        }
        let cases = [
            Case(name: "current", credentialsConfigured: true, needsSetup: false, engineState: .running, status: fresh, tint: .plain, label: "CGM Relay: Current"),
            Case(name: "stale", credentialsConfigured: true, needsSetup: false, engineState: .running, status: stale, tint: .amber, label: "CGM Relay: Stale"),
            Case(name: "sign-in failing", credentialsConfigured: true, needsSetup: false, engineState: .running, status: failing, tint: .red, label: "CGM Relay: Sign-in failing"),
            Case(name: "stopped", credentialsConfigured: true, needsSetup: false, engineState: .stopped, status: fresh, tint: .red, label: "CGM Relay: Stopped"),
            Case(name: "no account yet", credentialsConfigured: false, needsSetup: true, engineState: .stopped, status: nil, tint: .grey, label: "CGM Relay: Finish setup"),
            Case(name: "signed in, setup not finished, readings current", credentialsConfigured: true, needsSetup: true, engineState: .running, status: fresh, tint: .grey, label: "CGM Relay: Finish setup"),
            Case(name: "setup not finished, readings stale", credentialsConfigured: true, needsSetup: true, engineState: .running, status: stale, tint: .amber, label: "CGM Relay: Stale"),
            Case(name: "setup not finished, sign-in failing", credentialsConfigured: true, needsSetup: true, engineState: .running, status: failing, tint: .red, label: "CGM Relay: Sign-in failing"),
            Case(name: "setup not finished, stopped", credentialsConfigured: true, needsSetup: true, engineState: .stopped, status: fresh, tint: .red, label: "CGM Relay: Stopped"),
            Case(name: "setup not finished, engine failed", credentialsConfigured: true, needsSetup: true, engineState: .failed(.storeDamaged), status: nil, tint: .red, label: "CGM Relay: Saved readings can't be read"),
            Case(name: "setup not finished, no reading yet", credentialsConfigured: true, needsSetup: true, engineState: .running, status: EngineStatus(running: true), tint: .grey, label: "CGM Relay: Finish setup"),
        ]
        for testCase in cases {
            let menu = MenuDisplayState.make(
                credentialsConfigured: testCase.credentialsConfigured, engineState: testCase.engineState, status: testCase.status, now: Self.now
            )
            let item = MenuBarItemState.make(menu: menu, needsSetup: testCase.needsSetup, showReading: true)
            #expect(item.tint == testCase.tint, "\(testCase.name): tint")
            #expect(item.accessibilityLabel == testCase.label, "\(testCase.name): label")
        }
    }

    @Test("the reading beside the mark shows only when asked for and only while current, with the trend arrow the device reported")
    func menuBarItemReading() {
        func item(_ status: EngineStatus?, engineState: EngineSupervisor.RunState = .running, showReading: Bool, units: GlucoseUnit = .mgDl) -> MenuBarItemState {
            let menu = MenuDisplayState.make(credentialsConfigured: true, engineState: engineState, status: status, now: Self.now, units: units)
            return MenuBarItemState.make(menu: menu, needsSetup: false, showReading: showReading)
        }
        let fresh = EngineStatus(running: true, lastReadingTime: Self.now, lastReadingMgDl: 142, lastReadingTrend: "FortyFiveUp")
        let noTrend = EngineStatus(running: true, lastReadingTime: Self.now, lastReadingMgDl: 142)
        let stale = EngineStatus(running: true, lastReadingTime: Self.now.addingTimeInterval(-600), lastReadingMgDl: 142, lastReadingTrend: "Flat")
        let failing = EngineStatus(running: true, lastReadingTime: Self.now, lastReadingMgDl: 142, lastReadingTrend: "Flat", signInFailing: true)

        #expect(item(fresh, showReading: false).title == nil, "a value while the option is off")
        #expect(item(fresh, showReading: true).title == "142 ↗")
        #expect(item(fresh, showReading: true, units: .mmolL).title == "7.9 ↗")
        #expect(item(noTrend, showReading: true).title == "142", "no arrow for a trend the device did not report")
        #expect(item(stale, showReading: true).title == nil, "a stale value shown as current")
        #expect(item(failing, showReading: true).title == nil, "a value while sign-in is failing")
        #expect(item(fresh, engineState: .stopped, showReading: true).title == nil, "a value while stopped")
        #expect(item(nil, showReading: true).title == nil)
    }

    @Test("a waiting update adds the dot and a sentence to the spoken label, and never changes the tint or the reading")
    func menuBarItemUpdate() {
        let fresh = EngineStatus(running: true, lastReadingTime: Self.now, lastReadingMgDl: 142, lastReadingTrend: "Flat")
        let stale = EngineStatus(running: true, lastReadingTime: Self.now.addingTimeInterval(-600), lastReadingMgDl: 142, lastReadingTrend: "Flat")
        func item(_ status: EngineStatus, update: PendingUpdate) -> MenuBarItemState {
            let menu = MenuDisplayState.make(credentialsConfigured: true, engineState: .running, status: status, now: Self.now)
            return MenuBarItemState.make(menu: menu, needsSetup: false, showReading: true, update: update)
        }
        let none = item(fresh, update: .none)
        #expect(!none.showsUpdateMark)
        #expect(none.accessibilityLabel == "CGM Relay: Current")

        let available = item(fresh, update: .available(version: "0.2.0"))
        #expect(available.showsUpdateMark)
        #expect(available.tint == none.tint && available.title == none.title)
        #expect(available.accessibilityLabel == "CGM Relay: Current. Update 0.2.0 available")

        let ready = item(stale, update: .readyToRestart(version: "0.2.0"))
        #expect(ready.showsUpdateMark)
        #expect(ready.tint == .amber, "the tint still says the readings are late")
        #expect(ready.accessibilityLabel == "CGM Relay: Stale. Update 0.2.0 ready, restart to install")
    }

    @Test("every direction the engine reports has its arrow, and anything else has none")
    func trendArrows() {
        let expected = [
            "DoubleUp": "⇈", "SingleUp": "↑", "FortyFiveUp": "↗", "Flat": "→",
            "FortyFiveDown": "↘", "SingleDown": "↓", "DoubleDown": "⇊",
        ]
        for (direction, arrow) in expected {
            #expect(TrendArrow.symbol(forDirection: direction) == arrow, Comment(rawValue: direction))
        }
        #expect(TrendArrow.symbol(forDirection: "NotComputable") == nil)
        #expect(TrendArrow.symbol(forDirection: nil) == nil)
        #expect(TrendArrow.symbol(forDirection: "") == nil)
    }
}

@Suite("QuitPolicy")
struct QuitPolicyTests {
    private static func code(_ text: String) -> UInt32 {
        text.utf8.reduce(0) { ($0 << 8) | UInt32($1) }
    }

    static let cases: [(name: String, event: Bool, reason: UInt32?, ending: Bool, terminates: Bool)] = [
        ("a quit from inside the app (app menu, Command-Q, panel, right-click menu) has no Apple event and quits", false, nil, false, true),
        ("the Dock's or another app's quit event, with no reason, keeps the relay running", true, nil, false, false),
        ("a quit event carrying an unrelated reason keeps the relay running", true, code("abcd"), false, false),
        ("log out quits", true, code("logo"), false, true),
        ("log out after its dialog quits", true, code("rlgo"), false, true),
        ("restart quits", true, code("rest"), false, true),
        ("restart after its dialog quits", true, code("rrst"), false, true),
        ("shut down quits", true, code("shut"), false, true),
        ("shut down after its dialog quits", true, code("rsdn"), false, true),
        ("a quit event during the system's power-off notice quits", true, nil, true, true),
    ]

    @Test("only a quit event from outside the app, without a session-ending reason, is kept from quitting", arguments: cases)
    func decides(_ testCase: (name: String, event: Bool, reason: UInt32?, ending: Bool, terminates: Bool)) {
        #expect(QuitPolicy.shouldTerminate(quitEventPresent: testCase.event, eventReason: testCase.reason, sessionEnding: testCase.ending) == testCase.terminates)
    }

    @Test("the updater's quit event, which carries no reason, quits so the app can be replaced")
    func updaterQuits() {
        #expect(QuitPolicy.shouldTerminate(quitEventPresent: true, eventReason: nil, sessionEnding: false, fromUpdater: true))
        #expect(!QuitPolicy.shouldTerminate(quitEventPresent: true, eventReason: nil, sessionEnding: false, fromUpdater: false))
    }
}

@Suite("PendingUpdate")
struct PendingUpdateTests {
    @Test("each state words its entry and its sentence, and nothing waiting says nothing")
    func wording() {
        let cases: [(update: PendingUpdate, title: String, line: String?)] = [
            (.none, "Check for Updates…", nil),
            (.available(version: "0.2.0"), "Update Available (0.2.0)…", "Version 0.2.0 is available."),
            (.readyToRestart(version: "0.2.0"), "Restart to Update", "Version 0.2.0 is ready. It installs when CGM Relay next quits."),
        ]
        for testCase in cases {
            #expect(testCase.update.menuTitle == testCase.title)
            #expect(testCase.update.statusLine == testCase.line)
        }
    }
}
