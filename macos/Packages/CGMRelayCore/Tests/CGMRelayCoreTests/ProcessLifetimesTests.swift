import Testing
import Foundation
@testable import CGMRelayCore

// ProcessLifetimes is the one owner of when the engine and the logout child
// count as running. An end that is not confirmed counts as running until the
// app quits: nothing here, and nothing a caller does, releases it.

/// What each lifetime has been driven to. The two helpers below drive a real
/// ProcessLifetimes to one of these through its own transitions.
enum EngineLife: CaseIterable, CustomTestStringConvertible {
    case none, running, confirming, ended, notConfirmed
    var testDescription: String { "engine \(self)" }
}

enum LeaveLife: CaseIterable, CustomTestStringConvertible {
    case none, running, ended, notConfirmed
    var testDescription: String { "leave child \(self)" }
}

/// Answers is everything ProcessLifetimes tells its callers.
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
private func drive(_ lifetimes: ProcessLifetimes, engine: EngineLife, leave: LeaveLife) {
    switch engine {
    case .none: break
    case .running: lifetimes.engineStarted()
    case .confirming:
        lifetimes.engineStarted()
        lifetimes.engineStopRequested()
    case .ended:
        lifetimes.engineStarted()
        lifetimes.engineStopRequested()
        lifetimes.engineEnded(confirmed: true)
    case .notConfirmed:
        lifetimes.engineStarted()
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
/// whose end is not confirmed is a process still running.
private func expected(engine: EngineLife, leave: LeaveLife) -> Answers {
    let engineHolds = engine == .running || engine == .confirming || engine == .notConfirmed
    let leaveHolds = leave == .running || leave == .notConfirmed
    return Answers(
        holdsTailscaleFolder: engineHolds || leaveHolds,
        builtInChoiceBlocked: leaveHolds || engine == .notConfirmed,
        mayStartLeaveChild: !(engineHolds || leaveHolds),
        keepAwakeMayBeReleased: engine != .notConfirmed
    )
}

/// SupervisorFeed carries the real EngineSupervisor's state changes to a
/// ProcessLifetimes the way the app does: a start is a running engine, and an
/// end reported as not confirmed is a lifetime that stays held. The caller's
/// own stop request and a confirmed stop are recorded by the test, as they are
/// by the caller that asked.
@MainActor
private final class SupervisorFeed {
    let lifetimes = ProcessLifetimes()
    private let states = ObservedUpdates<EngineSupervisor.RunState>()
    private var applied = 0

    nonisolated var onStateChange: @Sendable (EngineSupervisor.RunState) -> Void {
        { [states] state in states.append(state) }
    }

    func applyReportedStates() {
        let all = states.values
        for state in all[applied...] {
            switch state {
            case .starting: lifetimes.engineStarted()
            case .failed(.engineStatusUnknown): lifetimes.engineEnded(confirmed: false)
            default: break
            }
        }
        applied = all.count
    }
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

    @Test("every pair of engine and leave child states answers by the rule that an unconfirmed end is a process still running", arguments: EngineLife.allCases, LeaveLife.allCases)
    func everyPairOfStates(engine: EngineLife, leave: LeaveLife) {
        let lifetimes = ProcessLifetimes()
        drive(lifetimes, engine: engine, leave: leave)
        #expect(answers(lifetimes) == expected(engine: engine, leave: leave))
    }

    @Test("a confirmed end releases what it held, and a stopped engine can be started again")
    func confirmedEndReleases() {
        let lifetimes = ProcessLifetimes()
        lifetimes.engineStarted()
        lifetimes.engineStopRequested()
        #expect(lifetimes.holdsTailscaleFolder, "an engine being stopped still holds the folder")
        #expect(!lifetimes.mayStartLeaveChild)
        lifetimes.engineEnded(confirmed: true)
        #expect(!lifetimes.holdsTailscaleFolder)
        #expect(lifetimes.mayStartLeaveChild)
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

    // MARK: - Driven by the real supervisor

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
        #expect(feed.lifetimes.holdsTailscaleFolder)
        #expect(!feed.lifetimes.mayStartLeaveChild, "a leave child could start while the engine was being waited for")

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

        // Neither a later start nor a clear of the failure lets go of it.
        await supervisor.clearFailure()
        await supervisor.start(configuration: .fixture())
        feed.applyReportedStates()
        #expect(launcher.launchCount == 1)
        #expect(!feed.lifetimes.mayStartLeaveChild)
    }
}

// MARK: - The app's callers act only on the owner's answer

/// AppModelSource reads AppModel.swift as text, comments and string contents
/// removed, because the app has no test target and its launcher is not
/// injectable. It is a narrow architecture guard over the callers, not a
/// stand-in for the behaviour, which the owner's own checks above prove.
///
/// For each caller that can release the folder, a leave child, the keep-awake
/// hold or the bound host, the caller's own body must ask the owner (read one
/// of its four answers) in the condition of an `if`, `guard` or `while`, and
/// that condition must guard the caller's first release: the release sits
/// inside the guarded block, or the block leaves the caller and the release
/// comes after it. Calling the owner's recording methods is not approval.
enum AppModelSource {
    struct Caller {
        let declaration: String
        let name: String
        /// releases are texts in the caller's body that let something go.
        let releases: [String]
        /// optional callers need not exist, but if they do they must ask.
        let optional: Bool
    }

    static let callers: [Caller] = [
        Caller(declaration: #"func\s+restartEngineIfRunning\s*\("#, name: "restartEngineIfRunning", releases: ["startEngine()"], optional: false),
        Caller(declaration: #"func\s+shutDown\s*\("#, name: "shutDown", releases: ["boundHost = nil"], optional: false),
        Caller(declaration: #"func\s+stop\s*\(\s*\)"#, name: "stop", releases: ["stayAwake.relayStopped", "boundHost = nil"], optional: false),
        Caller(declaration: #"func\s+signOut\s*\("#, name: "signOut", releases: ["stayAwake.relayStopped", "boundHost = nil"], optional: false),
        Caller(declaration: #"func\s+handleEngineStateChange\s*\("#, name: "handleEngineStateChange", releases: ["boundHost = nil", "stayAwake.relayStopped"], optional: false),
        Caller(declaration: #"func\s+leaveBuiltInRoute\s*\("#, name: "leaveBuiltInRoute", releases: ["applyChoice()"], optional: false),
        Caller(declaration: #"func\s+chooseBuiltInTailscale\s*\("#, name: "chooseBuiltInTailscale", releases: ["settings.useBuiltInTailscale = true"], optional: false),
        Caller(declaration: #"func\s+runPendingLeaveChild\s*\("#, name: "runPendingLeaveChild", releases: ["leaveRunner.run("], optional: false),
        Caller(declaration: #"var\s+engineHoldsFolder\b"#, name: "engineHoldsFolder", releases: [], optional: true),
    ]

    static let answers = "holdsTailscaleFolder|builtInChoiceBlocked|mayStartLeaveChild|keepAwakeMayBeReleased"

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

    /// closing is the index of the brace that closes the one at open.
    static func closing(_ text: String, from open: String.Index) -> String.Index? {
        var depth = 0
        var index = open
        while index < text.endIndex {
            if text[index] == "{" { depth += 1 }
            if text[index] == "}" {
                depth -= 1
                if depth == 0 { return index }
            }
            index = text.index(after: index)
        }
        return nil
    }

    /// bodyRange is the text between the braces that follow the declaration.
    static func bodyRange(of caller: Caller, in source: String) -> Range<String.Index>? {
        guard let regex = try? NSRegularExpression(pattern: caller.declaration),
              let match = regex.firstMatch(in: source, range: NSRange(source.startIndex..., in: source)),
              let declared = Range(match.range, in: source),
              let open = source[declared.upperBound...].firstIndex(of: "{"),
              let close = closing(source, from: open)
        else { return nil }
        return source.index(after: open)..<close
    }

    static func mentions(of owner: String, in text: String) -> [NSTextCheckingResult] {
        let pattern = #"\b"# + NSRegularExpression.escapedPattern(for: owner) + #"\.("# + answers + #")\b"#
        guard let regex = try? NSRegularExpression(pattern: pattern) else { return [] }
        return regex.matches(in: text, range: NSRange(text.startIndex..., in: text))
    }

    static let exits = ["return", "break", "continue", "throw", "fatalError"]

    /// problem is why a caller's body does not act on the owner's answer, nil
    /// when it does.
    static func problem(body: String, caller: Caller, owner: String) -> String? {
        let asked = mentions(of: owner, in: body)
        if asked.isEmpty { return "never consults \(owner)" }
        let firstRelease = caller.releases.compactMap { body.range(of: $0)?.lowerBound }.min()

        // The answers a caller used in a condition, with the block they guard.
        let conditions = try! NSRegularExpression(pattern: #"\b(if|guard|while)\b([^{]*)\{"#)
        for match in conditions.matches(in: body, range: NSRange(body.startIndex..., in: body)) {
            guard let whole = Range(match.range, in: body),
                  let keywordRange = Range(match.range(at: 1), in: body),
                  let conditionRange = Range(match.range(at: 2), in: body),
                  !mentions(of: owner, in: String(body[conditionRange])).isEmpty,
                  let open = body[whole.lowerBound...].firstIndex(of: "{"),
                  let close = closing(body, from: open)
            else { continue }
            guard let firstRelease else { return nil }
            let block = body.index(after: open)..<close
            let leaves = exits.contains { body[block].contains($0) }
            if body[keywordRange] == "guard" {
                if leaves, firstRelease > close { return nil }
            } else {
                if block.contains(firstRelease) { return nil }
                if leaves, firstRelease > close { return nil }
                // The release in the else branch of the question.
                let after = body[body.index(after: close)...]
                if after.drop(while: { $0.isWhitespace }).hasPrefix("else"),
                   let elseOpen = after.firstIndex(of: "{"), let elseClose = closing(body, from: elseOpen),
                   (elseOpen...elseClose).contains(firstRelease) { return nil }
            }
        }
        if caller.releases.isEmpty {
            // An answer handed on as the caller's own answer is used; one read and dropped is not.
            let dropped = asked.allSatisfy { match in
                let line = body.lineContaining(Range(match.range, in: body)!.lowerBound)
                return line.hasPrefix("_ =") || line.hasPrefix("let ") || line.hasPrefix("var ")
            }
            return dropped ? "reads the owner's answer and does not use it" : nil
        }
        return "reads the owner's answer but it guards no release"
    }

    /// violations lists every caller that does not act on the owner's answer.
    static func violations(in rawSource: String) -> [String] {
        let source = stripped(rawSource)
        guard let owner = ownerName(in: source) else {
            return ["AppModel declares no ProcessLifetimes owner"]
        }
        var found: [String] = []
        for caller in callers {
            guard let range = bodyRange(of: caller, in: source) else {
                if !caller.optional { found.append("\(caller.name): not found") }
                continue
            }
            let body = String(source[range])
            if let reason = problem(body: body, caller: caller, owner: owner) {
                found.append("\(caller.name): \(reason)")
            }
            // A leave child's outcome must reach the owner as an unconfirmed one.
            if caller.name == "runPendingLeaveChild" {
                for needed in ["leaveChildStarted", "leaveChildEnded", "notConfirmedEnded"] where !body.contains(needed) {
                    found.append("runPendingLeaveChild: does not use \(needed)")
                }
            }
        }
        return found
    }

    // MARK: planted faults, applied to a scratch copy held in memory

    enum Fault: CaseIterable, CustomTestStringConvertible {
        /// consultRemoved: the owner is never asked.
        case consultRemoved
        /// answerIgnored: asked first, for its side effect, and the answer dropped.
        case answerIgnored
        /// askedAfterRelease: asked, in a condition, only after the release it should guard.
        case askedAfterRelease
        var testDescription: String { "\(self)" }
    }

    /// planting returns the stripped source with one fault planted in one
    /// caller's body, or nil when the fault cannot apply to that caller (a
    /// caller with no release has nothing to be asked after).
    static func planting(_ fault: Fault, in caller: Caller, of rawSource: String) -> String? {
        var source = stripped(rawSource)
        guard let owner = ownerName(in: source), let range = bodyRange(of: caller, in: source) else { return nil }
        if fault == .askedAfterRelease, caller.releases.isEmpty { return nil }
        var body = String(source[range])
        let asked = mentions(of: owner, in: body)
        guard let answer = asked.first.flatMap({ Range($0.range(at: 1), in: body) }).map({ String(body[$0]) }) else { return nil }
        for match in asked.reversed() {
            body.replaceSubrange(Range(match.range, in: body)!, with: "true")
        }
        switch fault {
        case .consultRemoved: break
        case .answerIgnored: body = "\n_ = \(owner).\(answer)\n" + body
        case .askedAfterRelease: body += "\nif \(owner).\(answer) {\n}\n"
        }
        source.replaceSubrange(range, with: body)
        return source
    }
}

private extension String {
    /// lineContaining is the trimmed line the index falls on.
    func lineContaining(_ index: String.Index) -> String {
        let start = self[..<index].lastIndex(of: "\n").map { self.index(after: $0) } ?? startIndex
        let end = self[index...].firstIndex(of: "\n") ?? endIndex
        return String(self[start..<end]).trimmingCharacters(in: .whitespaces)
    }
}

@Suite("AppModel acts on ProcessLifetimes")
struct AppModelConsultTests {
    /// A source shaped like AppModel in the places the check reads: each
    /// caller asks the owner and releases only on its answer.
    static let conformingSource = """
    @MainActor final class AppModel {
        private let lifetimes = ProcessLifetimes()
        /// stop releases keep-awake: lifetimes.keepAwakeMayBeReleased (a comment, not a consult)
        func stop() {
            lifetimes.engineStopRequested()
            guard lifetimes.keepAwakeMayBeReleased else { return }
            stayAwake.relayStopped()
        }
        func shutDown() async {
            lifetimes.engineStopRequested()
            if lifetimes.keepAwakeMayBeReleased { boundHost = nil }
        }
        func signOut() async -> Bool {
            guard lifetimes.keepAwakeMayBeReleased else { return false }
            stayAwake.relayStopped()
            return true
        }
        private func restartEngineIfRunning() async {
            lifetimes.engineStopRequested()
            guard !lifetimes.holdsTailscaleFolder else { return }
            await startEngine()
        }
        private func handleEngineStateChange(_ state: EngineSupervisor.RunState) {
            switch state {
            case .stopped:
                if lifetimes.keepAwakeMayBeReleased {
                    boundHost = nil
                }
            case .failed:
                if lifetimes.keepAwakeMayBeReleased {
                    stayAwake.relayStopped()
                }
            default: break
            }
        }
        private func leaveBuiltInRoute(for trigger: LeaveTrigger, applyChoice: () async -> Void) async {
            guard lifetimes.mayStartLeaveChild else { return }
            await applyChoice()
        }
        func chooseBuiltInTailscale() {
            guard !lifetimes.builtInChoiceBlocked else { return }
            settings.useBuiltInTailscale = true
        }
        private var engineHoldsFolder: Bool {
            lifetimes.holdsTailscaleFolder
        }
        private func runPendingLeaveChild() async {
            guard lifetimes.mayStartLeaveChild else { return }
            lifetimes.leaveChildStarted()
            let result = await leaveRunner.run()
            if case .notConfirmedEnded = result { lifetimes.leaveChildEnded(confirmed: false) } else { lifetimes.leaveChildEnded(confirmed: true) }
        }
    }
    """

    static let callerNames = AppModelSource.callers.map(\.name)

    @Test("the check passes a source in which every named caller releases only on the owner's answer")
    func conformingSourcePasses() {
        #expect(AppModelSource.violations(in: Self.conformingSource) == [])
    }

    @Test("a planted fault in one caller of a scratch copy turns the check red for that caller alone", arguments: AppModelConsultTests.callerNames, AppModelSource.Fault.allCases)
    func plantedFaultIsCaught(callerName: String, fault: AppModelSource.Fault) throws {
        let caller = try #require(AppModelSource.callers.first { $0.name == callerName })
        guard let planted = AppModelSource.planting(fault, in: caller, of: Self.conformingSource) else {
            #expect(caller.releases.isEmpty && fault == .askedAfterRelease, "\(callerName) cannot take the fault \(fault)")
            return
        }
        let violations = AppModelSource.violations(in: planted)
        #expect(violations.count == 1, Comment(rawValue: "\(callerName) \(fault): \(violations)"))
        #expect(violations.first?.hasPrefix("\(callerName):") == true, Comment(rawValue: "\(callerName) \(fault): \(violations)"))
    }

    @Test("a stopped callback that clears the bound address without asking the owner is caught, even beside a guarded failed branch")
    func unguardedStoppedReleaseIsCaught() {
        let source = Self.conformingSource.replacingOccurrences(
            of: """
            case .stopped:
                        if lifetimes.keepAwakeMayBeReleased {
                            boundHost = nil
                        }
            """,
            with: """
            case .stopped:
                        boundHost = nil
            """
        )
        #expect(source != Self.conformingSource)
        let violations = AppModelSource.violations(in: source)
        #expect(violations.count == 1 && violations.first?.hasPrefix("handleEngineStateChange:") == true, Comment(rawValue: "\(violations)"))
    }

    @Test("the check goes red when AppModel declares no owner at all")
    func noOwnerIsCaught() {
        let source = Self.conformingSource.replacingOccurrences(of: "private let lifetimes = ProcessLifetimes()", with: "")
        #expect(!AppModelSource.violations(in: source).isEmpty)
    }

    private static func appModelText() throws -> String {
        var url = URL(fileURLWithPath: #filePath)
        for _ in 0..<5 { url.deleteLastPathComponent() }
        url.appendPathComponent("App/Sources/AppModel.swift")
        return try String(contentsOf: url, encoding: .utf8)
    }

    @Test("every named caller in the app's own AppModel releases only on the owner's answer")
    func appModelActsOnTheOwner() throws {
        #expect(AppModelSource.violations(in: try Self.appModelText()) == [])
    }

    @Test("each planted fault in a scratch copy of the app's own AppModel turns the check red for that caller", arguments: AppModelConsultTests.callerNames, AppModelSource.Fault.allCases)
    func plantedFaultInTheAppsOwnCopyIsCaught(callerName: String, fault: AppModelSource.Fault) throws {
        let text = try Self.appModelText()
        let caller = try #require(AppModelSource.callers.first { $0.name == callerName })
        guard let planted = AppModelSource.planting(fault, in: caller, of: text) else {
            // Optional or release-less callers, or no caller body that asks yet.
            #expect(caller.optional || (caller.releases.isEmpty && fault == .askedAfterRelease), "\(callerName) cannot take the fault \(fault) in the app's own source")
            return
        }
        let violations = AppModelSource.violations(in: planted)
        #expect(violations.contains { $0.hasPrefix("\(callerName):") }, Comment(rawValue: "\(callerName) \(fault): \(violations)"))
    }
}
