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

private struct TableBinder: PortBinding {
    var taken: [String: Set<Int>] = [:]
    var allTaken = false
    func canBind(host: String, port: Int) -> Bool {
        !allTaken && !(taken[host]?.contains(port) ?? false)
    }
}

/// Answers as the real binder does and keeps every answer, so a test can
/// check what the search saw without asking the system again later.
private final class RecordingBinder: PortBinding, @unchecked Sendable {
    let inner: any PortBinding
    private(set) var answers: [(host: String, port: Int, free: Bool)] = []
    init(inner: any PortBinding) { self.inner = inner }
    func canBind(host: String, port: Int) -> Bool {
        let free = inner.canBind(host: host, port: port)
        answers.append((host, port, free))
        return free
    }
}

// Serialized: tests that hold a run of 50 neighbouring ports would otherwise
// make a concurrent test see its own neighbours as taken.
@Suite("Port availability", .serialized)
struct PortAvailabilityTests {
    private let binder = SystemPortBinder()

    /// A free ephemeral port, found by binding and releasing one.
    private func freePort() throws -> Int {
        let probe = try #require(HeldListener(host: "127.0.0.1"))
        return probe.port
    }

    @Test("the addresses checked are the reach's own, loopback and all addresses on both IP versions, and each local IPv4 address once")
    func hostsChecked() {
        #expect(PortAvailability.hostsToCheck(bindHost: "127.0.0.1") == ["127.0.0.1", "::1", "0.0.0.0", "::"])
        #expect(PortAvailability.hostsToCheck(bindHost: "0.0.0.0") == ["0.0.0.0", "127.0.0.1", "::1", "::"])
        #expect(PortAvailability.hostsToCheck(bindHost: "100.101.102.103", localIPv4s: ["100.101.102.103", "192.168.1.5", "127.0.0.1"]) == ["100.101.102.103", "127.0.0.1", "::1", "0.0.0.0", "::", "192.168.1.5"])
    }

    @Test("a port another app holds is refused whichever address it holds it on, under every reach, and one only closing connections is free")
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
        let free = try freePort()
        #expect(PortAvailability.typedPortRefusal(port: free, bindHost: "0.0.0.0", binder: binder, reserved: nil) == nil)
        // The closing port comes from the ephemeral range, so a test running
        // alongside can open a connection on it before the check; that one is
        // retried with a fresh port. Refusing every closing port is the failure.
        var refusals: [String] = []
        for _ in 0..<5 {
            let closing = try #require(portInTimeWait())
            guard let refusal = PortAvailability.typedPortRefusal(port: closing, bindHost: "0.0.0.0", binder: binder, reserved: nil) else {
                return
            }
            refusals.append(refusal)
        }
        Issue.record("connections still closing do not hold a port, yet every one was refused: \(refusals)")
    }

    // Another suite running alongside can take a released port between the
    // probe and the search, so a port lost that way is retried; one still
    // free after the search but not chosen is the failure.
    @Test("a free default port is chosen as it is")
    func defaultFree() throws {
        for _ in 0..<20 {
            let port = try freePort()
            guard PortAvailability.isFree(port: port, bindHost: "127.0.0.1", binder: binder) else { continue }
            let choice = PortAvailability.firstFreePort(from: port, bindHost: "127.0.0.1", binder: binder)
            if choice == .free(port) { return }
            if PortAvailability.isFree(port: port, bindHost: "127.0.0.1", binder: binder) {
                Issue.record("port \(port) was free on both address families but the search chose \(choice)")
                return
            }
        }
        Issue.record("no port stayed free long enough to search from")
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
}
