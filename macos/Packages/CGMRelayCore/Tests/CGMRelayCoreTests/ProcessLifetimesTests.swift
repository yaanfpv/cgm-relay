import Testing
import Foundation
@testable import CGMRelayCore

// ProcessLifetimes is the one owner of when the engine and the logout child
// count as running. An end that is not confirmed counts as running until the
// app quits: nothing here, and nothing a caller does, releases it. An end
// still being waited for (a confirmation in flight) counts as one not yet
// confirmed: every answer that lets something go is false until it is.

/// What each lifetime has been driven to. The helpers below drive a real
/// ProcessLifetimes to one of these through its own transitions.
enum EngineLife: CaseIterable, CustomTestStringConvertible, Sendable {
    case none, running, confirming, ended, notConfirmed
    var testDescription: String { "engine \(self)" }
}

enum LeaveLife: CaseIterable, CustomTestStringConvertible, Sendable {
    case none, running, ended, notConfirmed
    var testDescription: String { "leave child \(self)" }
}

/// Answers is the owner's read-only view of the folder, built-in choice and
/// leave child, as it stood before the release answers were split by kind.
struct Answers: Equatable {
    var holdsTailscaleFolder: Bool
    var builtInChoiceBlocked: Bool
    var mayStartLeaveChild: Bool
    var keepAwakeMayBeReleased: Bool
}

@MainActor
private func answers(_ lifetimes: ProcessLifetimes) -> Answers {
    Answers(
        holdsTailscaleFolder: lifetimes.holdsTailscaleFolder,
        builtInChoiceBlocked: lifetimes.builtInChoiceBlocked,
        mayStartLeaveChild: lifetimes.mayStartLeaveChild,
        keepAwakeMayBeReleased: lifetimes.keepAwakeMayBeReleased
    )
}

@MainActor
private func drive(_ lifetimes: ProcessLifetimes, engine: EngineLife, leave: LeaveLife, usingKeptFolder: Bool = true) {
    switch engine {
    case .none: break
    case .running: lifetimes.engineStarted(usingKeptFolder: usingKeptFolder)
    case .confirming:
        lifetimes.engineStarted(usingKeptFolder: usingKeptFolder)
        lifetimes.engineStopRequested()
    case .ended:
        lifetimes.engineStarted(usingKeptFolder: usingKeptFolder)
        lifetimes.engineStopRequested()
        lifetimes.engineEnded(confirmed: true)
    case .notConfirmed:
        lifetimes.engineStarted(usingKeptFolder: usingKeptFolder)
        lifetimes.engineStopRequested()
        lifetimes.engineEnded(confirmed: false)
    }
    switch leave {
    case .none: break
    case .running: lifetimes.leaveChildStarted()
    case .ended:
        lifetimes.leaveChildStarted()
        lifetimes.leaveChildEnded(confirmed: true)
    case .notConfirmed:
        lifetimes.leaveChildStarted()
        lifetimes.leaveChildEnded(confirmed: false)
    }
}

/// expected is what the story's rule gives for a pair of lifetimes: a process
/// whose end is not confirmed is a process still running, and an end still
/// being waited for is an end not yet confirmed, so nothing is released while
/// it is, whichever folder the engine was configured to use.
private func expected(engine: EngineLife, leave: LeaveLife, usingKeptFolder: Bool = true) -> Answers {
    let engineHolds = engine == .notConfirmed || ((engine == .running || engine == .confirming) && usingKeptFolder)
    let leaveHolds = leave == .running || leave == .notConfirmed
    let engineUnsettled = engine == .notConfirmed || engine == .confirming
    return Answers(
        holdsTailscaleFolder: engineHolds || leaveHolds,
        builtInChoiceBlocked: leaveHolds || engineUnsettled,
        mayStartLeaveChild: !(engineHolds || leaveHolds || engineUnsettled),
        keepAwakeMayBeReleased: !engineUnsettled
    )
}

@MainActor
@Suite("ProcessLifetimes")
struct ProcessLifetimesTests {
    static let engineURL = URL(fileURLWithPath: "/usr/bin/true")

    @Test("with nothing started nothing is held and everything may proceed")
    func freshHoldsNothing() {
        #expect(answers(ProcessLifetimes()) == Answers(
            holdsTailscaleFolder: false,
            builtInChoiceBlocked: false,
            mayStartLeaveChild: true,
            keepAwakeMayBeReleased: true
        ))
    }

    @Test("every pair of engine and leave child states answers by the rule that an unconfirmed end, or one still being waited for, is a process still running", arguments: EngineLife.allCases, LeaveLife.allCases)
    func everyPairOfStates(engine: EngineLife, leave: LeaveLife) {
        let lifetimes = ProcessLifetimes()
        drive(lifetimes, engine: engine, leave: leave)
        #expect(answers(lifetimes) == expected(engine: engine, leave: leave))
    }

    @Test("an engine configured off the kept folder answers by the same rule: only the folder it holds changes", arguments: EngineLife.allCases, LeaveLife.allCases)
    func everyPairOfStatesOffTheKeptFolder(engine: EngineLife, leave: LeaveLife) {
        let lifetimes = ProcessLifetimes()
        drive(lifetimes, engine: engine, leave: leave, usingKeptFolder: false)
        #expect(answers(lifetimes) == expected(engine: engine, leave: leave, usingKeptFolder: false))
    }

    @Test("a confirmed end releases what it held, and a stopped engine can be started again")
    func confirmedEndReleases() {
        let lifetimes = ProcessLifetimes()
        lifetimes.engineStarted()
        lifetimes.engineStopRequested()
        #expect(lifetimes.holdsTailscaleFolder, "an engine being stopped still holds the folder")
        #expect(!lifetimes.mayStartLeaveChild)
        #expect(!lifetimes.keepAwakeMayBeReleased, "keep-awake was released while the engine's end was still being waited for")
        lifetimes.engineEnded(confirmed: true)
        #expect(!lifetimes.holdsTailscaleFolder)
        #expect(lifetimes.mayStartLeaveChild)
        #expect(lifetimes.keepAwakeMayBeReleased)
        lifetimes.engineStarted()
        #expect(lifetimes.holdsTailscaleFolder)
    }

    @Test("an end that was not confirmed never moves again, whatever is reported after it", arguments: ["engine", "leave child"])
    func notConfirmedNeverMoves(which: String) {
        let lifetimes = ProcessLifetimes()
        if which == "engine" {
            drive(lifetimes, engine: .notConfirmed, leave: .none)
        } else {
            drive(lifetimes, engine: .none, leave: .notConfirmed)
        }
        let held = answers(lifetimes)
        #expect(held.holdsTailscaleFolder)
        #expect(!held.mayStartLeaveChild)

        if which == "engine" {
            lifetimes.engineStopRequested()
            #expect(answers(lifetimes) == held)
            lifetimes.engineEnded(confirmed: true)
            #expect(answers(lifetimes) == held, "a later confirmed end released an engine that was never confirmed")
            lifetimes.engineStarted()
            lifetimes.engineEnded(confirmed: true)
            #expect(answers(lifetimes) == held, "a later start and end released an engine that was never confirmed")
        } else {
            lifetimes.leaveChildEnded(confirmed: true)
            #expect(answers(lifetimes) == held, "a later confirmed end released a leave child that was never confirmed")
            lifetimes.leaveChildStarted()
            lifetimes.leaveChildEnded(confirmed: true)
            #expect(answers(lifetimes) == held, "a second leave child run released a leave child that was never confirmed")
        }
    }

    @Test("a confirmed end of one process never releases the other's unconfirmed end")
    func theTwoLifetimesAreIndependent() {
        let engineHeld = ProcessLifetimes()
        drive(engineHeld, engine: .notConfirmed, leave: .none)
        engineHeld.leaveChildStarted()
        engineHeld.leaveChildEnded(confirmed: true)
        #expect(engineHeld.holdsTailscaleFolder)
        #expect(!engineHeld.mayStartLeaveChild)
        #expect(!engineHeld.keepAwakeMayBeReleased)

        let leaveHeld = ProcessLifetimes()
        drive(leaveHeld, engine: .none, leave: .notConfirmed)
        leaveHeld.engineStarted()
        leaveHeld.engineStopRequested()
        leaveHeld.engineEnded(confirmed: true)
        #expect(leaveHeld.holdsTailscaleFolder)
        #expect(leaveHeld.builtInChoiceBlocked)
        #expect(!leaveHeld.mayStartLeaveChild)
        #expect(leaveHeld.keepAwakeMayBeReleased, "only an engine that may still run keeps the Mac awake")
    }

    @Test("a leave child that ended unconfirmed keeps the built-in choice blocked and starts no second leave child")
    func unconfirmedLeaveChildBlocksTheChoiceAndASecondRun() {
        let lifetimes = ProcessLifetimes()
        #expect(lifetimes.mayStartLeaveChild)
        lifetimes.leaveChildStarted()
        #expect(lifetimes.builtInChoiceBlocked, "the choice must wait while the leave child runs")
        lifetimes.leaveChildEnded(confirmed: false)
        #expect(lifetimes.builtInChoiceBlocked, "the choice was allowed after a leave child whose end was not confirmed")
        #expect(!lifetimes.mayStartLeaveChild, "a second leave child could start on a folder the first may still use")
        // A confirmed run, by contrast, frees both.
        let clean = ProcessLifetimes()
        clean.leaveChildStarted()
        clean.leaveChildEnded(confirmed: true)
        #expect(!clean.builtInChoiceBlocked)
        #expect(clean.mayStartLeaveChild)
    }
}

// MARK: - K31-NAMED-BEGIN
let k31FailureReasons: [EngineSupervisor.FailureReason] = [
    .storeKeyMismatch, .storeInUse, .storeDamaged, .configurationUnreadable,
    .recoveryMoveFailed, .portInUse, .httpsOnStatusPort, .engineStatusUnknown,
]

// Everything between these markers names a member the owner does not have yet:
// the answers that split by kind of release, and the one mapping from the
// supervisor's reported states. The names are PROPOSED here (the story leaves
// them to the builder); `NamedAnswer.released` and the `engineStateReported`
// calls below are the only places the real members are spelled, and
// `AppModelSource.answerNames` carries the same names as text for the source
// check. A builder who names them otherwise edits that table and those calls,
// and a test below fails if the two tables drift apart.

/// NamedAnswer is one release the app makes after an end, with the owner's one
/// answer for it. released is true when that release may be made.
enum NamedAnswer: CaseIterable, CustomTestStringConvertible, Sendable {
    case boundAddress, keepAwake, builtInChoice, leaveChildStart, engineStart

    var testDescription: String { "\(self)" }

    /// sourceName is the answer's member name as AppModel's source spells it.
    var sourceName: String {
        switch self {
        case .boundAddress: AppModelSource.boundAddress
        case .keepAwake: AppModelSource.keepAwake
        case .builtInChoice: AppModelSource.builtInChoice
        case .leaveChildStart: AppModelSource.leaveChildStart
        case .engineStart: AppModelSource.engineStart
        }
    }

    /// released is the one place each real member is spelled.
    @MainActor
    func released(_ lifetimes: ProcessLifetimes, startOnKeptFolder: Bool) -> Bool {
        switch self {
        case .boundAddress: lifetimes.mayReleaseBoundAddress
        case .keepAwake: lifetimes.keepAwakeMayBeReleased
        case .builtInChoice: !lifetimes.builtInChoiceBlocked
        case .leaveChildStart: lifetimes.mayStartLeaveChild
        case .engineStart: lifetimes.mayStartEngine(onKeptFolder: startOnKeptFolder)
        }
    }
}

/// Situation is one state the owner is driven to through its own transitions.
enum Situation: Sendable, CustomTestStringConvertible {
    case engine(EngineLife, keptFolder: Bool)
    case leave(LeaveLife)
    var testDescription: String {
        switch self {
        case .engine(let life, let kept): "\(life), \(kept ? "on the kept folder" : "off the kept folder")"
        case .leave(let life): "\(life)"
        }
    }
    @MainActor
    func apply(to lifetimes: ProcessLifetimes) {
        switch self {
        case .engine(let life, let kept): drive(lifetimes, engine: life, leave: .none, usingKeptFolder: kept)
        case .leave(let life): drive(lifetimes, engine: .none, leave: life)
        }
    }
}

/// TermCase is one assertion about one answer: in this situation, with the
/// start (for the engine start answer) on or off the kept folder, the release
/// is made or is not. An unmet case names the one term that is unmet in it;
/// every other term of that answer is met.
struct TermCase: Sendable, CustomTestStringConvertible {
    let answer: NamedAnswer
    let term: String
    let situation: Situation?
    let startOnKeptFolder: Bool
    let released: Bool
    var testDescription: String {
        "\(answer): \(released ? "met" : "unmet") \(term)\(situation.map { " (\($0.testDescription))" } ?? "")"
    }

    static func unmet(_ answer: NamedAnswer, _ term: String, _ situation: Situation, startOnKeptFolder: Bool = true) -> TermCase {
        TermCase(answer: answer, term: term, situation: situation, startOnKeptFolder: startOnKeptFolder, released: false)
    }

    static func met(_ answer: NamedAnswer, _ term: String, _ situation: Situation?, startOnKeptFolder: Bool = true) -> TermCase {
        TermCase(answer: answer, term: term, situation: situation, startOnKeptFolder: startOnKeptFolder, released: true)
    }

    /// all is the table. Every answer's terms are listed with the situation
    /// that leaves only that term unmet, once on the kept folder and once off
    /// it where the term does not depend on the folder; the met rows are what
    /// an over-blocking answer would get wrong.
    static let all: [TermCase] = {
        var rows: [TermCase] = []
        let engineEnded: [Situation] = [true, false].map { .engine(.ended, keptFolder: $0) }

        // The bound address and keep-awake: no engine may still run, and none is being waited for.
        for answer in [NamedAnswer.boundAddress, .keepAwake] {
            for kept in [true, false] {
                rows.append(unmet(answer, "engine end unconfirmed", .engine(.notConfirmed, keptFolder: kept)))
                rows.append(unmet(answer, "engine end being confirmed", .engine(.confirming, keptFolder: kept)))
                rows.append(met(answer, "engine running", .engine(.running, keptFolder: kept)))
            }
            rows.append(met(answer, "nothing started", nil))
            for ended in engineEnded { rows.append(met(answer, "engine end confirmed", ended)) }
            rows.append(met(answer, "leave child running is no term of it", .leave(.running)))
            rows.append(met(answer, "leave child unconfirmed is no term of it", .leave(.notConfirmed)))
        }

        // The built-in choice: no engine unsettled, no leave child that may run.
        let choice = NamedAnswer.builtInChoice
        for kept in [true, false] {
            rows.append(unmet(choice, "engine end unconfirmed", .engine(.notConfirmed, keptFolder: kept)))
            rows.append(unmet(choice, "engine end being confirmed", .engine(.confirming, keptFolder: kept)))
            rows.append(met(choice, "engine running", .engine(.running, keptFolder: kept)))
        }
        rows.append(unmet(choice, "leave child running", .leave(.running)))
        rows.append(unmet(choice, "leave child unconfirmed", .leave(.notConfirmed)))
        rows.append(met(choice, "nothing started", nil))
        rows.append(met(choice, "leave child end confirmed", .leave(.ended)))
        for ended in engineEnded { rows.append(met(choice, "engine end confirmed", ended)) }

        // A leave child's start: the kept folder is free and no engine is unsettled.
        let leave = NamedAnswer.leaveChildStart
        rows.append(unmet(leave, "engine running on the kept folder", .engine(.running, keptFolder: true)))
        rows.append(unmet(leave, "engine end being confirmed (off the kept folder)", .engine(.confirming, keptFolder: false)))
        rows.append(unmet(leave, "engine end unconfirmed (on the kept folder)", .engine(.notConfirmed, keptFolder: true)))
        rows.append(unmet(leave, "engine end unconfirmed (off the kept folder)", .engine(.notConfirmed, keptFolder: false)))
        rows.append(unmet(leave, "leave child running", .leave(.running)))
        rows.append(unmet(leave, "leave child unconfirmed", .leave(.notConfirmed)))
        rows.append(met(leave, "nothing started", nil))
        rows.append(met(leave, "engine running off the kept folder", .engine(.running, keptFolder: false)))
        rows.append(met(leave, "leave child end confirmed", .leave(.ended)))
        for ended in engineEnded { rows.append(met(leave, "engine end confirmed", ended)) }

        // An engine start: no engine unsettled, and on the kept folder no leave child that may run.
        let start = NamedAnswer.engineStart
        for kept in [true, false] {
            rows.append(unmet(start, "engine end unconfirmed", .engine(.notConfirmed, keptFolder: kept)))
            rows.append(unmet(start, "engine end being confirmed", .engine(.confirming, keptFolder: kept)))
            rows.append(met(start, "engine still counted running (it stopped by itself)", .engine(.running, keptFolder: kept)))
        }
        rows.append(unmet(start, "leave child running, start on the kept folder", .leave(.running), startOnKeptFolder: true))
        rows.append(unmet(start, "leave child unconfirmed, start on the kept folder", .leave(.notConfirmed), startOnKeptFolder: true))
        rows.append(met(start, "leave child running, start off the kept folder", .leave(.running), startOnKeptFolder: false))
        rows.append(met(start, "leave child unconfirmed, start off the kept folder", .leave(.notConfirmed), startOnKeptFolder: false))
        rows.append(met(start, "nothing started, on the kept folder", nil, startOnKeptFolder: true))
        rows.append(met(start, "nothing started, off the kept folder", nil, startOnKeptFolder: false))
        rows.append(met(start, "leave child end confirmed, start on the kept folder", .leave(.ended), startOnKeptFolder: true))
        for ended in engineEnded { rows.append(met(start, "engine end confirmed", ended)) }
        return rows
    }()
}

extension ProcessLifetimesTests {
    @Test("each answer is false when only one of its terms is unmet, and true when all are met", arguments: TermCase.all)
    func eachTermAlone(_ row: TermCase) {
        let lifetimes = ProcessLifetimes()
        row.situation?.apply(to: lifetimes)
        let released = row.answer.released(lifetimes, startOnKeptFolder: row.startOnKeptFolder)
        #expect(released == row.released, "\(row.testDescription): the answer was \(released)")
    }

    @Test("the table of answers names exactly the members AppModel's source check looks for")
    func answerTablesAgree() {
        #expect(NamedAnswer.allCases.map(\.sourceName) == AppModelSource.answerNames)
        #expect(Set(TermCase.all.map(\.answer)).count == NamedAnswer.allCases.count, "an answer has no term rows")
    }

    // MARK: Driven by the owner's own mapping of the supervisor's states

    /// SupervisorFeed carries the real EngineSupervisor's state changes to a
    /// ProcessLifetimes through the owner's own mapping, the one AppModel runs.
    /// The caller's own stop request and a confirmed stop are recorded by the
    /// test, as they are by the caller that asked.
    @MainActor
    final class SupervisorFeed {
        let lifetimes = ProcessLifetimes()
        private let states = ObservedUpdates<EngineSupervisor.RunState>()
        private var applied = 0

        nonisolated var onStateChange: @Sendable (EngineSupervisor.RunState) -> Void {
            { [states] state in states.append(state) }
        }

        func applyReportedStates() {
            let all = states.values
            for state in all[applied...] {
                lifetimes.engineStateReported(state, usingKeptFolder: true)
            }
            applied = all.count
        }
    }

    @Test("a reported start records a running engine on the folder it was configured for", arguments: [true, false])
    func reportedStartRecordsTheEngine(kept: Bool) {
        let lifetimes = ProcessLifetimes()
        lifetimes.engineStateReported(.starting, usingKeptFolder: kept)
        #expect(lifetimes.engine == .running)
        #expect(lifetimes.holdsTailscaleFolder == kept)
        #expect(lifetimes.mayStartLeaveChild == !kept)
    }

    @Test("a reported failure confirms the engine's end for every reason but the one that says the end is unknown", arguments: k31FailureReasons, [true, false])
    func reportedFailureConfirmsByReason(reason: EngineSupervisor.FailureReason, kept: Bool) {
        let lifetimes = ProcessLifetimes()
        lifetimes.engineStateReported(.starting, usingKeptFolder: kept)
        lifetimes.engineStateReported(.failed(reason), usingKeptFolder: kept)
        let unknown = reason == .engineStatusUnknown
        #expect(lifetimes.engine == (unknown ? .notConfirmed : .ended), "\(reason)")
        #expect(lifetimes.keepAwakeMayBeReleased == !unknown, "\(reason)")
        #expect(lifetimes.holdsTailscaleFolder == unknown, "\(reason)")
    }

    @Test("a reported failure whose end is unknown holds for good: a later report of a start or another failure releases nothing")
    func reportedUnknownEndIsFinal() {
        let lifetimes = ProcessLifetimes()
        lifetimes.engineStateReported(.starting, usingKeptFolder: true)
        lifetimes.engineStateReported(.failed(.engineStatusUnknown), usingKeptFolder: true)
        for state in [EngineSupervisor.RunState.starting, .running, .stopped, .failed(.portInUse)] {
            lifetimes.engineStateReported(state, usingKeptFolder: false)
            #expect(lifetimes.engine == .notConfirmed, "\(state) released an engine that was never confirmed")
            #expect(lifetimes.holdsTailscaleFolder)
            #expect(!lifetimes.keepAwakeMayBeReleased)
        }
    }

    @Test("the states that are not a start or a failure change nothing the owner answers", arguments: [
        EngineSupervisor.RunState.stopped, .running, .waitingToRestart(attempt: 1, delay: .seconds(1)),
    ])
    func otherReportedStatesChangeNothing(state: EngineSupervisor.RunState) {
        for engine in [EngineLife.none, .running, .confirming, .ended] {
            let lifetimes = ProcessLifetimes()
            drive(lifetimes, engine: engine, leave: .running)
            let before = answers(lifetimes)
            let lifeBefore = lifetimes.engine
            lifetimes.engineStateReported(state, usingKeptFolder: true)
            #expect(answers(lifetimes) == before, "\(state) after \(engine)")
            #expect(lifetimes.engine == lifeBefore, "\(state) after \(engine)")
        }
    }

    @Test("a stopped report while the engine's end is being waited for releases neither the address nor keep-awake")
    func stoppedReportDuringConfirmationReleasesNothing() {
        let lifetimes = ProcessLifetimes()
        lifetimes.engineStateReported(.starting, usingKeptFolder: true)
        lifetimes.engineStopRequested()
        lifetimes.engineStateReported(.stopped, usingKeptFolder: true)
        #expect(!lifetimes.mayReleaseBoundAddress, "the address was released before the end was confirmed")
        #expect(!lifetimes.keepAwakeMayBeReleased)
        lifetimes.engineEnded(confirmed: true)
        #expect(lifetimes.mayReleaseBoundAddress)
        #expect(lifetimes.keepAwakeMayBeReleased)
    }

    @Test("an engine whose exit is reported as not confirmed, even after a plain stop, holds the folder with the route on or off")
    func statusUnknownExitHoldsTheFolder() async throws {
        for plainStopFirst in [false, true] {
            let launcher = FakeProcessLauncher()
            let feed = SupervisorFeed()
            let supervisor = EngineSupervisor(
                engineURL: Self.engineURL, launcher: launcher, clock: FakeVirtualClock(), onStateChange: feed.onStateChange
            )
            await supervisor.start(configuration: .fixture())
            feed.applyReportedStates()
            #expect(feed.lifetimes.holdsTailscaleFolder)
            if plainStopFirst { await supervisor.stop() }

            launcher.finishLaunch(at: 0, exitCode: ProcessExitCode.statusUnknown)
            #expect(await waitUntil { await supervisor.state == .failed(.engineStatusUnknown) }, "plain stop first: \(plainStopFirst)")
            feed.applyReportedStates()

            // No setting is an input: the answer is the same whether the
            // built-in route is on or off.
            #expect(feed.lifetimes.holdsTailscaleFolder, "plain stop first: \(plainStopFirst)")
            #expect(!feed.lifetimes.mayStartLeaveChild, "a leave child could launch on the kept folder, plain stop first: \(plainStopFirst)")
            #expect(feed.lifetimes.builtInChoiceBlocked)
            #expect(!feed.lifetimes.keepAwakeMayBeReleased)
            #expect(!feed.lifetimes.mayReleaseBoundAddress)
            #expect(!feed.lifetimes.mayStartEngine(onKeptFolder: true))
        }
    }

    @Test("an engine being stopped holds the folder until its end is confirmed, then releases it")
    func confirmingEngineHoldsUntilTheReap() async throws {
        let launcher = FakeProcessLauncher()
        let gate = ExitGate()
        launcher.exitGate = gate
        let feed = SupervisorFeed()
        let supervisor = EngineSupervisor(
            engineURL: Self.engineURL, launcher: launcher, clock: FakeVirtualClock(), onStateChange: feed.onStateChange
        )
        await supervisor.start(configuration: .fixture())
        feed.applyReportedStates()

        feed.lifetimes.engineStopRequested()
        let stopping = Task { await supervisor.stopAndWait(timeout: .seconds(3)) }
        await gate.awaitWaits(1)
        feed.applyReportedStates()
        #expect(feed.lifetimes.holdsTailscaleFolder)
        #expect(!feed.lifetimes.mayStartLeaveChild, "a leave child could start while the engine was being waited for")
        #expect(!feed.lifetimes.mayReleaseBoundAddress, "the address was released while the engine's end was being waited for, after the supervisor reported stopped")
        #expect(!feed.lifetimes.keepAwakeMayBeReleased)
        #expect(!feed.lifetimes.mayStartEngine(onKeptFolder: true))

        launcher.finishLaunch(at: 0, exitCode: -SIGTERM)
        gate.release()
        let confirmed = await StoppedChildSupport.withinAsync { await stopping.value }
        try #require(confirmed != nil, "stopAndWait never returned")
        #expect(confirmed == true)
        feed.lifetimes.engineEnded(confirmed: confirmed == true)
        feed.applyReportedStates()
        #expect(!feed.lifetimes.holdsTailscaleFolder)
        #expect(feed.lifetimes.mayStartLeaveChild)
        #expect(feed.lifetimes.keepAwakeMayBeReleased)
        #expect(feed.lifetimes.mayReleaseBoundAddress)
        #expect(feed.lifetimes.mayStartEngine(onKeptFolder: true))
    }

    @Test("an engine whose stop could not be confirmed holds the folder and keeps the Mac awake for the life of the process")
    func unconfirmedStopHoldsEverything() async throws {
        let launcher = FakeProcessLauncher()
        let gate = ExitGate()
        launcher.exitGate = gate
        let feed = SupervisorFeed()
        let supervisor = EngineSupervisor(
            engineURL: Self.engineURL, launcher: launcher, clock: FakeVirtualClock(), onStateChange: feed.onStateChange
        )
        await supervisor.start(configuration: .fixture())
        feed.applyReportedStates()

        feed.lifetimes.engineStopRequested()
        let stopping = Task { await supervisor.stopAndWait(timeout: .seconds(3)) }
        await gate.awaitWaits(1)
        gate.expirePending()
        await gate.awaitWaits(2)
        gate.expirePending()
        let confirmed = await StoppedChildSupport.withinAsync { await stopping.value }
        try #require(confirmed != nil, "stopAndWait never returned")
        #expect(confirmed == false)
        feed.applyReportedStates()

        #expect(feed.lifetimes.holdsTailscaleFolder)
        #expect(!feed.lifetimes.mayStartLeaveChild)
        #expect(feed.lifetimes.builtInChoiceBlocked)
        #expect(!feed.lifetimes.keepAwakeMayBeReleased)
        #expect(!feed.lifetimes.mayReleaseBoundAddress)
        #expect(!feed.lifetimes.mayStartEngine(onKeptFolder: false))

        // Neither a later start nor a clear of the failure lets go of it.
        await supervisor.clearFailure()
        await supervisor.start(configuration: .fixture())
        feed.applyReportedStates()
        #expect(launcher.launchCount == 1)
        #expect(!feed.lifetimes.mayStartLeaveChild)
        #expect(!feed.lifetimes.mayStartEngine(onKeptFolder: true))
    }
}
// MARK: - K31-NAMED-END

// MARK: - The app's releases each ask their own answer

/// AppModelSource reads AppModel.swift as text, comments and string contents
/// removed, because the app has no test target and its launcher is not
/// injectable. It is a narrow architecture guard over the whole file, not a
/// stand-in for the behaviour, which the owner's own checks above prove.
///
/// A release is a statement that lets something go after an end (the bound
/// address, the keep-awake hold, the built-in choice, a leave child's start,
/// an engine start). The table of rows below is the inventory: every
/// occurrence of a release token anywhere in the file belongs to a row (the
/// function it sits in, the token, how many there are), and a row says what may
/// guard it. An answer row needs its own owner answer among the conditions
/// that govern the release (an enclosing `if`, an earlier `guard` or `if` that
/// leaves, or a ternary), no other owner answer, and no other term unless the
/// row declares it by name. A reset row is a release before any engine runs; a
/// declared row is not made after an end and says why. A row whose token is not
/// found, or a token no row names, is red. Polarity stays the stated limit:
/// the check sees which answer guards, not whether the guard is inverted.
enum AppModelSource {
    enum Kind: Sendable {
        /// answer: the release is guarded by this owner answer, and by nothing
        /// else except the extras, named by the text they contain.
        case answer(String, extras: [String])
        /// reset: dropped before any engine runs, so nothing is released after an end.
        case reset(reason: String)
        /// declared: not made after an end; the reason is the ruling it follows.
        case declared(reason: String)
    }

    struct Row: Sendable {
        let function: String
        let release: String
        let count: Int
        let kind: Kind
    }

    // The names of the answers, as AppModel's source spells them. PROPOSED:
    // the story leaves them to the builder, who edits this table and
    // NamedAnswer.released together.
    static let boundAddress = "mayReleaseBoundAddress"
    static let keepAwake = "keepAwakeMayBeReleased"
    static let builtInChoice = "builtInChoiceBlocked"
    static let leaveChildStart = "mayStartLeaveChild"
    static let engineStart = "mayStartEngine"
    static let answerNames = [boundAddress, keepAwake, builtInChoice, leaveChildStart, engineStart]
    /// mappingName is the owner's one mapping from a supervisor state to its lifetimes.
    static let mappingName = "engineStateReported"

    /// releases are the tokens whose every occurrence must belong to a row.
    static let releases: [(id: String, pattern: String)] = [
        ("boundHost = nil", #"\bboundHost\s*=\s*nil\b"#),
        ("stayAwake.relayStopped", #"\bstayAwake\.relayStopped\s*\("#),
        ("stayAwake.willQuitInBackground", #"\bstayAwake\.willQuitInBackground\s*\("#),
        ("stayAwake.choiceChanged", #"\bstayAwake\.choiceChanged\s*\("#),
        ("stayAwake.powerChanged", #"\bstayAwake\.powerChanged\s*\("#),
        ("settings.useBuiltInTailscale = true", #"\bsettings\.useBuiltInTailscale\s*=\s*true\b"#),
        ("leaveRunner.run", #"\bleaveRunner\.run\s*\("#),
        ("startEngine()", #"\bstartEngine\s*\(\s*\)"#),
        ("supervisor.start", #"\bsupervisor\.start\s*\("#),
        ("applyChoice()", #"\bapplyChoice\s*\(\s*\)"#),
    ]

    static let rows: [Row] = [
        // After an end, on the app's own stop paths.
        Row(function: "stop", release: "stayAwake.relayStopped", count: 1, kind: .answer(keepAwake, extras: [])),
        Row(function: "stop", release: "boundHost = nil", count: 1, kind: .answer(boundAddress, extras: [])),
        Row(function: "signOut", release: "stayAwake.relayStopped", count: 1, kind: .answer(keepAwake, extras: [])),
        Row(function: "signOut", release: "boundHost = nil", count: 1, kind: .answer(boundAddress, extras: [])),
        Row(function: "shutDown", release: "boundHost = nil", count: 1, kind: .answer(boundAddress, extras: [])),
        Row(function: "shutDown", release: "stayAwake.willQuitInBackground", count: 1,
            kind: .declared(reason: "quit is the boundary: the hold is released as the app ends, whatever the engine's end")),
        // After an end, on the supervisor's reports.
        Row(function: "handleEngineStateChange", release: "boundHost = nil", count: 2, kind: .answer(boundAddress, extras: [])),
        Row(function: "handleEngineStateChange", release: "stayAwake.relayStopped", count: 1, kind: .answer(keepAwake, extras: [])),
        // The built-in choice and a leave child.
        Row(function: "chooseBuiltInTailscale", release: "settings.useBuiltInTailscale = true", count: 1,
            kind: .answer(builtInChoice, extras: ["settings.useBuiltInTailscale", "isLeavingRoute"])),
        Row(function: "leaveBuiltInRoute", release: "applyChoice()", count: 1, kind: .answer(builtInChoice, extras: [])),
        Row(function: "runPendingLeaveChild", release: "leaveRunner.run", count: 1,
            kind: .answer(leaveChildStart, extras: ["pendingLeaveRetry", "useBuiltInTailscale"])),
        // An engine start on the folder the engine may use: every start path asks.
        Row(function: "onLaunch", release: "startEngine()", count: 1, kind: .answer(engineStart, extras: ["canStart"])),
        Row(function: "start", release: "startEngine()", count: 1, kind: .answer(engineStart, extras: ["canStart"])),
        Row(function: "startFresh", release: "startEngine()", count: 1, kind: .answer(engineStart, extras: ["canStartFresh"])),
        Row(function: "tryAgain", release: "startEngine()", count: 1, kind: .answer(engineStart, extras: ["canTryAgain"])),
        Row(function: "signIn", release: "startEngine()", count: 1, kind: .answer(engineStart, extras: ["canStart", "outcome == .signedIn"])),
        Row(function: "retryBuiltInRoute", release: "startEngine()", count: 2, kind: .answer(engineStart, extras: ["canStart"])),
        Row(function: "updatePort", release: "startEngine()", count: 1, kind: .answer(engineStart, extras: ["engineState", "isPortLocked"])),
        Row(function: "restartEngineIfRunning", release: "startEngine()", count: 1, kind: .answer(engineStart, extras: ["stopEngineAndWait"])),
        Row(function: "startEngine", release: "supervisor.start", count: 1,
            kind: .declared(reason: "the start itself: each caller asks the start answer before it")),
        // Before any engine runs: the start was refused, so no address was bound.
        Row(function: "startEngine", release: "boundHost = nil", count: 4,
            kind: .reset(reason: "the start is refused before the engine is launched, so no address was bound")),
        // Not after an end: his rulings.
        Row(function: "saveStayAwake", release: "stayAwake.choiceChanged", count: 1,
            kind: .declared(reason: "keep-awake is his choice: turning it off is his, not an end")),
        Row(function: "init", release: "stayAwake.powerChanged", count: 1,
            kind: .declared(reason: "keep-awake is on power only: going to battery is his ruling, not an end")),
    ]

    /// stripped removes line and block comments (nested) and the contents of
    /// string literals, keeping everything else and the line structure.
    static func stripped(_ text: String) -> String {
        let chars = Array(text)
        var out = ""
        var index = 0
        var blockDepth = 0
        func peek(_ offset: Int) -> Character? { index + offset < chars.count ? chars[index + offset] : nil }
        while index < chars.count {
            let c = chars[index]
            if blockDepth > 0 {
                if c == "/", peek(1) == "*" { blockDepth += 1; index += 2; continue }
                if c == "*", peek(1) == "/" { blockDepth -= 1; index += 2; continue }
                if c == "\n" { out.append(c) }
                index += 1
                continue
            }
            if c == "/", peek(1) == "/" {
                while index < chars.count, chars[index] != "\n" { index += 1 }
                continue
            }
            if c == "/", peek(1) == "*" { blockDepth = 1; index += 2; continue }
            if c == "\"" {
                if peek(1) == "\"", peek(2) == "\"" {
                    index += 3
                    while index < chars.count, !(chars[index] == "\"" && peek(1) == "\"" && peek(2) == "\"") {
                        if chars[index] == "\n" { out.append("\n") }
                        index += 1
                    }
                    index += 3
                    out += "\"\"\"\"\"\""
                    continue
                }
                index += 1
                while index < chars.count, chars[index] != "\"", chars[index] != "\n" {
                    index += chars[index] == "\\" ? 2 : 1
                }
                index += 1
                out += "\"\""
                continue
            }
            out.append(c)
            index += 1
        }
        return out
    }

    /// ownerName is the name AppModel gives its ProcessLifetimes.
    static func ownerName(in source: String) -> String? {
        let patterns = [
            #"(?:let|var)\s+(\w+)\s*(?::\s*[\w.]+)?\s*=\s*ProcessLifetimes\s*\("#,
            #"(?:let|var)\s+(\w+)\s*:\s*ProcessLifetimes\b"#,
        ]
        for pattern in patterns {
            guard let regex = try? NSRegularExpression(pattern: pattern),
                  let match = regex.firstMatch(in: source, range: NSRange(source.startIndex..., in: source)),
                  let range = Range(match.range(at: 1), in: source)
            else { continue }
            return String(source[range])
        }
        return nil
    }

    /// Parsed is the stripped text with its braces matched, as UTF-16 offsets.
    struct Parsed {
        let text: String
        let ns: NSString
        let units: [UInt16]
        let closeOf: [Int: Int]
        /// parent is, for each offset, the open brace of the block it sits in (-1 for none).
        let parent: [Int]

        init(_ text: String) {
            self.text = text
            ns = text as NSString
            units = Array(text.utf16)
            var stack: [Int] = []
            var closes: [Int: Int] = [:]
            var parents = [Int](repeating: -1, count: units.count)
            for (index, unit) in units.enumerated() {
                if unit == 123 {
                    parents[index] = stack.last ?? -1
                    stack.append(index)
                } else if unit == 125 {
                    if let open = stack.popLast() { closes[open] = index }
                    parents[index] = stack.last ?? -1
                } else {
                    parents[index] = stack.last ?? -1
                }
            }
            closeOf = closes
            parent = parents
        }

        struct Function {
            let name: String
            let declaration: Int
            let open: Int
            let close: Int
        }

        func functions() -> [Function] {
            guard let regex = try? NSRegularExpression(pattern: #"\b(?:func\s+(\w+)|(init))\s*[(<]"#) else { return [] }
            var found: [Function] = []
            for match in regex.matches(in: text, range: NSRange(location: 0, length: ns.length)) {
                if match.range(at: 2).location != NSNotFound, match.range.location > 0, units[match.range.location - 1] == 46 { continue }
                let name = match.range(at: 1).location != NSNotFound ? ns.substring(with: match.range(at: 1)) : "init"
                var index = match.range.location + match.range.length
                while index < units.count, units[index] != 123, units[index] != 59 { index += 1 }
                guard index < units.count, units[index] == 123, let close = closeOf[index] else { continue }
                found.append(Function(name: name, declaration: match.range.location, open: index, close: close))
            }
            return found
        }

        func innermost(_ functions: [Function], at position: Int) -> Function? {
            functions.filter { $0.open < position && position < $0.close }.max { $0.open < $1.open }
        }

        struct Condition {
            let keyword: String
            let text: String
            let start: Int
            let open: Int
            let close: Int
            let elseRange: Range<Int>?
            let leaves: Bool
        }

        func conditions(in range: Range<Int>) -> [Condition] {
            guard let regex = try? NSRegularExpression(pattern: #"\b(if|guard|while)\b([^{]*)\{"#),
                  let exit = try? NSRegularExpression(pattern: #"\b(return|break|continue|throw|fatalError)\b"#)
            else { return [] }
            var found: [Condition] = []
            for match in regex.matches(in: text, range: NSRange(location: range.lowerBound, length: range.count)) {
                let open = match.range.location + match.range.length - 1
                guard let close = closeOf[open] else { continue }
                var elseRange: Range<Int>?
                var after = close + 1
                while after < units.count, [32, 10, 9, 13].contains(units[after]) { after += 1 }
                if after + 4 <= units.count, ns.substring(with: NSRange(location: after, length: 4)) == "else" {
                    after += 4
                    while after < units.count, [32, 10, 9, 13].contains(units[after]) { after += 1 }
                    if after < units.count, units[after] == 123, let elseClose = closeOf[after] { elseRange = after..<elseClose }
                }
                let block = NSRange(location: open + 1, length: close - open - 1)
                found.append(Condition(
                    keyword: ns.substring(with: match.range(at: 1)),
                    text: ns.substring(with: match.range(at: 2)).replacingOccurrences(of: #"\belse\s*$"#, with: "", options: .regularExpression),
                    start: match.range.location,
                    open: open,
                    close: close,
                    elseRange: elseRange,
                    leaves: exit.firstMatch(in: text, range: block) != nil
                ))
            }
            return found
        }

        /// labelBetween is whether a `case` or `default` label of the block
        /// that holds `scope` lies in the text from `from` to `to`: a guard
        /// above one case does not govern another.
        func labelBetween(_ from: Int, _ to: Int, scope: Int) -> Bool {
            guard from < to, let regex = try? NSRegularExpression(pattern: #"\bcase\b[^\n{;]*:|\bdefault\s*:"#) else { return false }
            return regex.matches(in: text, range: NSRange(location: from, length: to - from)).contains { parent[$0.range.location] == scope }
        }
    }

    /// clauses splits a condition at its top-level commas and `&&`, whitespace collapsed.
    static func clauses(_ condition: String) -> [String] {
        var out: [String] = []
        var depth = 0
        var current = ""
        let chars = Array(condition)
        var index = 0
        while index < chars.count {
            let c = chars[index]
            if "([<".contains(c) { depth += 1 }
            if ")]>".contains(c), depth > 0, !(c == ">" && index > 0 && chars[index - 1] == "-") { depth -= 1 }
            if depth == 0, c == "," {
                out.append(current)
                current = ""
            } else if depth == 0, c == "&", index + 1 < chars.count, chars[index + 1] == "&" {
                out.append(current)
                current = ""
                index += 1
            } else {
                current.append(c)
            }
            index += 1
        }
        out.append(current)
        return out
            .map { $0.split(whereSeparator: \.isWhitespace).joined(separator: " ") }
            // A binding () only unwraps a value: it is no state term.
            .filter { !$0.isEmpty && !$0.hasPrefix("let ") && !$0.hasPrefix("var ") }
    }

    /// governingClauses are the clauses of every condition that governs the
    /// release at `position` in `function`: an enclosing `if` or `while` (or
    /// its else), an earlier `guard` of an enclosing block, an earlier `if`
    /// that leaves, and the condition of a ternary the release sits in.
    static func governingClauses(at position: Int, in parsed: Parsed, function: Parsed.Function) -> [String] {
        var out: [String] = []
        for condition in parsed.conditions(in: (function.open + 1)..<function.close) {
            let scope = parsed.parent[condition.start]
            var governs = false
            var viaEarlier = false
            if condition.keyword == "guard" {
                governs = condition.close < position
                viaEarlier = true
            } else if (condition.open < position && position < condition.close) || (condition.elseRange?.contains(position) ?? false) {
                governs = true
            } else if condition.leaves, condition.close < position {
                governs = true
                viaEarlier = true
            }
            if governs, viaEarlier {
                // An earlier statement governs only from the block that holds it.
                let held = scope >= 0 && scope < position && (parsed.closeOf[scope].map { position < $0 } ?? false)
                if !held || parsed.labelBetween(condition.close, position, scope: scope) { governs = false }
            }
            if governs { out += clauses(condition.text) }
        }
        // A ternary: `cond ? release : other` on the release's own line.
        let lineStart = (parsed.ns.range(of: "\n", options: .backwards, range: NSRange(location: 0, length: position)).upperBound)
        let prefix = parsed.ns.substring(with: NSRange(location: lineStart, length: position - lineStart))
        if let mark = try? NSRegularExpression(pattern: #"\?\s*$"#), let hit = mark.firstMatch(in: prefix, range: NSRange(location: 0, length: (prefix as NSString).length)) {
            var cond = (prefix as NSString).substring(to: hit.range.location)
            for strip in [#"^\s*(?:async\s+)?(?:let|var)\s+\w+\s*(?::\s*[\w<>.?]+)?\s*=\s*"#, #"^\s*(?:await\s+)?(?:return\s+)?"#] {
                if let regex = try? NSRegularExpression(pattern: strip), let hit = regex.firstMatch(in: cond, range: NSRange(location: 0, length: (cond as NSString).length)) {
                    cond = (cond as NSString).substring(from: hit.range.location + hit.range.length)
                }
            }
            out += clauses(cond)
        }
        return out
    }

    static func ownerAnswers(in clause: String, owner: String) -> [String] {
        let pattern = #"\b"# + NSRegularExpression.escapedPattern(for: owner) + #"\.(\w+)"#
        guard let regex = try? NSRegularExpression(pattern: pattern) else { return [] }
        let ns = clause as NSString
        return regex.matches(in: clause, range: NSRange(location: 0, length: ns.length)).map { ns.substring(with: $0.range(at: 1)) }
    }

    struct Occurrence {
        let release: String
        let position: Int
        let function: String?
    }

    static func occurrences(in parsed: Parsed) -> [Occurrence] {
        let functions = parsed.functions()
        var found: [Occurrence] = []
        for release in releases {
            guard let regex = try? NSRegularExpression(pattern: release.pattern) else { continue }
            for match in regex.matches(in: parsed.text, range: NSRange(location: 0, length: parsed.ns.length)) {
                let before = parsed.ns.substring(to: match.range.location).trimmingCharacters(in: .whitespaces)
                if release.id == "startEngine()", before.hasSuffix("func") { continue }
                found.append(Occurrence(
                    release: release.id,
                    position: match.range.location,
                    function: parsed.innermost(functions, at: match.range.location)?.name
                ))
            }
        }
        return found.sorted { $0.position < $1.position }
    }

    /// violations lists everything in AppModel's text that breaks the table:
    /// each line starts with the function it is about, then a colon.
    static func violations(in rawSource: String) -> [String] {
        let source = stripped(rawSource)
        guard let owner = ownerName(in: source) else {
            return ["AppModel: declares no ProcessLifetimes owner"]
        }
        let parsed = Parsed(source)
        let functions = parsed.functions()
        let all = occurrences(in: parsed)
        var found: [String] = []

        // Whole file: every token is in a row, every row's token is found.
        var keys: [String] = []
        for row in rows where !keys.contains("\(row.function)|\(row.release)") { keys.append("\(row.function)|\(row.release)") }
        for occurrence in all {
            let name = occurrence.function ?? "(outside every function)"
            if !keys.contains("\(name)|\(occurrence.release)") {
                found.append("\(name): \(occurrence.release) is in no row")
            }
        }
        for key in keys {
            let parts = key.split(separator: "|", maxSplits: 1).map(String.init)
            let expectedCount = rows.filter { $0.function == parts[0] && $0.release == parts[1] }.map(\.count).reduce(0, +)
            let here = all.filter { $0.function == parts[0] && $0.release == parts[1] }
            if here.count < expectedCount {
                found.append("\(parts[0]): \(parts[1]) not found (\(here.count) of \(expectedCount))")
            } else if here.count > expectedCount {
                found.append("\(parts[0]): \(parts[1]) found \(here.count) times, rows allow \(expectedCount)")
            }
        }

        // Each answer row: its own answer, nothing else.
        for row in rows {
            let here = all.filter { $0.function == row.function && $0.release == row.release }
            guard let function = functions.first(where: { $0.name == row.function }) else { continue }
            switch row.kind {
            case .declared: break
            case .reset:
                if let start = all.first(where: { $0.function == row.function && $0.release == "supervisor.start" }) {
                    for occurrence in here where occurrence.position > start.position {
                        found.append("\(row.function): \(row.release) is a reset but comes after the engine start")
                    }
                }
            case .answer(let answer, let extras):
                for (index, occurrence) in here.enumerated() {
                    let owning = functions.filter { $0.name == row.function }.first { $0.open < occurrence.position && occurrence.position < $0.close } ?? function
                    let clauses = governingClauses(at: occurrence.position, in: parsed, function: owning)
                    let label = "\(row.function): \(row.release) #\(index + 1)"
                    var asked: Set<String> = []
                    var problems: [String] = []
                    for clause in clauses {
                        let names = ownerAnswers(in: clause, owner: owner)
                        if !names.isEmpty {
                            asked.formUnion(names)
                            if clause.contains("||") { problems.append("answer weakened by an or: `\(clause)`") }
                        } else if clause.contains("engineHoldsFolder") {
                            problems.append("an owner answer under another name: `\(clause)`")
                        } else if !extras.contains(where: { clause.contains($0) }) {
                            problems.append("undeclared term `\(clause)`")
                        }
                    }
                    if asked.isEmpty {
                        found.append("\(label) is guarded by no owner answer, expects `\(answer)`")
                    } else if asked != [answer] {
                        found.append("\(label) is guarded by `\(asked.sorted().joined(separator: ", "))`, expects only `\(answer)`")
                    }
                    for problem in problems { found.append("\(label): \(problem)") }
                }
            }
        }
        return found
    }

    /// mappingProblem is why AppModel does not hand every supervisor state to
    /// the owner's mapping, nil when it does.
    static func mappingProblem(in rawSource: String) -> String? {
        let source = stripped(rawSource)
        guard let owner = ownerName(in: source) else { return "declares no owner" }
        let parsed = Parsed(source)
        guard let function = parsed.functions().first(where: { $0.name == "handleEngineStateChange" }) else { return "handleEngineStateChange not found" }
        let body = parsed.ns.substring(with: NSRange(location: function.open + 1, length: function.close - function.open - 1))
        if !body.contains("\(owner).\(mappingName)(") { return "handleEngineStateChange never calls \(owner).\(mappingName)" }
        for own in ["engineStarted(", "engineEnded("] where body.contains("\(owner).\(own)") {
            return "handleEngineStateChange keeps its own copy of the mapping (\(own))"
        }
        return nil
    }
}

/// Plant is a fault put into an in-memory copy of a source, whatever the
/// check is. It never touches a file.
enum Plant: Sendable, Hashable, CustomTestStringConvertible {
    /// stoppedBoundAddressGuardedByKeepAwakeAlone is the F1 mutation: the
    /// .stopped branch's bound-address release guarded by the keep-awake
    /// answer alone.
    case stoppedBoundAddressGuardedByKeepAwakeAlone
    case wrongAnswer(function: String, answer: String)
    case guardRemoved(function: String, answer: String)
    case guardAfterRelease(function: String, answer: String)
    case extraTerm(function: String, answer: String)
    case weakenedGuard(function: String, answer: String)
    case releaseGone(function: String, release: String)
    case releaseInHelper(function: String, release: String)
    case newUnguardedRelease

    var testDescription: String {
        switch self {
        case .stoppedBoundAddressGuardedByKeepAwakeAlone: "F1: .stopped address release guarded by keep-awake alone"
        case .wrongAnswer(let f, let a): "\(f): \(a) swapped for another release's answer"
        case .guardRemoved(let f, let a): "\(f): \(a) guard removed"
        case .guardAfterRelease(let f, let a): "\(f): \(a) asked after the release"
        case .extraTerm(let f, let a): "\(f): undeclared term joined to \(a)"
        case .weakenedGuard(let f, let a): "\(f): \(a) weakened by an or"
        case .releaseGone(let f, let r): "\(f): \(r) no longer found"
        case .releaseInHelper(let f, let r): "\(f): \(r) moved into a helper"
        case .newUnguardedRelease: "a new unguarded boundHost = nil in a function no row names"
        }
    }

    /// function is the function the check must name for this plant.
    var function: String {
        switch self {
        case .stoppedBoundAddressGuardedByKeepAwakeAlone: "handleEngineStateChange"
        case .wrongAnswer(let f, _), .guardRemoved(let f, _), .guardAfterRelease(let f, _), .extraTerm(let f, _), .weakenedGuard(let f, _): f
        case .releaseGone(let f, _), .releaseInHelper(let f, _): f
        case .newUnguardedRelease: "k31Plant"
        }
    }

    /// all is every plant the table allows: each release removed and moved,
    /// and each answer row's guard swapped, removed, moved after, joined to an
    /// undeclared term and weakened.
    static let all: [Plant] = {
        var plants: [Plant] = [.stoppedBoundAddressGuardedByKeepAwakeAlone, .newUnguardedRelease]
        var seen: Set<String> = []
        for row in AppModelSource.rows {
            plants.append(.releaseGone(function: row.function, release: row.release))
            plants.append(.releaseInHelper(function: row.function, release: row.release))
            if case .answer(let answer, _) = row.kind, seen.insert("\(row.function)|\(answer)").inserted {
                plants.append(.wrongAnswer(function: row.function, answer: answer))
                plants.append(.guardRemoved(function: row.function, answer: answer))
                plants.append(.guardAfterRelease(function: row.function, answer: answer))
                plants.append(.extraTerm(function: row.function, answer: answer))
                plants.append(.weakenedGuard(function: row.function, answer: answer))
            }
        }
        return plants
    }()

    /// apply returns the stripped source with the fault planted, or nil when
    /// the source has nothing for the fault to change.
    func apply(to raw: String) -> String? {
        var source = AppModelSource.stripped(raw)
        guard let owner = AppModelSource.ownerName(in: source) else { return nil }

        func bodyRange(_ name: String, in text: String) -> NSRange? {
            let parsed = AppModelSource.Parsed(text)
            return parsed.functions().first { $0.name == name }.map { NSRange(location: $0.open + 1, length: $0.close - $0.open - 1) }
        }
        func answerRegex(_ answer: String) -> NSRegularExpression {
            try! NSRegularExpression(pattern: #"\b"# + NSRegularExpression.escapedPattern(for: owner) + #"\."# + answer + #"\b(\([^()]*\))?"#)
        }
        func rewriteAnswer(_ function: String, _ answer: String, template: String) -> String? {
            guard let range = bodyRange(function, in: source) else { return nil }
            let regex = answerRegex(answer)
            guard regex.numberOfMatches(in: source, range: range) > 0 else { return nil }
            return regex.stringByReplacingMatches(in: source, range: range, withTemplate: template)
        }

        switch self {
        case .stoppedBoundAddressGuardedByKeepAwakeAlone:
            guard let range = bodyRange("handleEngineStateChange", in: source),
                  let label = (source as NSString).range(of: "case .stopped:", range: range) as NSRange?, label.location != NSNotFound,
                  let regex = try? NSRegularExpression(pattern: #"\bif\b([^{]*)\{"#),
                  let hit = regex.firstMatch(in: source, range: NSRange(location: label.location, length: range.location + range.length - label.location))
            else { return nil }
            return (source as NSString).replacingCharacters(in: hit.range(at: 1), with: " \(owner).\(AppModelSource.keepAwake) ")

        case .wrongAnswer(let function, let answer):
            let used = Set(AppModelSource.rows.filter { $0.function == function }.compactMap { row -> String? in
                if case .answer(let a, _) = row.kind { a } else { nil }
            })
            guard let other = AppModelSource.answerNames.first(where: { !used.contains($0) }) else { return nil }
            return rewriteAnswer(function, answer, template: "\(owner).\(other)$1")

        case .guardRemoved(let function, let answer):
            return rewriteAnswer(function, answer, template: "true")

        case .guardAfterRelease(let function, let answer):
            guard let removed = rewriteAnswer(function, answer, template: "true") else { return nil }
            let parsed = AppModelSource.Parsed(removed)
            guard let target = parsed.functions().first(where: { $0.name == function }) else { return nil }
            return (removed as NSString).replacingCharacters(in: NSRange(location: target.close, length: 0), with: "\nif \(owner).\(answer) {\n}\n")

        case .extraTerm(let function, let answer):
            return rewriteAnswer(function, answer, template: "$0, k31ExtraTerm")

        case .weakenedGuard(let function, let answer):
            return rewriteAnswer(function, answer, template: "($0 || k31OtherTerm)")

        case .releaseGone(let function, let release):
            guard let range = bodyRange(function, in: source),
                  let pattern = AppModelSource.releases.first(where: { $0.id == release })?.pattern,
                  let regex = try? NSRegularExpression(pattern: pattern),
                  let hit = regex.firstMatch(in: source, range: range)
            else { return nil }
            let text = (source as NSString).substring(with: hit.range)
            return (source as NSString).replacingCharacters(in: hit.range, with: "k31_" + text)

        case .releaseInHelper(let function, let release):
            let parsed = AppModelSource.Parsed(source)
            guard let target = parsed.functions().first(where: { $0.name == function }),
                  let pattern = AppModelSource.releases.first(where: { $0.id == release })?.pattern,
                  let regex = try? NSRegularExpression(pattern: pattern),
                  let hit = regex.firstMatch(in: source, range: NSRange(location: target.open + 1, length: target.close - target.open - 1))
            else { return nil }
            var end = hit.range.location + hit.range.length
            if (source as NSString).substring(with: hit.range).hasSuffix("(") {
                var depth = 1
                while end < parsed.units.count, depth > 0 {
                    if parsed.units[end] == 40 { depth += 1 }
                    if parsed.units[end] == 41 { depth -= 1 }
                    end += 1
                }
            }
            let statement = (source as NSString).substring(with: NSRange(location: hit.range.location, length: end - hit.range.location))
            let lineStart = (source as NSString).range(of: "\n", options: .backwards, range: NSRange(location: 0, length: target.declaration)).upperBound
            var edited = (source as NSString).replacingCharacters(in: NSRange(location: hit.range.location, length: end - hit.range.location), with: "k31Helper()")
            edited = (edited as NSString).replacingCharacters(in: NSRange(location: lineStart, length: 0), with: "private func k31Helper() {\n\(statement)\n}\n")
            return edited

        case .newUnguardedRelease:
            guard let regex = try? NSRegularExpression(pattern: #"\bfunc\s+startEngine\b"#),
                  let hit = regex.firstMatch(in: source, range: NSRange(location: 0, length: (source as NSString).length))
            else { return nil }
            let lineStart = (source as NSString).range(of: "\n", options: .backwards, range: NSRange(location: 0, length: hit.range.location)).upperBound
            source = (source as NSString).replacingCharacters(in: NSRange(location: lineStart, length: 0), with: "private func k31Plant() {\nboundHost = nil\n}\n")
            return source
        }
    }
}

@Suite("AppModel acts on ProcessLifetimes")
struct AppModelConsultTests {
    /// A source shaped like AppModel in the places the check reads, in the
    /// design the story asks for: each release asks its own answer, the
    /// start paths ask the start answer, and the supervisor's state goes to
    /// the owner's mapping.
    static let conformingSource = """
    @MainActor final class AppModel {
        private let lifetimes = ProcessLifetimes()
        init() {
            let watcher = PowerSourceWatcher { [weak self] in
                guard let self else { return }
                self.stayAwake.powerChanged(self.powerSource.snapshot())
            }
        }
        private func onLaunch() async {
            Task { await runPendingLeaveChild() }
            async let engineStarted: Void = canStart && lifetimes.mayStartEngine(onKeptFolder: settings.useBuiltInTailscale) ? startEngine() : ()
            _ = await engineStarted
        }
        func start() {
            guard canStart, lifetimes.mayStartEngine(onKeptFolder: settings.useBuiltInTailscale) else { return }
            Task { await startEngine() }
        }
        /// stop releases keep-awake: lifetimes.keepAwakeMayBeReleased (a comment, not a consult)
        func stop() {
            stopRequested = true
            Task {
                _ = await stopEngineAndWait()
                if lifetimes.keepAwakeMayBeReleased { stayAwake.relayStopped() }
                if lifetimes.mayReleaseBoundAddress { boundHost = nil }
            }
        }
        func startFresh() {
            guard canStartFresh else { return }
            Task {
                guard canStartFresh, lifetimes.mayStartEngine(onKeptFolder: settings.useBuiltInTailscale) else { return }
                await supervisor.clearFailure()
                await startEngine()
            }
        }
        func tryAgain() {
            guard canTryAgain, lifetimes.mayStartEngine(onKeptFolder: settings.useBuiltInTailscale) else { return }
            Task {
                await supervisor.clearFailure()
                await startEngine()
            }
        }
        func shutDown() async {
            await stayAwake.willQuitInBackground()
            _ = await stopEngineAndWait()
            if lifetimes.mayReleaseBoundAddress { boundHost = nil }
        }
        func signIn(email: String) async -> AccountCheckOutcome {
            let outcome = await accountSignIn.signIn(email: email)
            if outcome == .signedIn {
                if canStart, lifetimes.mayStartEngine(onKeptFolder: settings.useBuiltInTailscale) {
                    await startEngine()
                }
            }
            return outcome
        }
        func signOut() async -> Bool {
            _ = await stopEngineAndWait()
            if lifetimes.keepAwakeMayBeReleased { stayAwake.relayStopped() }
            if lifetimes.mayReleaseBoundAddress { boundHost = nil }
            return true
        }
        func chooseBuiltInTailscale() {
            guard !settings.useBuiltInTailscale, !isLeavingRoute, !lifetimes.builtInChoiceBlocked else { return }
            settings.useBuiltInTailscale = true
        }
        private func leaveBuiltInRoute(for trigger: LeaveTrigger, applyChoice: () async -> Void) async {
            guard !lifetimes.builtInChoiceBlocked else { return }
            for step in steps {
                switch step {
                case .leave: await routeLeaver.leave()
                case .applyChoice: await applyChoice()
                }
            }
        }
        private func runPendingLeaveChild() async {
            guard lifetimes.mayStartLeaveChild, settings.pendingLeaveRetry, !settings.useBuiltInTailscale else { return }
            lifetimes.leaveChildStarted()
            let result = await leaveRunner.run(configuration)
            if case .notConfirmedEnded = result { lifetimes.leaveChildEnded(confirmed: false) } else { lifetimes.leaveChildEnded(confirmed: true) }
        }
        func retryBuiltInRoute() {
            Task {
                switch engineState {
                case .failed(.engineStatusUnknown):
                    return
                case .failed:
                    await supervisor.clearFailure()
                    if lifetimes.mayStartEngine(onKeptFolder: settings.useBuiltInTailscale) { await startEngine() }
                case .stopped:
                    if canStart, lifetimes.mayStartEngine(onKeptFolder: settings.useBuiltInTailscale) { await startEngine() }
                case .starting, .running, .waitingToRestart:
                    await restartEngineIfRunning()
                }
            }
        }
        func updatePort() {
            Task {
                if engineState == .failed(.portInUse), lifetimes.mayStartEngine(onKeptFolder: settings.useBuiltInTailscale) {
                    await supervisor.clearFailure()
                    await startEngine()
                } else {
                    await restartEngineIfRunning()
                }
            }
        }
        private func saveStayAwake(_ choice: StayAwakeChoice) {
            settings.stayAwake = choice
            stayAwake.choiceChanged(choice)
        }
        private func restartEngineIfRunning() async {
            switch engineState {
            case .starting, .running, .waitingToRestart:
                guard await stopEngineAndWait() else { return }
                if lifetimes.mayStartEngine(onKeptFolder: settings.useBuiltInTailscale) {
                    await startEngine()
                }
            case .stopped, .failed:
                return
            }
        }
        private func startEngine() async {
            stopRequested = false
            if DatabaseRecovery.hasSplitMove(databasePath: databasePath) {
                boundHost = nil
                await supervisor.fail(.recoveryMoveFailed)
                return
            }
            if let refusal = choosePortBeforeStart() {
                boundHost = nil
                await supervisor.fail(refusal)
                return
            }
            if settings.useBuiltInTailscale {
                guard let stateDirectory = builtInStateDirectory() else {
                    boundHost = nil
                    await supervisor.fail(.configurationUnreadable)
                    return
                }
            }
            guard let configuration = try? build() else {
                boundHost = nil
                await supervisor.fail(.configurationUnreadable)
                return
            }
            boundHost = ReachAddressResolver.bindHost(for: settings.effectiveReach)
            await supervisor.start(configuration: configuration)
        }
        private func handleEngineStateChange(_ state: EngineSupervisor.RunState) {
            lifetimes.engineStateReported(state, usingKeptFolder: engineUsesKeptFolder)
            switch state {
            case .stopped:
                if lifetimes.mayReleaseBoundAddress {
                    boundHost = nil
                }
            case .failed:
                if lifetimes.mayReleaseBoundAddress { boundHost = nil }
                if lifetimes.keepAwakeMayBeReleased { stayAwake.relayStopped() }
            case .running:
                if !stopRequested { stayAwake.relayStarted() }
            default: break
            }
            engineState = state
        }
    }
    """

    @Test("the check passes a source in which every release asks its own answer")
    func conformingSourcePasses() {
        #expect(AppModelSource.violations(in: Self.conformingSource) == [])
        #expect(AppModelSource.mappingProblem(in: Self.conformingSource) == nil)
    }

    @Test("every row declares its reason, and the table has a row for each place the story names")
    func tableIsComplete() {
        for row in AppModelSource.rows {
            switch row.kind {
            case .reset(let reason), .declared(let reason): #expect(!reason.isEmpty, "\(row.function) \(row.release)")
            case .answer(let answer, _): #expect(AppModelSource.answerNames.contains(answer), "\(row.function) \(row.release)")
            }
        }
        let resets = AppModelSource.rows.filter { if case .reset = $0.kind { true } else { false } }
        #expect(resets.map(\.count).reduce(0, +) == 4, "the four start-path resets in startEngine are rows of their own")
        #expect(AppModelSource.rows.contains { $0.function == "shutDown" && $0.release == "stayAwake.willQuitInBackground" })
        #expect(AppModelSource.rows.contains { $0.function == "saveStayAwake" })
        #expect(AppModelSource.rows.contains { $0.function == "init" && $0.release == "stayAwake.powerChanged" })
        #expect(AppModelSource.answerNames.count == 5 && Set(AppModelSource.answerNames).count == 5)
    }

    @Test("a planted fault in a scratch copy of a conforming source turns the check red for that function", arguments: Plant.all)
    func plantIsCaught(plant: Plant) throws {
        let planted = try #require(plant.apply(to: Self.conformingSource), "\(plant.testDescription) does not apply to the conforming source")
        let violations = AppModelSource.violations(in: planted)
        #expect(violations.contains { $0.hasPrefix("\(plant.function):") }, Comment(rawValue: "\(plant.testDescription): \(violations)"))
    }

    @Test("a planted fault is not read as the guard it replaces: the same plant on the conforming source never changes a function it was not planted in", arguments: Plant.all)
    func plantStaysInItsFunction(plant: Plant) throws {
        let planted = try #require(plant.apply(to: Self.conformingSource))
        let others = AppModelSource.violations(in: planted).filter { !$0.hasPrefix("\(plant.function):") && !$0.hasPrefix("k31Helper:") }
        #expect(others.isEmpty, Comment(rawValue: "\(plant.testDescription): \(others)"))
    }

    @Test("the check goes red when AppModel declares no owner at all")
    func noOwnerIsCaught() {
        let source = Self.conformingSource.replacingOccurrences(of: "private let lifetimes = ProcessLifetimes()", with: "")
        #expect(!AppModelSource.violations(in: source).isEmpty)
    }

    @Test("a state handler that keeps its own copy of the owner's mapping is caught")
    func handCopyOfTheMappingIsCaught() {
        let withCopy = Self.conformingSource.replacingOccurrences(
            of: "lifetimes.engineStateReported(state, usingKeptFolder: engineUsesKeptFolder)",
            with: "lifetimes.engineEnded(confirmed: true)"
        )
        #expect(withCopy != Self.conformingSource)
        #expect(AppModelSource.mappingProblem(in: withCopy) != nil)
    }

    private static func appModelText() throws -> String {
        var url = URL(fileURLWithPath: #filePath)
        for _ in 0..<5 { url.deleteLastPathComponent() }
        url.appendPathComponent("App/Sources/AppModel.swift")
        return try String(contentsOf: url, encoding: .utf8)
    }

    @Test("every release in the app's own AppModel asks its own answer and nothing else")
    func appModelActsOnTheOwner() throws {
        #expect(AppModelSource.violations(in: try Self.appModelText()) == [])
    }

    @Test("the app's own AppModel hands every supervisor state to the owner's mapping")
    func appModelUsesTheOwnersMapping() throws {
        #expect(AppModelSource.mappingProblem(in: try Self.appModelText()) == nil)
    }

    @Test("each planted fault in a scratch copy of the app's own AppModel turns the check red for that function", arguments: Plant.all)
    func plantInTheAppsOwnCopyIsCaught(plant: Plant) throws {
        let text = try Self.appModelText()
        let baseline = AppModelSource.violations(in: text)
        let planted = try #require(plant.apply(to: text), "\(plant.testDescription) does not apply to AppModel: it has nothing there to change")
        let after = AppModelSource.violations(in: planted)
        #expect(after.contains { $0.hasPrefix("\(plant.function):") && !baseline.contains($0) }, Comment(rawValue: "\(plant.testDescription): \(after)"))
    }
}

// MARK: - The supervisor's header claims only what holds

/// EngineSupervisorHeader reads the doc comment above the type. Plain stop()
/// asks the engine to exit and does not wait, and a start after it is allowed,
/// so a claim that no second engine starts while the first may still run holds
/// only on the stopAndWait path the app uses; the header must say so.
enum EngineSupervisorHeader {
    static func header(of source: String) -> String? {
        let lines = source.components(separatedBy: "\n")
        guard let declaration = lines.firstIndex(where: { $0.contains("actor EngineSupervisor") }) else { return nil }
        var comment: [String] = []
        var index = declaration - 1
        while index >= 0, lines[index].trimmingCharacters(in: .whitespaces).hasPrefix("///") {
            comment.insert(String(lines[index].trimmingCharacters(in: .whitespaces).dropFirst(3)), at: 0)
            index -= 1
        }
        return comment.isEmpty ? nil : comment.joined(separator: " ").split(whereSeparator: \.isWhitespace).joined(separator: " ")
    }

    /// problems lists what in the header claims more than plain stop() keeps.
    static func problems(_ header: String) -> [String] {
        // A parenthetical pointer ("see stopAndWait") is not the claim's own condition.
        let bare = header.replacingOccurrences(of: #"\([^)]*\)"#, with: "", options: .regularExpression)
        let sentences = bare.components(separatedBy: CharacterSet(charactersIn: ".;")).map { $0.trimmingCharacters(in: .whitespaces) }
        var found: [String] = []
        for sentence in sentences {
            for claim in ["second engine", "ends the child", "end of the child"] where sentence.localizedCaseInsensitiveContains(claim) {
                if !sentence.contains("stopAndWait") {
                    found.append("claims \"\(claim)\" without saying it holds on the stopAndWait path: \(sentence)")
                }
            }
        }
        if header.range(of: #"stop\(\)[^.;]*(does not wait|not wait|without waiting|only asks)"#, options: .regularExpression) == nil {
            found.append("does not describe plain stop(): that it asks the engine to exit and does not wait")
        }
        return found
    }
}

@Suite("EngineSupervisor header")
struct EngineSupervisorHeaderTests {
    /// What the header said before it was corrected.
    static let overclaiming = """
    /// EngineSupervisor starts the engine as a child process, restarts it
    /// with backoff if it exits on its own, once stopped ends the child it started
    /// or reports that it could not confirm that end (see stopAndWait), and starts
    /// no second engine while the first may still be running. It is an actor
    public actor EngineSupervisor {
    """

    static let honest = """
    /// EngineSupervisor starts the engine as a child process and restarts it
    /// with backoff if it exits on its own. On the stopAndWait path, the one the
    /// app uses, it ends the child it started or reports that it could not
    /// confirm that end, and starts no second engine while the first may still
    /// be running. Plain stop() only asks the engine to exit and does not wait.
    public actor EngineSupervisor {
    """

    @Test("a header that claims no second engine without the stopAndWait path is caught")
    func overclaimIsCaught() throws {
        let header = try #require(EngineSupervisorHeader.header(of: Self.overclaiming))
        #expect(EngineSupervisorHeader.problems(header).count >= 2)
    }

    @Test("a header that says where the guarantee holds and what plain stop() does passes")
    func honestHeaderPasses() throws {
        let header = try #require(EngineSupervisorHeader.header(of: Self.honest))
        #expect(EngineSupervisorHeader.problems(header) == [])
    }

    @Test("EngineSupervisor's own header claims only what holds when the app uses stopAndWait and plain stop() merely asks")
    func supervisorHeaderClaimsOnlyWhatHolds() throws {
        var url = URL(fileURLWithPath: #filePath)
        for _ in 0..<2 { url.deleteLastPathComponent() }
        url.deleteLastPathComponent()
        url.appendPathComponent("Sources/CGMRelayCore/EngineSupervisor.swift")
        let source = try String(contentsOf: url, encoding: .utf8)
        let header = try #require(EngineSupervisorHeader.header(of: source), "no header above the type")
        #expect(EngineSupervisorHeader.problems(header) == [])
    }
}
