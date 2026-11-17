import Darwin
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

/// A listener held open on a real socket, with no address reuse, so any bind
/// of the same address and port conflicts for as long as it is alive.
private final class HeldListener {
    let port: Int
    private let descriptor: Int32

    init?(host: String, port requested: Int = 0, dualStack: Bool = false) {
        let isIPv6 = host.contains(":")
        let descriptor = socket(isIPv6 ? AF_INET6 : AF_INET, SOCK_STREAM, 0)
        guard descriptor >= 0 else { return nil }
        var bound: Int32
        var address4 = sockaddr_in()
        var address6 = sockaddr_in6()
        if isIPv6 {
            address6.sin6_len = UInt8(MemoryLayout<sockaddr_in6>.size)
            address6.sin6_family = sa_family_t(AF_INET6)
            address6.sin6_port = in_port_t(requested).bigEndian
            inet_pton(AF_INET6, host, &address6.sin6_addr)
            var only: Int32 = dualStack ? 0 : 1
            _ = setsockopt(descriptor, IPPROTO_IPV6, IPV6_V6ONLY, &only, socklen_t(MemoryLayout<Int32>.size))
            bound = withUnsafePointer(to: &address6) {
                $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { Darwin.bind(descriptor, $0, socklen_t(MemoryLayout<sockaddr_in6>.size)) }
            }
        } else {
            address4.sin_len = UInt8(MemoryLayout<sockaddr_in>.size)
            address4.sin_family = sa_family_t(AF_INET)
            address4.sin_port = in_port_t(requested).bigEndian
            inet_pton(AF_INET, host, &address4.sin_addr)
            bound = withUnsafePointer(to: &address4) {
                $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { Darwin.bind(descriptor, $0, socklen_t(MemoryLayout<sockaddr_in>.size)) }
            }
        }
        guard bound == 0, listen(descriptor, 1) == 0 else {
            close(descriptor)
            return nil
        }
        var actual = sockaddr_storage()
        var length = socklen_t(MemoryLayout<sockaddr_storage>.size)
        let named = withUnsafeMutablePointer(to: &actual) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { getsockname(descriptor, $0, &length) }
        }
        guard named == 0 else {
            close(descriptor)
            return nil
        }
        self.descriptor = descriptor
        self.port = isIPv6
            ? Int(UInt16(bigEndian: withUnsafePointer(to: &actual) { $0.withMemoryRebound(to: sockaddr_in6.self, capacity: 1) { $0.pointee.sin6_port } }))
            : Int(UInt16(bigEndian: withUnsafePointer(to: &actual) { $0.withMemoryRebound(to: sockaddr_in.self, capacity: 1) { $0.pointee.sin_port } }))
    }

    deinit { close(descriptor) }

    /// run holds count consecutive ports on host, starting at an OS-assigned
    /// one, retrying elsewhere when a neighbour is already taken.
    static func run(host: String, count: Int) -> [HeldListener]? {
        for _ in 0..<200 {
            guard let first = HeldListener(host: host) else { return nil }
            var held = [first]
            for offset in 1..<count {
                guard first.port + offset <= 65535, let next = HeldListener(host: host, port: first.port + offset) else { break }
                held.append(next)
            }
            if held.count == count { return held }
        }
        return nil
    }
}

/// A port whose only state is a closed connection waiting out its time: a
/// reusing listener accepts one client and closes the server side first.
/// Nothing listens on the port afterwards.
private func portInTimeWait() -> Int? {
    let listener = socket(AF_INET, SOCK_STREAM, 0)
    guard listener >= 0 else { return nil }
    defer { close(listener) }
    var on: Int32 = 1
    _ = setsockopt(listener, SOL_SOCKET, SO_REUSEADDR, &on, socklen_t(MemoryLayout<Int32>.size))
    var address = sockaddr_in()
    address.sin_len = UInt8(MemoryLayout<sockaddr_in>.size)
    address.sin_family = sa_family_t(AF_INET)
    inet_pton(AF_INET, "127.0.0.1", &address.sin_addr)
    let bound = withUnsafeMutablePointer(to: &address) {
        $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { Darwin.bind(listener, $0, socklen_t(MemoryLayout<sockaddr_in>.size)) }
    }
    var length = socklen_t(MemoryLayout<sockaddr_in>.size)
    let named = withUnsafeMutablePointer(to: &address) {
        $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { getsockname(listener, $0, &length) }
    }
    guard bound == 0, named == 0, listen(listener, 1) == 0 else { return nil }
    let client = socket(AF_INET, SOCK_STREAM, 0)
    guard client >= 0 else { return nil }
    defer { close(client) }
    let connected = withUnsafeMutablePointer(to: &address) {
        $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { Darwin.connect(client, $0, socklen_t(MemoryLayout<sockaddr_in>.size)) }
    }
    guard connected == 0 else { return nil }
    let accepted = accept(listener, nil, nil)
    guard accepted >= 0 else { return nil }
    close(accepted)
    return Int(UInt16(bigEndian: address.sin_port))
}

/// ClosingSetup is the result of making a port whose only use is a closing
/// connection: ready with the port, or the step that could not be proved.
private enum ClosingSetup {
    case ready(port: Int)
    case unproven(String)
}

/// closingConnectionPort makes its own connection on a port it chose and ends
/// it from the server side first, so the closing state (TIME_WAIT) is on that
/// port, then releases its listener. Every step must report success: a call
/// that fails, a client that does not see the server's close as end of file,
/// or a reset instead of an orderly close leaves the setup unproven.
private func closingConnectionPort() -> ClosingSetup {
    let listener = socket(AF_INET, SOCK_STREAM, 0)
    guard listener >= 0 else { return .unproven("no listener socket (errno \(errno))") }
    var listenerOpen = true
    defer { if listenerOpen { close(listener) } }
    var address = sockaddr_in()
    address.sin_len = UInt8(MemoryLayout<sockaddr_in>.size)
    address.sin_family = sa_family_t(AF_INET)
    inet_pton(AF_INET, "127.0.0.1", &address.sin_addr)
    let bound = withUnsafeMutablePointer(to: &address) {
        $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { Darwin.bind(listener, $0, socklen_t(MemoryLayout<sockaddr_in>.size)) }
    }
    guard bound == 0 else { return .unproven("bind failed (errno \(errno))") }
    var length = socklen_t(MemoryLayout<sockaddr_in>.size)
    let named = withUnsafeMutablePointer(to: &address) {
        $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { getsockname(listener, $0, &length) }
    }
    guard named == 0, listen(listener, 1) == 0 else { return .unproven("listener setup failed (errno \(errno))") }
    let port = Int(UInt16(bigEndian: address.sin_port))

    let client = socket(AF_INET, SOCK_STREAM, 0)
    guard client >= 0 else { return .unproven("no client socket (errno \(errno))") }
    var clientOpen = true
    defer { if clientOpen { close(client) } }
    let connected = withUnsafeMutablePointer(to: &address) {
        $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { Darwin.connect(client, $0, socklen_t(MemoryLayout<sockaddr_in>.size)) }
    }
    guard connected == 0 else { return .unproven("connect to port \(port) failed (errno \(errno))") }
    let accepted = accept(listener, nil, nil)
    guard accepted >= 0 else { return .unproven("accept on port \(port) failed (errno \(errno))") }
    // The server side closes first: its end is the one that waits out the time.
    guard close(accepted) == 0 else { return .unproven("closing the server side failed (errno \(errno))") }
    var byte: UInt8 = 0
    var count: Int
    repeat { count = read(client, &byte, 1) } while count < 0 && errno == EINTR
    guard count == 0 else { return .unproven("the client did not see an orderly close from the server side (read returned \(count), errno \(errno))") }
    clientOpen = false
    guard close(client) == 0 else { return .unproven("closing the client side failed (errno \(errno))") }
    listenerOpen = false
    guard close(listener) == 0 else { return .unproven("releasing the listener failed (errno \(errno))") }
    return .ready(port: port)
}

private struct TableBinder: PortBinding {
    var taken: [String: Set<Int>] = [:]
    var allTaken = false
    func canBind(host: String, port: Int) -> Bool {
        !allTaken && !(taken[host]?.contains(port) ?? false)
    }
}

/// Answers as the real binder does and keeps every answer it was given by
/// the system, so a test can judge a verdict by what the product's own call
/// saw instead of asking the system again later. A distortion hands the
/// product the opposite of what the record shows, to plant a wrong decision.
private final class RecordingBinder: PortBinding, @unchecked Sendable {
    enum Distortion { case none, refuseFree, acceptInUse }

    let inner: any PortBinding
    let distortion: Distortion
    private(set) var answers: [(host: String, port: Int, free: Bool)] = []
    init(inner: any PortBinding, distortion: Distortion = .none) {
        self.inner = inner
        self.distortion = distortion
    }
    func canBind(host: String, port: Int) -> Bool {
        let free = inner.canBind(host: host, port: port)
        answers.append((host, port, free))
        switch distortion {
        case .none: return free
        case .refuseFree: return false
        case .acceptInUse: return true
        }
    }
}

private typealias Answer = (host: String, port: Int, free: Bool)

/// What a pass found: a verdict the record backs, a wrong one, or a pass in
/// which nothing could be proved because every candidate got an in-use answer.
private enum PassOutcome: Equatable {
    case correct
    case inconclusive(String)
    case wrong(String)
}

/// Ends a pass the way the suite reports it: a wrong verdict fails, an
/// inconclusive pass is cancelled with its reason, a correct one just ends.
private func conclude(_ outcome: PassOutcome) throws {
    switch outcome {
    case .correct: return
    case .wrong(let message): Issue.record("\(message)")
    case .inconclusive(let reason): try Test.cancel("\(reason)")
    }
}

private func describe(port: Int, _ answers: [Answer]) -> String {
    let mine = answers.filter { $0.port == port }
    guard !mine.isEmpty else { return "port \(port): no answer" }
    return "port \(port): " + mine.map { "\($0.host) \($0.free ? "free" : "in use")" }.joined(separator: ", ")
}

/// Judges one typed-port verdict only by the answers its own call received.
/// A refusal is wrong only when every recorded answer said free; an
/// acceptance is wrong when any answer said in use or a host was not asked.
private func judgeTyped(port: Int, bindHost: String, localIPv4s: [String] = [], refusal: String?, answers: [Answer]) -> (wrong: String?, acceptedFree: Bool, note: String) {
    let mine = answers.filter { $0.port == port }
    let note = describe(port: port, mine)
    let anyInUse = mine.contains { !$0.free }
    if let refusal {
        if !anyInUse { return ("port \(port) was refused (\(refusal)) though every recorded answer said free; \(note)", false, note) }
        if refusal != PortAvailability.inUseMessage(port: port) { return ("port \(port) was refused with \(refusal), not the in-use message; \(note)", false, note) }
        return (nil, false, note)
    }
    if anyInUse { return ("port \(port) was accepted though a recorded answer said in use; \(note)", false, note) }
    let missing = Set(PortAvailability.hostsToCheck(bindHost: bindHost, localIPv4s: localIPv4s)).subtracting(mine.map { $0.host })
    if !missing.isEmpty { return ("port \(port) was accepted without asking \(missing.sorted()); \(note)", false, note) }
    return (nil, true, note)
}

private func typedOutcome(ports: [Int], bindHost: String, inner: any PortBinding, distortion: RecordingBinder.Distortion = .none) -> PassOutcome {
    var wrong: [String] = []
    var accepted = 0
    var notes: [String] = []
    for port in ports {
        let recorder = RecordingBinder(inner: inner, distortion: distortion)
        let refusal = PortAvailability.typedPortRefusal(port: port, bindHost: bindHost, binder: recorder, reserved: nil)
        let judged = judgeTyped(port: port, bindHost: bindHost, refusal: refusal, answers: recorder.answers)
        if let message = judged.wrong { wrong.append(message) }
        if judged.acceptedFree { accepted += 1 }
        notes.append(judged.note)
    }
    if !wrong.isEmpty { return .wrong(wrong.joined(separator: "; ")) }
    if accepted == 0 { return .inconclusive("no candidate was answered free: " + notes.joined(separator: "; ")) }
    return .correct
}

private func searchOutcome(start: Int, bindHost: String, inner: any PortBinding, distortion: RecordingBinder.Distortion = .none, candidates: Int = PortAvailability.candidateCount) -> PassOutcome {
    let recorder = RecordingBinder(inner: inner, distortion: distortion)
    let choice = PortAvailability.firstFreePort(from: start, bindHost: bindHost, binder: recorder, candidates: candidates)
    let last = min(start + candidates - 1, 65535)
    let range = start <= last ? Array(start...last) : []
    let answers = recorder.answers
    func gotInUse(_ port: Int) -> Bool { answers.contains { $0.port == port && !$0.free } }
    switch choice {
    case .free(let chosen):
        guard range.contains(chosen) else { return .wrong("chose \(chosen), outside \(start)...\(last)") }
        var problems: [String] = []
        for port in range where port < chosen && !gotInUse(port) {
            problems.append("skipped a candidate with no in-use answer; \(describe(port: port, answers))")
        }
        let mine = answers.filter { $0.port == chosen }
        if mine.contains(where: { !$0.free }) { problems.append("chose a port a recorded answer said in use; \(describe(port: chosen, answers))") }
        let missing = Set(PortAvailability.hostsToCheck(bindHost: bindHost)).subtracting(mine.map { $0.host })
        if !missing.isEmpty { problems.append("chose \(chosen) without asking \(missing.sorted())") }
        return problems.isEmpty ? .correct : .wrong(problems.joined(separator: "; "))
    case .exhausted(let first, let end):
        if first != start || end != last { return .wrong("exhausted named \(first)...\(end), the range was \(start)...\(last)") }
        let unproved = range.filter { !gotInUse($0) }
        if !unproved.isEmpty { return .wrong("gave up though no in-use answer was recorded for \(unproved.map { describe(port: $0, answers) })") }
        return .inconclusive("every candidate got an in-use answer: " + range.map { describe(port: $0, answers) }.joined(separator: "; "))
    }
}

/// Distinct ports the system handed out a moment ago, used only as
/// candidates: how the product treats them is judged by its own record.
private func ephemeralCandidates(count: Int) -> [Int]? {
    var listeners: [HeldListener] = []
    for _ in 0..<count {
        guard let next = HeldListener(host: "127.0.0.1") else { return nil }
        listeners.append(next)
    }
    return listeners.map { $0.port }
}

// Serialized: tests that hold a run of 50 neighbouring ports would otherwise
// make a concurrent test see its own neighbours as taken.
@Suite("Port availability", .serialized)
struct PortAvailabilityTests {
    private let binder = SystemPortBinder()

    @Test("the addresses checked are the reach's own, loopback and all addresses on both IP versions, and each local IPv4 address once")
    func hostsChecked() {
        #expect(PortAvailability.hostsToCheck(bindHost: "127.0.0.1") == ["127.0.0.1", "::1", "0.0.0.0", "::"])
        #expect(PortAvailability.hostsToCheck(bindHost: "0.0.0.0") == ["0.0.0.0", "127.0.0.1", "::1", "::"])
        #expect(PortAvailability.hostsToCheck(bindHost: "100.101.102.103", localIPv4s: ["100.101.102.103", "192.168.1.5", "127.0.0.1"]) == ["100.101.102.103", "127.0.0.1", "::1", "0.0.0.0", "::", "192.168.1.5"])
    }

    @Test("a port another app holds is refused whichever address it holds it on, under every reach")
    func typedPortHeldOnAnyAddress() throws {
        let hosts = ["127.0.0.1", "0.0.0.0", "::", "::1"]
        for holder in hosts {
            for bindHost in ["127.0.0.1", "0.0.0.0", "100.101.102.103"] {
                let held = try #require(HeldListener(host: holder))
                #expect(
                    PortAvailability.typedPortRefusal(port: held.port, bindHost: bindHost, binder: binder, reserved: nil) == PortAvailability.inUseMessage(port: held.port),
                    "a listener on \(holder) should refuse a port for \(bindHost)"
                )
            }
        }
        let dual = try #require(HeldListener(host: "::", dualStack: true))
        #expect(PortAvailability.typedPortRefusal(port: dual.port, bindHost: "127.0.0.1", binder: binder, reserved: nil) != nil, "a dual-stack holder is refused")
    }

    @Test("a taken default port moves to the next free one")
    func defaultTaken() throws {
        let held = try #require(HeldListener.run(host: "127.0.0.1", count: 1))
        let recorder = RecordingBinder(inner: binder)
        guard case .free(let chosen) = PortAvailability.firstFreePort(from: held[0].port, bindHost: "127.0.0.1", binder: recorder) else {
            Issue.record("expected a free port")
            return
        }
        #expect(chosen > held[0].port)
        let answers = recorder.answers.filter { $0.port == chosen }
        #expect(Set(answers.map { $0.host }) == ["127.0.0.1", "::1", "0.0.0.0", "::"])
        #expect(answers.allSatisfy { $0.free }, "the search saw the chosen port free on both address families")
    }

    @Test("several taken ports in a row are all skipped")
    func severalTaken() throws {
        let held = try #require(HeldListener.run(host: "127.0.0.1", count: 3))
        let start = held[0].port
        guard case .free(let chosen) = PortAvailability.firstFreePort(from: start, bindHost: "127.0.0.1", binder: binder) else {
            Issue.record("expected a free port")
            return
        }
        #expect(chosen >= start + 3)
    }

    @Test("when all 50 candidate ports are taken the search says so, naming the range")
    func allFiftyTaken() throws {
        let held = try #require(HeldListener.run(host: "127.0.0.1", count: PortAvailability.candidateCount))
        let start = held[0].port
        #expect(PortAvailability.firstFreePort(from: start, bindHost: "127.0.0.1", binder: binder) == .exhausted(first: start, last: start + 49))
    }

    @Test("the search stops at 65535")
    func stopsAtTop() {
        let allTaken = TableBinder(allTaken: true)
        #expect(PortAvailability.firstFreePort(from: 65530, bindHost: "127.0.0.1", binder: allTaken) == .exhausted(first: 65530, last: 65535))
        let topFree = TableBinder(taken: ["127.0.0.1": Set(65530...65534)])
        #expect(PortAvailability.firstFreePort(from: 65530, bindHost: "127.0.0.1", binder: topFree) == .free(65535))
    }

    @Test("during setup a saved port that is still free stays, and a taken one moves to the first free from the default")
    func setupKeepsAFreeSavedPort() {
        let defaultPort = 4000
        let table = TableBinder(taken: ["127.0.0.1": [4001]])
        #expect(PortAvailability.setupPort(current: 4002, default: defaultPort, bindHost: "127.0.0.1", binder: table) == .free(4002), "a non-default saved port stays while free, even though the default is free too")
        #expect(PortAvailability.setupPort(current: 4000, default: defaultPort, bindHost: "127.0.0.1", binder: table) == .free(4000))
        #expect(PortAvailability.setupPort(current: 4001, default: defaultPort, bindHost: "127.0.0.1", binder: table) == .free(4000), "a taken saved port searches from the default")
        let defaultTaken = TableBinder(taken: ["127.0.0.1": [4000, 4001]])
        #expect(PortAvailability.setupPort(current: 4001, default: defaultPort, bindHost: "127.0.0.1", binder: defaultTaken) == .free(4002))
        #expect(PortAvailability.setupPort(current: 4001, default: defaultPort, bindHost: "127.0.0.1", binder: TableBinder(allTaken: true)) == .exhausted(first: 4000, last: 4049))
    }

    @Test("the relay's own status port is never chosen: setup skips it, a typed one is refused as its own")
    func statusPortIsReserved() {
        let table = TableBinder(taken: ["127.0.0.1": [4000]])
        #expect(PortAvailability.firstFreePort(from: 4000, bindHost: "127.0.0.1", binder: table, reserved: 4001) == .free(4002), "default taken and the status port next in line is skipped")
        #expect(PortAvailability.setupPort(current: 4001, default: 4000, bindHost: "127.0.0.1", binder: TableBinder(), reserved: 4001) == .free(4000), "a saved port equal to the status port is replaced")
        #expect(PortAvailability.setupPort(current: 4000, default: 4000, bindHost: "127.0.0.1", binder: table, reserved: 4001) == .free(4002))
        for current in 3990...4060 {
            #expect(PortAvailability.setupPort(current: current, default: 4000, bindHost: "127.0.0.1", binder: table, reserved: 4001) != .free(4001))
        }
        #expect(PortAvailability.typedPortRefusal(port: 4001, bindHost: "127.0.0.1", binder: TableBinder(), reserved: 4001) == "CGM Relay already uses port 4001 for itself. Choose another.")
        #expect(PortAvailability.typedPortRefusal(port: 4000, bindHost: "127.0.0.1", binder: table, reserved: 4001) == "Port 4000 is in use by another app. Choose another.")
        #expect(PortAvailability.typedPortRefusal(port: 4002, bindHost: "127.0.0.1", binder: table, reserved: 4001) == nil)
        #expect(PortAvailability.port(inAddress: "127.0.0.1:1338") == 1338)
        #expect(PortAvailability.port(inAddress: "nonsense") == nil)
    }

    @Test("before a start a saved port stays once setup is over or the person chose it, unless it is the status port, which is replaced at any time")
    func startPortRepairsASavedStatusPort() {
        let table = TableBinder(taken: ["127.0.0.1": [4000]])
        #expect(PortAvailability.startPort(current: 4005, default: 4000, searching: false, locked: false, bindHost: "127.0.0.1", binder: table, reserved: 4001) == .keep, "a person's or finished setup's port is kept")
        #expect(PortAvailability.startPort(current: 4000, default: 4000, searching: false, locked: false, bindHost: "127.0.0.1", binder: table, reserved: 4001) == .keep, "kept even when taken: that failure is reported, never moved")
        #expect(PortAvailability.startPort(current: 4001, default: 4000, searching: false, locked: false, bindHost: "127.0.0.1", binder: table, reserved: 4001) == .use(4002), "a saved status port is replaced after setup too")
        #expect(PortAvailability.startPort(current: 4001, default: 4000, searching: false, locked: false, bindHost: "127.0.0.1", binder: TableBinder(allTaken: true), reserved: 4001) == .exhausted(first: 4000, last: 4049))
        #expect(PortAvailability.startPort(current: 4000, default: 4000, searching: true, locked: false, bindHost: "127.0.0.1", binder: table, reserved: 4001) == .use(4002), "during setup it is setupPort")
        #expect(PortAvailability.startPort(current: 4001, default: 4000, searching: false, locked: false, bindHost: "127.0.0.1", binder: table, reserved: nil) == .keep, "no status port, nothing to repair")
    }

    @Test("while Tailscale HTTPS holds the port it is kept, and a held status port refuses the start rather than moving")
    func startPortUnderTailscaleHTTPS() {
        let table = TableBinder(taken: ["127.0.0.1": [4000]])
        #expect(PortAvailability.startPort(current: 4001, default: 4000, searching: false, locked: true, bindHost: "127.0.0.1", binder: table, reserved: 4001) == .statusPortLocked)
        #expect(PortAvailability.startPort(current: 4001, default: 4000, searching: true, locked: true, bindHost: "127.0.0.1", binder: TableBinder(), reserved: 4001) == .statusPortLocked, "refused during setup too")
        #expect(PortAvailability.startPort(current: 4000, default: 4000, searching: true, locked: true, bindHost: "127.0.0.1", binder: table, reserved: 4001) == .keep, "a held port is never moved, even when taken")
        #expect(PortAvailability.startPort(current: 4005, default: 4000, searching: false, locked: true, bindHost: "127.0.0.1", binder: table, reserved: 4001) == .keep)
    }

    @Test("a port another app holds on either address family is taken, and the refusal names it")
    func ipv4AndIPv6Conflicts() throws {
        let v4 = try #require(HeldListener.run(host: "127.0.0.1", count: 1))
        #expect(!PortAvailability.isFree(port: v4[0].port, bindHost: "127.0.0.1", binder: binder))
        let wide = try #require(HeldListener.run(host: "0.0.0.0", count: 1))
        #expect(!PortAvailability.isFree(port: wide[0].port, bindHost: "0.0.0.0", binder: binder))
        #expect(PortAvailability.inUseMessage(port: v4[0].port) == "Port \(v4[0].port) is in use by another app. Choose another.")

        guard let v6 = HeldListener(host: "::1") else { return }
        #expect(!PortAvailability.isFree(port: v6.port, bindHost: "127.0.0.1", binder: binder), "an IPv6 holder blocks a loopback reach too")
    }

    @Test("every address the reach binds is asked, and one taken makes the port taken")
    func everyAddressAsked() {
        let table = TableBinder(taken: ["::": [4000], "192.168.1.5": [4001]])
        #expect(!PortAvailability.isFree(port: 4000, bindHost: "0.0.0.0", binder: table))
        #expect(!PortAvailability.isFree(port: 4000, bindHost: "127.0.0.1", binder: table), "a loopback reach is blocked by an all-addresses holder too")
        #expect(PortAvailability.isFree(port: 4001, bindHost: "127.0.0.1", binder: table), "a local address not asked about is not")
        #expect(!PortAvailability.isFree(port: 4001, bindHost: "127.0.0.1", binder: table, localIPv4s: ["192.168.1.5"]))
    }

    // MARK: Decisions over fixed answers

    @Test("a typed port every address answers free is accepted, after every address was asked", arguments: ["127.0.0.1", "0.0.0.0", "100.101.102.103"])
    func typedPortAnsweredFreeIsAccepted(_ bindHost: String) {
        let recorder = RecordingBinder(inner: TableBinder())
        #expect(PortAvailability.typedPortRefusal(port: 4000, bindHost: bindHost, binder: recorder, reserved: nil, localIPv4s: ["192.168.1.5"]) == nil)
        #expect(Set(recorder.answers.map { $0.host }) == Set(PortAvailability.hostsToCheck(bindHost: bindHost, localIPv4s: ["192.168.1.5"])))
    }

    @Test("a typed port any one address answers in use is refused with the in-use message", arguments: ["127.0.0.1", "0.0.0.0", "100.101.102.103"])
    func typedPortAnsweredInUseOnAnyAddressIsRefused(_ bindHost: String) {
        let localIPv4s = ["192.168.1.5"]
        for holder in PortAvailability.hostsToCheck(bindHost: bindHost, localIPv4s: localIPv4s) {
            let table = TableBinder(taken: [holder: [4000]])
            #expect(
                PortAvailability.typedPortRefusal(port: 4000, bindHost: bindHost, binder: table, reserved: nil, localIPv4s: localIPv4s) == PortAvailability.inUseMessage(port: 4000),
                "in use on \(holder) for reach \(bindHost)"
            )
            #expect(PortAvailability.typedPortRefusal(port: 4001, bindHost: bindHost, binder: table, reserved: nil, localIPv4s: localIPv4s) == nil, "another port stays free")
        }
    }

    @Test("the reserved status port is refused as the relay's own, without asking any address")
    func reservedPortIsRefusedWithoutAsking() {
        for inner in [TableBinder(), TableBinder(allTaken: true)] {
            let recorder = RecordingBinder(inner: inner)
            #expect(PortAvailability.typedPortRefusal(port: 4001, bindHost: "127.0.0.1", binder: recorder, reserved: 4001) == PortAvailability.reservedMessage(port: 4001))
            #expect(recorder.answers.isEmpty)
        }
    }

    @Test("the search skips every in-use candidate and returns the first free one", arguments: [0, 1, 2, 10, 48, 49])
    func firstFreeSkipsInUsePrefix(_ skipped: Int) {
        let hosts = PortAvailability.hostsToCheck(bindHost: "127.0.0.1")
        var taken: [String: Set<Int>] = [:]
        // Every candidate but the one at offset `skipped` is in use, each on
        // a different address in turn, so that one is the only right answer.
        for offset in 0..<PortAvailability.candidateCount where offset != skipped {
            taken[hosts[offset % hosts.count], default: []].insert(4000 + offset)
        }
        #expect(PortAvailability.firstFreePort(from: 4000, bindHost: "127.0.0.1", binder: TableBinder(taken: taken)) == .free(4000 + skipped))
    }

    @Test("when every candidate is in use the search names the first and last")
    func firstFreeExhausted() {
        let hosts = PortAvailability.hostsToCheck(bindHost: "127.0.0.1")
        var taken: [String: Set<Int>] = [:]
        for offset in 0..<PortAvailability.candidateCount { taken[hosts[offset % hosts.count], default: []].insert(4000 + offset) }
        #expect(PortAvailability.firstFreePort(from: 4000, bindHost: "127.0.0.1", binder: TableBinder(taken: taken)) == .exhausted(first: 4000, last: 4049))
        #expect(PortAvailability.firstFreePort(from: 4000, bindHost: "127.0.0.1", binder: TableBinder(allTaken: true)) == .exhausted(first: 4000, last: 4049))
    }

    // MARK: Real passes, judged by the answers their own call received

    @Test("a free port is accepted, judged by what the call was answered")
    func realPassFreePort() throws {
        let ports = try #require(ephemeralCandidates(count: 5))
        try conclude(typedOutcome(ports: ports, bindHost: "0.0.0.0", inner: binder))
    }

    @Test("a port whose connections are only closing is accepted, judged by what the call was answered")
    func realPassClosingPort() throws {
        let ports = (0..<5).compactMap { _ in portInTimeWait() }
        try #require(!ports.isEmpty)
        try conclude(typedOutcome(ports: ports, bindHost: "0.0.0.0", inner: binder))
    }

    @Test("the real binder accepts a port whose only use is a closing connection, on every address a start asks", arguments: ["127.0.0.1", "0.0.0.0"])
    func realBinderAcceptsAClosingPort(_ host: String) throws {
        switch closingConnectionPort() {
        case .unproven(let reason):
            try Test.cancel("the closing connection could not be set up, so nothing is proved: \(reason)")
        case .ready(let port):
            #expect(binder.canBind(host: host, port: port), "the binder refused \(host):\(port), whose only use is a closing connection the test made")
        }
    }

    @Test("a free default port is chosen, judged by what the search was answered")
    func realPassDefaultFree() throws {
        let start = try #require(ephemeralCandidates(count: 1)).first!
        try conclude(searchOutcome(start: start, bindHost: "127.0.0.1", inner: binder))
    }

    @Test("a held default port is skipped, judged by what the search was answered")
    func realPassDefaultHeld() throws {
        let held = try #require(HeldListener.run(host: "127.0.0.1", count: 2))
        try conclude(searchOutcome(start: held[0].port, bindHost: "127.0.0.1", inner: binder))
    }

    // MARK: A pass with nothing to prove is cancelled

    @Test("a typed pass in which every candidate got an in-use answer is inconclusive and ends cancelled with the candidates named")
    func inconclusiveTypedPassIsCancelled() throws {
        let held = try #require(HeldListener.run(host: "127.0.0.1", count: 2))
        let outcome = typedOutcome(ports: held.map { $0.port }, bindHost: "127.0.0.1", inner: binder)
        guard case .inconclusive(let reason) = outcome else {
            Issue.record("expected an inconclusive pass, got \(outcome)")
            return
        }
        for listener in held { #expect(reason.contains("port \(listener.port): 127.0.0.1 in use")) }
        try conclude(outcome)
    }

    @Test("a search pass in which every candidate got an in-use answer is inconclusive and ends cancelled with the candidates named")
    func inconclusiveSearchPassIsCancelled() throws {
        let held = try #require(HeldListener.run(host: "127.0.0.1", count: 3))
        let outcome = searchOutcome(start: held[0].port, bindHost: "127.0.0.1", inner: binder, candidates: 3)
        guard case .inconclusive(let reason) = outcome else {
            Issue.record("expected an inconclusive pass, got \(outcome)")
            return
        }
        for listener in held { #expect(reason.contains("port \(listener.port): 127.0.0.1 in use")) }
        try conclude(outcome)
    }

    // MARK: A planted wrong decision turns the pass red

    private func expectWrong(_ outcome: PassOutcome, _ what: String) {
        guard case .wrong = outcome else {
            Issue.record("\(what): expected the pass to fail, got \(outcome)")
            return
        }
    }

    @Test("a binder that makes the product refuse a port its record shows free fails the typed pass")
    func plantedRefusalOfFreePortFailsTypedPass() {
        let free = TableBinder()
        #expect(typedOutcome(ports: [4000, 4001], bindHost: "127.0.0.1", inner: free) == .correct, "control: the honest product passes")
        expectWrong(typedOutcome(ports: [4000, 4001], bindHost: "127.0.0.1", inner: free, distortion: .refuseFree), "refusing a port recorded free")
    }

    @Test("a binder that makes the product accept a port its record shows in use fails the typed pass")
    func plantedAcceptanceOfInUsePortFailsTypedPass() throws {
        let held = try #require(HeldListener(host: "127.0.0.1"))
        guard case .inconclusive = typedOutcome(ports: [held.port], bindHost: "127.0.0.1", inner: binder) else {
            Issue.record("control: the honest product refusing a held port should leave the pass inconclusive")
            return
        }
        expectWrong(typedOutcome(ports: [held.port], bindHost: "127.0.0.1", inner: binder, distortion: .acceptInUse), "accepting a port recorded in use")
    }

    @Test("a binder that makes the search skip a candidate its record shows free fails the search pass")
    func plantedSkipOfFreeCandidateFailsSearchPass() {
        let free = TableBinder()
        #expect(searchOutcome(start: 4000, bindHost: "127.0.0.1", inner: free) == .correct, "control: the honest search passes")
        expectWrong(searchOutcome(start: 4000, bindHost: "127.0.0.1", inner: free, distortion: .refuseFree), "skipping candidates recorded free")
    }

    @Test("a binder that makes the search choose a candidate its record shows in use fails the search pass")
    func plantedChoiceOfInUseCandidateFailsSearchPass() {
        let taken = TableBinder(taken: ["127.0.0.1": [4000]])
        #expect(searchOutcome(start: 4000, bindHost: "127.0.0.1", inner: taken) == .correct, "control: the honest search passes")
        expectWrong(searchOutcome(start: 4000, bindHost: "127.0.0.1", inner: taken, distortion: .acceptInUse), "choosing a candidate recorded in use")
    }
}
