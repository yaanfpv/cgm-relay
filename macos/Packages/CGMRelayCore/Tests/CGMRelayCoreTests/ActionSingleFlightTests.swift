import Testing
import Foundation

// The app has no test target, so the order in which an action takes its
// guard flag is checked on the source: a second quick press must find the
// flag already set. Each member below is an action with a flag that its
// caller checks. The flag has to be set on the main actor before the first
// Task is created and before the first await is reached, by the function
// the person's press calls, and it is cleared by the run that set it, never
// by a defer in some other function that another run may also be in.

/// Member is one action with a guard flag.
struct SingleFlightMember: Sendable, CustomTestStringConvertible {
    /// name is the function the button's press calls.
    let name: String
    /// file is the source file that declares it.
    let file: String
    /// flag is the guard flag the callers check.
    let flag: String
    /// signature, when set, must appear between the function's name and its
    /// opening brace (tells a form's submit(model:) from a view's submit()).
    let signature: String?
    /// callPattern finds each place the press reaches the function.
    let callPattern: String
    /// owners are the functions whose run owns the flag: only these may
    /// clear it in a defer.
    let owners: [String]
    /// pathPatterns are further call patterns that lead to the function
    /// (chooseWay reaches the This Mac only leave); they too must not sit in
    /// a Task.
    var pathPatterns: [String] = []

    var testDescription: String { name }

    static let all: [SingleFlightMember] = [
        SingleFlightMember(
            name: "chooseOwnTailscale", file: "AppModel.swift", flag: "isLeavingRoute", signature: nil,
            callPattern: #"\bchooseOwnTailscale\s*\("#,
            owners: ["chooseOwnTailscale", "chooseThisMacOnlyLeavingBuiltIn"]
        ),
        SingleFlightMember(
            name: "chooseThisMacOnlyLeavingBuiltIn", file: "AppModel.swift", flag: "isLeavingRoute", signature: nil,
            callPattern: #"\bchooseThisMacOnlyLeavingBuiltIn\s*\("#,
            owners: ["chooseOwnTailscale", "chooseThisMacOnlyLeavingBuiltIn"],
            pathPatterns: [#"\bchooseWay\s*\("#]
        ),
        SingleFlightMember(
            name: "submit", file: "AccountPaneView.swift", flag: "isChecking", signature: "model:",
            callPattern: #"\.submit\s*\(\s*model:"#,
            owners: ["submit"]
        ),
        SingleFlightMember(
            name: "enableTailscaleHTTPS", file: "AppModel.swift", flag: "isChangingTailscale", signature: nil,
            callPattern: #"\benableTailscaleHTTPS\s*\("#,
            owners: ["enableTailscaleHTTPS", "disableTailscaleHTTPS"]
        ),
        SingleFlightMember(
            name: "disableTailscaleHTTPS", file: "AppModel.swift", flag: "isChangingTailscale", signature: nil,
            callPattern: #"\bdisableTailscaleHTTPS\s*\("#,
            owners: ["enableTailscaleHTTPS", "disableTailscaleHTTPS"]
        ),
        SingleFlightMember(
            name: "turnOnStayAwake", file: "AppModel.swift", flag: "isChangingStayAwake", signature: nil,
            callPattern: #"\bturnOnStayAwake\s*\("#,
            owners: ["turnOnStayAwake"]
        ),
    ]
}

enum SingleFlightSource {
    typealias Parsed = AppModelSource.Parsed

    /// problems lists what keeps a member from being single-flight, over a
    /// set of source files by name.
    static func problems(_ member: SingleFlightMember, in files: [String: String]) -> [String] {
        guard let raw = files[member.file] else { return ["\(member.name): \(member.file) is missing"] }
        let parsed = Parsed(AppModelSource.stripped(raw))
        let functions = parsed.functions()
        let entries = functions.filter { function in
            guard function.name == member.name else { return false }
            guard let signature = member.signature else { return true }
            return parsed.ns.substring(with: NSRange(location: function.declaration, length: function.open - function.declaration)).contains(signature)
        }
        guard let entry = entries.first else { return ["\(member.name): not declared in \(member.file)"] }
        var found: [String] = []

        // Set on the main actor: the owning type is @MainActor and the
        // function is not nonisolated.
        if !isMainActor(entry, in: parsed) {
            found.append("\(member.name): the flag \(member.flag) is not set on the main actor")
        }
        let declaration = parsed.ns.substring(with: NSRange(location: entry.declaration, length: entry.open - entry.declaration))
        if declaration.contains("nonisolated") {
            found.append("\(member.name): is nonisolated, so it does not run on the main actor")
        }

        // Every set of the flag in the file comes before the first Task and
        // the first await of the function it sits in.
        let setPattern = #"\b"# + member.flag + #"\s*=\s*true\b"#
        var entrySets = 0
        for match in regex(setPattern).matches(in: parsed.text, range: NSRange(location: 0, length: parsed.ns.length)) {
            guard let function = parsed.innermost(functions, at: match.range.location) else { continue }
            if function.name == member.name, function.open == entry.open { entrySets += 1 }
            if let hop = firstHop(in: function, parsed: parsed), hop.position < match.range.location {
                found.append("\(function.name): sets \(member.flag) after \(hop.kind), so a second press gets in first")
            }
        }
        if entrySets == 0 {
            found.append("\(member.name): never sets \(member.flag) before its Task or await")
        }

        // The run that set it clears it.
        let clearRange = NSRange(location: entry.open, length: entry.close - entry.open)
        if regex(#"\b"# + member.flag + #"\s*=\s*false\b"#).firstMatch(in: parsed.text, range: clearRange) == nil {
            found.append("\(member.name): never clears \(member.flag) when its run ends")
        }

        // No defer in another function clears it.
        for match in regex(#"\bdefer\s*\{"#).matches(in: parsed.text, range: NSRange(location: 0, length: parsed.ns.length)) {
            let open = match.range.location + match.range.length - 1
            guard let close = parsed.closeOf[open] else { continue }
            let body = parsed.ns.substring(with: NSRange(location: open, length: close - open))
            guard regex(#"\b"# + member.flag + #"\s*=\s*false\b"#).firstMatch(in: body, range: NSRange(location: 0, length: (body as NSString).length)) != nil else { continue }
            let owner = parsed.innermost(functions, at: match.range.location)?.name ?? "(none)"
            if !member.owners.contains(owner) {
                found.append("\(owner): clears \(member.flag) in a defer, though another run may be in flight")
            }
        }

        // No press reaches it through a Task: the Task would start after
        // the press returned, before the flag is set.
        for pattern in [member.callPattern] + member.pathPatterns {
            for (name, text) in files.sorted(by: { $0.key < $1.key }) {
                let other = Parsed(AppModelSource.stripped(text))
                for match in regex(pattern).matches(in: other.text, range: NSRange(location: 0, length: other.ns.length)) {
                    let before = other.ns.substring(to: match.range.location).trimmingCharacters(in: .whitespaces)
                    if before.hasSuffix("func") { continue }
                    if insideTask(match.range.location, in: other) {
                        found.append("\(member.name): called from inside a Task in \(name), so the flag is set only after the Task starts")
                    }
                }
            }
        }
        return found
    }

    struct Hop {
        let kind: String
        let position: Int
    }

    /// firstHop is the first Task or await in the function's own body.
    static func firstHop(in function: Parsed.Function, parsed: Parsed) -> Hop? {
        let range = NSRange(location: function.open + 1, length: function.close - function.open - 1)
        var best: Hop?
        let task = regex(#"\bTask\s*(?:\.detached\s*)?(?:\([^()]*\)\s*)?\{"#).firstMatch(in: parsed.text, range: range)
        if let task { best = Hop(kind: "a Task is created", position: task.range.location) }
        if let wait = regex(#"\bawait\b"#).firstMatch(in: parsed.text, range: range),
           best == nil || wait.range.location < best!.position {
            best = Hop(kind: "an await", position: wait.range.location)
        }
        return best
    }

    static func insideTask(_ position: Int, in parsed: Parsed) -> Bool {
        var open = parsed.parent[position]
        while open >= 0 {
            let start = max(0, open - 80)
            let before = parsed.ns.substring(with: NSRange(location: start, length: open - start))
            if regex(#"\bTask\s*(?:\.detached\s*)?(?:\([^()]*\)\s*)?$"#).firstMatch(in: before, range: NSRange(location: 0, length: (before as NSString).length)) != nil {
                return true
            }
            open = parsed.parent[open]
        }
        return false
    }

    static func isMainActor(_ function: Parsed.Function, in parsed: Parsed) -> Bool {
        var open = parsed.parent[function.declaration]
        while open >= 0 {
            let before = parsed.ns.substring(to: open)
            let kinds = regex(#"(?:final\s+)?\b(?:class|struct|actor)\s+\w+[^{};]*$"#)
            if let match = kinds.firstMatch(in: before, range: NSRange(location: 0, length: (before as NSString).length)) {
                let prefix = (before as NSString).substring(to: match.range.location)
                let tail = String(prefix.suffix(200))
                guard let mark = tail.range(of: "@MainActor", options: .backwards) else { return false }
                let after = tail[mark.upperBound...]
                return !after.contains("}") && !after.contains(";")
            }
            open = parsed.parent[open]
        }
        return false
    }

    /// disabledWhileLeaving is true when the "Use My Tailscale" row (the
    /// ChoiceRow whose action is chooseOwnTailscale) carries a disabled
    /// argument that reads isLeavingRoute.
    static func useMyTailscaleDisabledWhileLeaving(in raw: String) -> Bool {
        let parsed = Parsed(AppModelSource.stripped(raw))
        let text = parsed.text
        for match in regex(#"\bChoiceRow\s*\("#).matches(in: text, range: NSRange(location: 0, length: parsed.ns.length)) {
            var depth = 0
            var index = match.range.location + match.range.length - 1
            let units = parsed.units
            let start = index
            while index < units.count {
                if units[index] == 40 { depth += 1 }
                if units[index] == 41 { depth -= 1; if depth == 0 { break } }
                index += 1
            }
            guard index < units.count else { continue }
            let arguments = parsed.ns.substring(with: NSRange(location: start, length: index - start))
            var trailing = index + 1
            while trailing < units.count, units[trailing] == 32 || units[trailing] == 10 { trailing += 1 }
            var closure = ""
            if trailing < units.count, units[trailing] == 123, let close = parsed.closeOf[trailing] {
                closure = parsed.ns.substring(with: NSRange(location: trailing, length: close - trailing))
            }
            guard closure.contains("chooseOwnTailscale") || arguments.contains("chooseOwnTailscale") else { continue }
            let reads = regex(#"\bdisabled:\s*[^,)]*\bisLeavingRoute\b"#)
            return reads.firstMatch(in: arguments, range: NSRange(location: 0, length: (arguments as NSString).length)) != nil
        }
        return false
    }

    static func regex(_ pattern: String) -> NSRegularExpression {
        // swiftlint:disable:next force_try
        try! NSRegularExpression(pattern: pattern)
    }

    /// sources reads every Swift file the app is built from.
    static func sources() throws -> [String: String] {
        var url = URL(fileURLWithPath: #filePath)
        for _ in 0..<5 { url.deleteLastPathComponent() }
        url.appendPathComponent("App/Sources")
        var files: [String: String] = [:]
        for name in try FileManager.default.contentsOfDirectory(atPath: url.path) where name.hasSuffix(".swift") {
            files[name] = try String(contentsOf: url.appendingPathComponent(name), encoding: .utf8)
        }
        return files
    }
}

// MARK: - A source that conforms, and faults planted in a copy of it

enum SingleFlightFixture {
    static let appModel = """
    @MainActor
    final class AppModel: ObservableObject {
        private var isLeavingRoute = false
        @Published private(set) var isChangingTailscale = false
        @Published private(set) var isChangingStayAwake = false
        var isLaptop = true

        func chooseOwnTailscale() {
            guard settings.useBuiltInTailscale, !isLeavingRoute else { return }
            isLeavingRoute = true
            Task {
                defer { isLeavingRoute = false }
                await leaveBuiltInRoute(for: .chooseOwnTailscale) {
                    self.persistSettings()
                }
            }
        }

        private func chooseThisMacOnlyLeavingBuiltIn() {
            guard settings.useBuiltInTailscale, !isLeavingRoute else { return }
            isLeavingRoute = true
            Task {
                defer { isLeavingRoute = false }
                await leaveBuiltInRoute(for: .chooseThisMacOnly) {
                    self.persistSettings()
                }
            }
        }

        func chooseWay(_ way: ReachWay) {
            if way == .thisMacOnly, settings.useBuiltInTailscale {
                chooseThisMacOnlyLeavingBuiltIn()
                return
            }
        }

        private func leaveBuiltInRoute(for trigger: LeaveTrigger, applyChoice: () async -> Void) async {
            guard !lifetimes.builtInChoiceBlocked else { return }
            builtInSession.cancel()
            let outcome = await routeLeaver.leave()
            await applyChoice()
        }

        func enableTailscaleHTTPS(shownPort: Int) {
            guard !isChangingTailscale else { return }
            isChangingTailscale = true
            tailscaleFailure = nil
            Task {
                defer { isChangingTailscale = false }
                let result = await TailscaleChange.turnOn(shownPort: shownPort)
            }
        }

        func disableTailscaleHTTPS(shownPort: Int) {
            guard !isChangingTailscale else { return }
            isChangingTailscale = true
            tailscaleFailure = nil
            Task {
                defer { isChangingTailscale = false }
                let result = await TailscaleChange.turnOff(shownPort: shownPort)
            }
        }

        func turnOnStayAwake() {
            guard !isChangingStayAwake else { return }
            stayAwakeNotice = nil
            if isLaptop {
                isChangingStayAwake = true
                Task {
                    defer { isChangingStayAwake = false }
                    await sleepRules.install()
                    saveStayAwake(.on)
                }
                return
            }
            saveStayAwake(.on)
        }
    }
    """

    static let accountPane = """
    @MainActor
    final class SignInForm: ObservableObject {
        @Published private(set) var isChecking = false

        func submit(model: AppModel) {
            guard canSubmit else { return }
            isChecking = true
            Task {
                defer { isChecking = false }
                let outcome = await model.signIn(email: email, password: password)
            }
        }
    }

    struct AccountPaneView: View {
        var body: some View {
            AccessibleButton { form.submit(model: model) }
        }

        private func submit() {
            form.submit(model: model)
        }
    }
    """

    static let setup = """
    struct SetupView: View {
        var body: some View {
            AccessibleButton { signInForm.submit(model: model) }
            Button { model.turnOnStayAwake() }
        }
    }
    """

    static let general = """
    struct GeneralPaneView: View {
        var stayAwakeBinding: Binding<Bool> {
            Binding(get: { true }, set: { on in
                if on {
                    model.turnOnStayAwake()
                }
            })
        }
    }
    """

    static let tailscaleControl = """
    struct TailscaleHTTPSControl: View {
        var body: some View {
            row { model.enableTailscaleHTTPS(shownPort: port) }
            Button { model.disableTailscaleHTTPS(shownPort: port) }
        }
    }
    """

    static let advanced = """
    struct AdvancedPaneView: View {
        var body: some View {
            ChoiceRow(title: x) { model.chooseWay(.thisMacOnly) }
        }
    }
    """

    static let builtInRoute = """
    struct TailscaleChoiceView: View {
        var body: some View {
            ChoiceRow(
                title: "Use My Tailscale",
                description: "Reach this Mac over your own Tailscale.",
                selected: !model.settings.useBuiltInTailscale,
                disabled: model.isLeavingRoute
            ) { model.chooseOwnTailscale() }
            ChoiceRow(
                title: "Use Built-In Tailscale",
                description: "Give this Mac its own address.",
                selected: model.settings.useBuiltInTailscale,
                disabled: model.builtInChoiceBlockedReason != nil
            ) { model.chooseBuiltInTailscale() }
        }
    }
    """

    static let files: [String: String] = [
        "AppModel.swift": appModel,
        "AccountPaneView.swift": accountPane,
        "SetupView.swift": setup,
        "GeneralPaneView.swift": general,
        "TailscaleHTTPSControl.swift": tailscaleControl,
        "AdvancedPaneView.swift": advanced,
        "BuiltInRouteView.swift": builtInRoute,
    ]
}

/// FlagPlant is a fault put into an in-memory copy of the fixture.
enum FlagPlant: CaseIterable, Sendable, CustomTestStringConvertible {
    case setInsideTask
    case setAfterAwait
    case neverSet
    case neverCleared
    case deferInAnotherFunction
    case callerInTask
    case notMainActor

    var testDescription: String {
        switch self {
        case .setInsideTask: "the flag set inside the Task"
        case .setAfterAwait: "the flag set after an await"
        case .neverSet: "the flag never set before the hop"
        case .neverCleared: "the flag never cleared"
        case .deferInAnotherFunction: "a defer in another function clears the flag"
        case .callerInTask: "the press wrapped in a Task"
        case .notMainActor: "the owning type off the main actor"
        }
    }

    func apply(to member: SingleFlightMember) -> [String: String]? {
        var files = SingleFlightFixture.files
        let flag = member.flag
        switch self {
        case .setInsideTask:
            return edit(&files, member) { body in
                let setLine = "\(flag) = true\n"
                guard let set = body.range(of: setLine), let task = body.range(of: "Task {\n") else { return nil }
                var out = body
                out.replaceSubrange(set, with: "")
                guard let task = out.range(of: "Task {\n") ?? Optional(task) else { return nil }
                out.insert(contentsOf: "\(flag) = true\n", at: task.upperBound)
                return out
            }
        case .setAfterAwait:
            return edit(&files, member) { body in
                guard body.contains("\(flag) = true") else { return nil }
                return body.replacingOccurrences(of: "\(flag) = true", with: "await Task.yield()\n\(flag) = true")
            }
        case .neverSet:
            return edit(&files, member) { body in
                guard body.contains("\(flag) = true\n") else { return nil }
                return body.replacingOccurrences(of: "\(flag) = true\n", with: "")
            }
        case .neverCleared:
            return edit(&files, member) { body in
                guard body.contains("\(flag) = false") else { return nil }
                return body.replacingOccurrences(of: "\(flag) = false", with: "_ = 0")
            }
        case .deferInAnotherFunction:
            let target = flag == "isLeavingRoute" ? "leaveBuiltInRoute" : nil
            if let target {
                return edit(&files, SingleFlightMember(name: target, file: member.file, flag: flag, signature: nil, callPattern: "", owners: [])) { body in
                    "\ndefer { \(flag) = false }" + body
                }
            }
            guard var text = files[member.file], let tail = text.range(of: "}", options: .backwards) else { return nil }
            text.replaceSubrange(tail, with: "    private func finishElsewhere() { defer { \(flag) = false } }\n}")
            files[member.file] = text
            return files
        case .callerInTask:
            var changed = false
            for (name, text) in files {
                let pattern = #"(?<!func )((?:(?:model|form|signInForm)\.)?\#(member.name)\([^)\n]*\))"#
                let replaced = text.replacingOccurrences(of: pattern, with: "Task { await $1 }", options: .regularExpression)
                if replaced != text { files[name] = replaced; changed = true }
            }
            return changed ? files : nil
        case .notMainActor:
            guard let text = files[member.file], text.contains("@MainActor") else { return nil }
            files[member.file] = text.replacingOccurrences(of: "@MainActor", with: "")
            return files
        }
    }

    private func edit(_ files: inout [String: String], _ member: SingleFlightMember, _ transform: (String) -> String?) -> [String: String]? {
        guard let text = files[member.file] else { return nil }
        let parsed = AppModelSource.Parsed(text)
        guard let function = parsed.functions().first(where: { fn in
            fn.name == member.name
                && (member.signature.map { parsed.ns.substring(with: NSRange(location: fn.declaration, length: fn.open - fn.declaration)).contains($0) } ?? true)
        }) else { return nil }
        let bodyRange = NSRange(location: function.open + 1, length: function.close - function.open - 1)
        guard let changed = transform(parsed.ns.substring(with: bodyRange)) else { return nil }
        files[member.file] = parsed.ns.replacingCharacters(in: bodyRange, with: changed)
        return files
    }
}

// MARK: - The checks

@Suite("A second quick press never starts a second run")
struct ActionSingleFlightTests {
    @Test("the source the check is judged against conforms for every member")
    func fixtureConforms() {
        for member in SingleFlightMember.all {
            #expect(SingleFlightSource.problems(member, in: SingleFlightFixture.files) == [], Comment(rawValue: member.name))
        }
        #expect(SingleFlightSource.useMyTailscaleDisabledWhileLeaving(in: SingleFlightFixture.builtInRoute))
    }

    @Test("the app's own source sets each action's flag, on the main actor, before its first Task and first await, and clears it only in its own run", arguments: SingleFlightMember.all)
    func appSourceIsSingleFlight(member: SingleFlightMember) throws {
        #expect(SingleFlightSource.problems(member, in: try SingleFlightSource.sources()) == [])
    }

    @Test("no defer outside the leave callers clears isLeavingRoute")
    func noLeaveDeferClearsTheFlag() throws {
        let member = SingleFlightMember.all[0]
        let leaks = SingleFlightSource.problems(member, in: try SingleFlightSource.sources()).filter { $0.contains("clears \(member.flag) in a defer") }
        #expect(leaks == [])
    }

    @Test("Use My Tailscale is disabled while a leave runs")
    func useMyTailscaleDisabledDuringLeave() throws {
        let text = try #require(try SingleFlightSource.sources()["BuiltInRouteView.swift"])
        #expect(SingleFlightSource.useMyTailscaleDisabledWhileLeaving(in: text))
    }

    @Test("each planted fault turns the check red for the member it is planted in", arguments: SingleFlightMember.all, FlagPlant.allCases)
    func plantIsCaught(member: SingleFlightMember, plant: FlagPlant) throws {
        let planted = try #require(plant.apply(to: member), "\(plant.testDescription) does not apply to \(member.name)")
        let found = SingleFlightSource.problems(member, in: planted)
        #expect(!found.isEmpty, Comment(rawValue: "\(member.name) with \(plant.testDescription) stayed green"))
    }

    @Test("a planted defer in leaveBuiltInRoute is named, not only the missing caller flag")
    func leaveDeferIsNamed() throws {
        let member = SingleFlightMember.all[0]
        let planted = try #require(FlagPlant.deferInAnotherFunction.apply(to: member))
        let found = SingleFlightSource.problems(member, in: planted)
        #expect(found.contains { $0.hasPrefix("leaveBuiltInRoute: clears isLeavingRoute in a defer") }, Comment(rawValue: "\(found)"))
    }

    @Test("the disabled argument removed from the Use My Tailscale row turns the check red")
    func disabledArgumentRemovedIsCaught() {
        let planted = SingleFlightFixture.builtInRoute.replacingOccurrences(of: #",\s*disabled: model\.isLeavingRoute"#, with: "", options: .regularExpression)
        #expect(planted != SingleFlightFixture.builtInRoute)
        #expect(!SingleFlightSource.useMyTailscaleDisabledWhileLeaving(in: planted))
        // The selected line must lose its trailing comma too, or the plant
        // would be a syntax error rather than a missing argument.
        let wrongFlag = SingleFlightFixture.builtInRoute.replacingOccurrences(of: "disabled: model.isLeavingRoute", with: "disabled: model.builtInChoiceBlockedReason != nil")
        #expect(!SingleFlightSource.useMyTailscaleDisabledWhileLeaving(in: wrongFlag))
    }
}
