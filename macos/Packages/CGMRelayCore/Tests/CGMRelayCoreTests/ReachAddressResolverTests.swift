import Foundation
import Testing
@testable import CGMRelayCore

@Suite("ReachAddressResolver")
struct ReachAddressResolverTests {
    static let mixed = [
        NetworkInterfaceAddress(name: "lo0", address: "127.0.0.1"),
        NetworkInterfaceAddress(name: "en0", address: "192.168.1.42"),
        NetworkInterfaceAddress(name: "utun4", address: "100.101.102.5"),
    ]

    @Test("This Mac only always binds and displays loopback, whatever interfaces exist")
    func thisMacOnlyIsAlwaysLoopback() {
        #expect(ReachAddressResolver.bindHost(for: .thisMacOnly, interfaces: Self.mixed) == "127.0.0.1")
        #expect(ReachAddressResolver.displayHost(for: .thisMacOnly, interfaces: Self.mixed) == "127.0.0.1")
        #expect(ReachAddressResolver.bindHost(for: .thisMacOnly, interfaces: []) == "127.0.0.1")
    }

    @Test("My tailnet binds and displays the discovered Tailscale address")
    func myTailnetUsesTheTailscaleAddress() {
        #expect(ReachAddressResolver.bindHost(for: .myTailnet, interfaces: Self.mixed) == "100.101.102.5")
        #expect(ReachAddressResolver.displayHost(for: .myTailnet, interfaces: Self.mixed) == "100.101.102.5")
    }

    @Test("My tailnet with no tailnet address falls back to loopback rather than crashing or binding nothing")
    func myTailnetWithNoTailscaleAddressFallsBack() {
        let noTailnet = [NetworkInterfaceAddress(name: "en0", address: "192.168.1.42")]
        #expect(ReachAddressResolver.tailscaleIPv4(among: noTailnet) == nil)
        #expect(ReachAddressResolver.bindHost(for: .myTailnet, interfaces: noTailnet) == "127.0.0.1")
        #expect(ReachAddressResolver.displayHost(for: .myTailnet, interfaces: noTailnet) == "127.0.0.1")
    }

    @Test("My local network keeps its plain listener on loopback and displays the private LAN address")
    func myLocalNetworkPlainListenerStaysOnLoopback() {
        #expect(ReachAddressResolver.bindHost(for: .myLocalNetwork, interfaces: Self.mixed) == "127.0.0.1")
        #expect(ReachAddressResolver.displayHost(for: .myLocalNetwork, interfaces: Self.mixed) == "192.168.1.42")
    }

    @Test("the follower port is tested on every interface for My local network, and on the listening host for the others")
    func portCheckHostCoversEveryListener() {
        #expect(ReachAddressResolver.portCheckHost(for: .myLocalNetwork, interfaces: Self.mixed) == "0.0.0.0")
        #expect(ReachAddressResolver.portCheckHost(for: .thisMacOnly, interfaces: Self.mixed) == "127.0.0.1")
        #expect(ReachAddressResolver.portCheckHost(for: .myTailnet, interfaces: Self.mixed) == "100.101.102.5")
    }

    @Test("only private addresses on ordinary interfaces are offered to the local network route, each once and in a fixed order")
    func privateLANAddressesOnly() {
        let interfaces = [
            NetworkInterfaceAddress(name: "en1", address: "10.0.0.7"),
            NetworkInterfaceAddress(name: "en0", address: "192.168.1.42"),
            NetworkInterfaceAddress(name: "en2", address: "203.0.113.9"),
            NetworkInterfaceAddress(name: "en3", address: "172.15.0.1"),
            NetworkInterfaceAddress(name: "en4", address: "172.16.4.2"),
            NetworkInterfaceAddress(name: "en5", address: "192.168.1.42"),
            NetworkInterfaceAddress(name: "bridge100", address: "192.168.64.1"),
            NetworkInterfaceAddress(name: "utun4", address: "100.101.102.5"),
            NetworkInterfaceAddress(name: "en6", address: "169.254.3.4"),
        ]
        #expect(ReachAddressResolver.privateLANIPv4s(among: interfaces) == ["10.0.0.7", "172.16.4.2", "192.168.1.42"])
        #expect(ReachAddressResolver.primaryPrivateLANIPv4(among: interfaces, primaryInterfaceName: "en0") == "192.168.1.42")
        #expect(ReachAddressResolver.primaryPrivateLANIPv4(among: interfaces, primaryInterfaceName: "en2") == "10.0.0.7", "a public address on the default route is never the one given to a phone")
        let publicOnly = [NetworkInterfaceAddress(name: "en0", address: "203.0.113.9")]
        #expect(ReachAddressResolver.displayHostAvailability(for: .myLocalNetwork, interfaces: publicOnly) == .unavailable(reason: "Waiting for a network connection."))
    }

    @Test("My local network with no LAN address falls back to loopback for display")
    func myLocalNetworkWithNoLANAddressFallsBack() {
        let tailnetOnly = [NetworkInterfaceAddress(name: "utun4", address: "100.101.102.5")]
        #expect(ReachAddressResolver.primaryLANIPv4(among: tailnetOnly) == nil)
        #expect(ReachAddressResolver.displayHost(for: .myLocalNetwork, interfaces: tailnetOnly) == "127.0.0.1")
    }

    @Test(
        "the Tailscale range boundary is exact: 100.63 and 100.128 are outside it, 100.64 and 100.127 are inside it",
        arguments: [
            ("100.63.0.1", false),
            ("100.64.0.1", true),
            ("100.100.0.1", true),
            ("100.127.255.255", true),
            ("100.128.0.1", false),
            ("10.0.0.1", false),
        ]
    )
    func tailscaleRangeBoundary(_ testCase: (address: String, wantInRange: Bool)) {
        #expect(ReachAddressResolver.isTailscaleAddress(testCase.address) == testCase.wantInRange)
    }

    @Test("a VM bridge interface listed first is never chosen as the local network address")
    func vmBridgeInterfaceExcluded() {
        let interfaces = [
            NetworkInterfaceAddress(name: "bridge100", address: "192.168.64.1"),
            NetworkInterfaceAddress(name: "vmnet1", address: "192.168.72.1"),
            NetworkInterfaceAddress(name: "en0", address: "192.168.1.50"),
        ]
        #expect(ReachAddressResolver.primaryLANIPv4(among: interfaces) == "192.168.1.50")
    }

    @Test("a VPN tunnel interface (utun, ipsec, ppp) listed first is never chosen as the local network address")
    func vpnTunnelInterfacesExcluded() {
        let interfaces = [
            NetworkInterfaceAddress(name: "ppp0", address: "10.8.0.5"),
            NetworkInterfaceAddress(name: "ipsec0", address: "10.9.0.5"),
            NetworkInterfaceAddress(name: "en0", address: "192.168.1.50"),
        ]
        #expect(ReachAddressResolver.primaryLANIPv4(among: interfaces) == "192.168.1.50")
    }

    @Test("a self-assigned 169.254.x.x link-local address is never chosen, even with nothing else present")
    func linkLocalAddressExcluded() {
        let interfaces = [NetworkInterfaceAddress(name: "en0", address: "169.254.10.4")]
        #expect(ReachAddressResolver.primaryLANIPv4(among: interfaces) == nil)
        #expect(ReachAddressResolver.displayHostAvailability(for: .myLocalNetwork, interfaces: interfaces) == .unavailable(reason: "Waiting for a network connection."))
    }

    @Test("the interface actually carrying the default route wins over an earlier-listed candidate")
    func defaultRouteInterfaceWins() {
        let interfaces = [
            NetworkInterfaceAddress(name: "en1", address: "192.168.2.9"),
            NetworkInterfaceAddress(name: "en0", address: "192.168.1.50"),
        ]
        #expect(ReachAddressResolver.primaryLANIPv4(among: interfaces, primaryInterfaceName: "en0") == "192.168.1.50")
    }

    @Test("with no known default-route interface, the first physical LAN candidate is used")
    func fallsBackToFirstCandidateWithNoPrimaryInterfaceName() {
        let interfaces = [
            NetworkInterfaceAddress(name: "en1", address: "192.168.2.9"),
            NetworkInterfaceAddress(name: "en0", address: "192.168.1.50"),
        ]
        #expect(ReachAddressResolver.primaryLANIPv4(among: interfaces, primaryInterfaceName: nil) == "192.168.2.9")
    }

    @Test("displayHostAvailability reports the real address when this Mac has one, for every reach")
    func displayHostAvailabilityReportsRealAddresses() {
        #expect(ReachAddressResolver.displayHostAvailability(for: .thisMacOnly, interfaces: []) == .available("127.0.0.1"))
        #expect(ReachAddressResolver.displayHostAvailability(for: .myTailnet, interfaces: Self.mixed) == .available("100.101.102.5"))
        #expect(ReachAddressResolver.displayHostAvailability(for: .myLocalNetwork, interfaces: Self.mixed) == .available("192.168.1.42"))
    }

    @Test("displayHostAvailability reports a plain reason, never the loopback fallback, when this Mac has no address for the chosen reach")
    func displayHostAvailabilityReportsNoAddressPlainly() {
        let noTailnet = [NetworkInterfaceAddress(name: "en0", address: "192.168.1.42")]
        #expect(ReachAddressResolver.displayHostAvailability(for: .myTailnet, interfaces: noTailnet) == .unavailable(reason: "Waiting for Tailscale to connect."))

        let tailnetOnly = [NetworkInterfaceAddress(name: "utun4", address: "100.101.102.5")]
        #expect(ReachAddressResolver.displayHostAvailability(for: .myLocalNetwork, interfaces: tailnetOnly) == .unavailable(reason: "Waiting for a network connection."))
    }
}

@Suite("ConnectPaneAddressState")
struct ConnectPaneAddressStateTests {
    static let localListen = "127.0.0.1|relay-mac.local|192.168.1.42"

    static let cases: [(name: String, reach: NetworkReach, boundHost: String?, impliedBindHost: String, availability: ReachAddressAvailability, want: ConnectPaneAddressState)] = [
        ("This Mac only, engine running", .thisMacOnly, "127.0.0.1", "127.0.0.1", .available("127.0.0.1"), .thisMacOnly),
        ("This Mac only, engine stopped", .thisMacOnly, nil, "127.0.0.1", .available("127.0.0.1"), .thisMacOnly),
        ("This Mac only, no address available for the chosen reach at all", .thisMacOnly, nil, "127.0.0.1", .unavailable(reason: "n/a"), .thisMacOnly),

        ("My tailnet, bound to the tailnet address", .myTailnet, "100.101.102.5", "100.101.102.5", .available("100.101.102.5"), .ready(address: "http://100.101.102.5:1337")),
        // Tailscale disconnects after the engine started: the implied host
        // falls back to loopback while boundHost is still the tailnet
        // address, so the pane says the setting is being applied rather
        // than offering an address nothing listens on.
        ("My tailnet, Tailscale disconnected after start: bound to the now-stale tailnet address", .myTailnet, "100.101.102.5", "127.0.0.1", .unavailable(reason: "Waiting for Tailscale to connect."), .unavailable(reason: "The network setting is being applied.")),
        ("consequence: My tailnet bound to the loopback fallback is never offered as ready", .myTailnet, "127.0.0.1", "127.0.0.1", .available("100.101.102.5"), .unavailable(reason: "Waiting for Tailscale to connect.")),
        ("My tailnet, nothing running", .myTailnet, nil, "100.101.102.5", .available("100.101.102.5"), .unavailable(reason: "The engine isn't running right now.")),
        ("My tailnet just chosen with Tailscale connected: engine still bound to its old address", .myTailnet, "0.0.0.0", "100.101.102.5", .available("100.101.102.5"), .unavailable(reason: "The network setting is being applied.")),

        ("consequence: My local network never shows the loopback listen host, only the https address", .myLocalNetwork, localListen, localListen, .available("192.168.1.42"), .ready(address: "https://192.168.1.42:1337")),
        ("My local network, bound but no LAN address right now", .myLocalNetwork, localListen, localListen, .unavailable(reason: "Waiting for a network connection."), .unavailable(reason: "Waiting for a network connection.")),
        ("My local network, nothing running", .myLocalNetwork, nil, localListen, .available("192.168.1.42"), .unavailable(reason: "The engine isn't running right now.")),
        ("My local network just chosen: engine still bound to its old This Mac only address", .myLocalNetwork, "127.0.0.1", localListen, .available("192.168.1.42"), .unavailable(reason: "The network setting is being applied.")),
        ("My local network, an address joined since the engine started", .myLocalNetwork, localListen, "127.0.0.1|relay-mac.local|10.0.0.7,192.168.1.42", .available("192.168.1.42"), .unavailable(reason: "The network setting is being applied.")),
    ]

    @Test("decide maps every reach, bound host, implied host and availability combination to the pane's own state", arguments: cases)
    func decideMapsEveryCombination(_ testCase: (name: String, reach: NetworkReach, boundHost: String?, impliedBindHost: String, availability: ReachAddressAvailability, want: ConnectPaneAddressState)) {
        let got = ConnectPaneAddressState.decide(reach: testCase.reach, boundHost: testCase.boundHost, impliedBindHost: testCase.impliedBindHost, port: 1337, displayHostAvailability: testCase.availability)
        #expect(got == testCase.want)
    }

    @Test("the local network address names this Mac's .local name when it has one, and always uses https")
    func localNetworkAddressUsesTheName() {
        let got = ConnectPaneAddressState.decide(
            reach: .myLocalNetwork, boundHost: Self.localListen, impliedBindHost: Self.localListen, port: 1337,
            displayHostAvailability: .available("192.168.1.42"), localHostName: "relay-mac.local"
        )
        #expect(got == .ready(address: "https://relay-mac.local:1337"))
    }

    @Test("until the certificate step is finished the local network route offers no address, and every other route is unaffected")
    func certificateStepHoldsBackTheLocalRoute() {
        let local = ConnectPaneAddressState.decide(
            reach: .myLocalNetwork, boundHost: Self.localListen, impliedBindHost: Self.localListen, port: 1337,
            displayHostAvailability: .available("192.168.1.42"), localHostName: "relay-mac.local", certificateStepFinished: false
        )
        #expect(local == .certificateStepNeeded)
        let stopped = ConnectPaneAddressState.decide(
            reach: .myLocalNetwork, boundHost: nil, impliedBindHost: Self.localListen, port: 1337,
            displayHostAvailability: .available("192.168.1.42"), certificateStepFinished: false
        )
        #expect(stopped == .unavailable(reason: "The engine isn't running right now."), "a reason that is about the network is still said first")
        let tailnet = ConnectPaneAddressState.decide(
            reach: .myTailnet, boundHost: "100.101.102.5", impliedBindHost: "100.101.102.5", port: 1337,
            displayHostAvailability: .available("100.101.102.5"), certificateStepFinished: false
        )
        #expect(tailnet == .ready(address: "http://100.101.102.5:1337"))
    }
}

@Suite("PhoneReachability")
struct PhoneReachabilityTests {
    static let cases: [(name: String, reach: NetworkReach, chosen: Bool, serving: Bool, tailnet: Bool, lan: Bool, reachable: Bool)] = [
        ("Tailscale HTTPS serving", .thisMacOnly, true, true, false, false, true),
        ("Tailscale HTTPS serving, reach left at another choice", .myLocalNetwork, true, true, false, false, true),
        ("Tailscale HTTPS chosen but not serving, a network up", .myLocalNetwork, true, false, true, true, false),
        ("A handler serving that was not chosen, reach left at This Mac only", .thisMacOnly, false, true, false, false, false),
        ("A handler serving that was not chosen, no address for the chosen tailnet", .myTailnet, false, true, false, true, false),
        ("A handler serving that was not chosen, My local network with an address", .myLocalNetwork, false, true, false, true, true),
        ("This Mac only, everything available", .thisMacOnly, false, false, true, true, false),
        ("My tailnet with a Tailscale address", .myTailnet, false, false, true, false, true),
        ("My tailnet with no Tailscale address", .myTailnet, false, false, false, true, false),
        ("My local network with an address", .myLocalNetwork, false, false, false, true, true),
        ("My local network with no address", .myLocalNetwork, false, false, true, false, false),
    ]

    @Test("a phone can be reached only through chosen and serving HTTPS, or a tailnet or local network choice with an address", arguments: cases)
    func decideMapsEveryCombination(_ testCase: (name: String, reach: NetworkReach, chosen: Bool, serving: Bool, tailnet: Bool, lan: Bool, reachable: Bool)) {
        let got = PhoneReachability.decide(
            reach: testCase.reach,
            httpsChosen: testCase.chosen,
            httpsServing: testCase.serving,
            tailnetAvailable: testCase.tailnet,
            localNetworkAvailable: testCase.lan
        )
        #expect(got.isReachable == testCase.reachable, Comment(rawValue: testCase.name))
        if !testCase.reachable, case .blocked(let reason) = got {
            #expect(!reason.isEmpty)
        }
        #expect(SetupCompletion.mayFinish(reachability: got) == testCase.reachable, Comment(rawValue: testCase.name))
    }
}

@Suite("BoundAddressDecision")
struct BoundAddressDecisionTests {
    @Test("nothing currently bound never needs a restart")
    func nothingBoundNeedsNoRestart() {
        #expect(BoundAddressDecision.decide(currentBoundHost: nil, impliedBindHost: "100.101.102.5") == .unchanged)
    }

    @Test("the same host implied as the one already bound needs no restart")
    func sameHostNeedsNoRestart() {
        #expect(BoundAddressDecision.decide(currentBoundHost: "127.0.0.1", impliedBindHost: "127.0.0.1") == .unchanged)
    }

    @Test("a freshly implied host that differs from the one currently bound needs a restart")
    func differentHostNeedsRestart() {
        #expect(BoundAddressDecision.decide(currentBoundHost: "127.0.0.1", impliedBindHost: "100.101.102.5") == .restartNeeded)
    }
}

@Suite("Addresses shown to follower apps")
struct FollowerAddressTests {
    static let name = "relay-mac.example-tailnet.ts.net"
    static let tailscaleCases: [(name: String, boundHost: String?, tailscale: TailscaleStatus, https: TailscaleHTTPSState, want: ConnectPaneAddressState)] = [
        ("Tailscale serves ours on 443: the https name with no port", "127.0.0.1", .running(name: name), .on(port: 443), .ready(address: "https://relay-mac.example-tailnet.ts.net")),
        ("Tailscale serves ours on 8443: the port is in the address", "127.0.0.1", .running(name: name), .on(port: 8443), .ready(address: "https://relay-mac.example-tailnet.ts.net:8443")),
        ("serving, engine stopped", nil, .running(name: name), .on(port: 443), .unavailable(reason: "The engine isn't running right now.")),
        ("chosen but Tailscale no longer serves it: never a ready address", "127.0.0.1", .running(name: name), .off(port: 443), .unavailable(reason: "Tailscale HTTPS is off right now.")),
        ("chosen but every port is taken", "127.0.0.1", .running(name: name), .noFreePort, .unavailable(reason: "Tailscale HTTPS is off right now.")),
        ("serve settings unreadable", "127.0.0.1", .running(name: name), .unreadable, .unavailable(reason: "Couldn't read Tailscale's settings right now.")),
        ("Tailscale stopped: never an http address in its place", "127.0.0.1", .stopped, .unavailable, .unavailable(reason: "Waiting for Tailscale to connect.")),
        ("Tailscale absent", "127.0.0.1", .absent, .unavailable, .unavailable(reason: "Waiting for Tailscale to connect.")),
        ("not checked yet", "127.0.0.1", .unknown, .unknown, .unavailable(reason: "Checking Tailscale…")),
    ]

    @Test("with Tailscale HTTPS chosen, the address is the https name only while Tailscale itself serves it", arguments: tailscaleCases)
    func tailscaleHTTPSAddress(_ testCase: (name: String, boundHost: String?, tailscale: TailscaleStatus, https: TailscaleHTTPSState, want: ConnectPaneAddressState)) {
        #expect(ConnectPaneAddressState.decideTailscaleHTTPS(boundHost: testCase.boundHost, tailscale: testCase.tailscale, https: testCase.https) == testCase.want)
    }

    static let counterexamples: [(name: String, json: String)] = [
        ("plain HTTP on the port", TailscaleServeTests.httpOnlyTCP),
        ("another host's entry on the port", TailscaleServeTests.otherHost443),
        ("a foreground session's handler", TailscaleServeTests.foregroundOurs443),
    ]

    @Test("a Tailscale entry that is not this Mac's own HTTPS handler never becomes a ready address", arguments: counterexamples)
    func notOursNeverReady(_ testCase: (name: String, json: String)) {
        let config = TailscaleServeConfigParser.parse(Data(testCase.json.utf8))
        let state = TailscaleHTTPSState.evaluate(status: .running(name: Self.name), config: config, relayPort: 1337)
        #expect(!state.isOn)
        let got = ConnectPaneAddressState.decideTailscaleHTTPS(boundHost: "127.0.0.1", tailscale: .running(name: Self.name), https: state)
        guard case .unavailable = got else {
            Issue.record("\(testCase.name): got \(got)")
            return
        }
    }

    @Test("this Mac's own HTTPS handler read from Tailscale's output is on, with the ready address")
    func ownHandlerIsReady() {
        let config = TailscaleServeConfigParser.parse(Data(TailscaleServeTests.ours443.utf8))
        let state = TailscaleHTTPSState.evaluate(status: .running(name: Self.name), config: config, relayPort: 1337)
        #expect(state == .on(port: 443))
        #expect(ConnectPaneAddressState.decideTailscaleHTTPS(boundHost: "127.0.0.1", tailscale: .running(name: Self.name), https: state) == .ready(address: "https://relay-mac.example-tailnet.ts.net"))
    }

    @Test("an address splits into the URL and Port a follower app's own two fields take")
    func hostAndPortSplit() {
        let http = FollowerAppEntry.hostAndPort(of: "http://192.168.1.42:1337")
        #expect(http.host == "http://192.168.1.42")
        #expect(http.port == "1337")
        let https = FollowerAppEntry.hostAndPort(of: "https://relay-mac.example-tailnet.ts.net")
        #expect(https.host == "https://relay-mac.example-tailnet.ts.net")
        #expect(https.port == nil)
    }

    @Test("the token goes in front of the host, keeping scheme and port")
    func urlWithToken() {
        #expect(FollowerAppEntry.urlWithToken(address: "http://192.168.1.42:1337", token: "abc-_9") == "http://abc-_9@192.168.1.42:1337")
        #expect(FollowerAppEntry.urlWithToken(address: "https://relay-mac.example-tailnet.ts.net", token: "abc") == "https://abc@relay-mac.example-tailnet.ts.net")
    }

    @Test("xDrip4iOS lists URL, API_SECRET, Token, Port in its settings order and ends on Test Connection, with a Port only when the address names one")
    func xDrip4iOSInstructions() {
        let withPort = FollowerAppEntry.instructions(for: .xDrip4iOS, address: "http://192.168.1.42:1337")
        #expect(withPort.steps.contains { $0.contains("Sharing and Services") && $0.contains("Nightscout") })
        #expect(withPort.steps.suffix(5) == [
            "In URL, enter the address without its port.",
            "Leave API_SECRET blank.",
            "In Token, enter the token.",
            "In Port, enter 1337.",
            "Tap Test Connection and wait for the dot to turn green.",
        ])
        #expect(withPort.fields == [
            .init(label: "URL", value: "http://192.168.1.42"),
            .init(label: "Token", value: FollowerAppEntry.tokenPlaceholder),
            .init(label: "Port", value: "1337"),
        ])
        let noPort = FollowerAppEntry.instructions(for: .xDrip4iOS, address: "https://relay-mac.example-tailnet.ts.net")
        #expect(!noPort.steps.contains { $0.contains("Port") })
        #expect(noPort.steps.suffix(4) == [
            "In URL, enter the address.",
            "Leave API_SECRET blank.",
            "In Token, enter the token.",
            "Tap Test Connection and wait for the dot to turn green.",
        ])
        #expect(noPort.fields.map(\.label) == ["URL", "Token"])
        let local = FollowerAppEntry.instructions(for: .xDrip4iOS, address: "https://relay-mac.local:1337")
        #expect(local.fields == [
            .init(label: "URL", value: "https://relay-mac.local"),
            .init(label: "Token", value: FollowerAppEntry.tokenPlaceholder),
            .init(label: "Port", value: "1337"),
        ])
        #expect(local.steps.last(where: { $0.hasPrefix("In Port") }) == "In Port, enter 1337.")
    }

    @Test("xDrip+ introduces its one combined field with its own step, and the value to copy holds the address with the token in front")
    func xDripPlusInstructions() {
        let entry = FollowerAppEntry.instructions(for: .xDripPlus, address: "http://192.168.1.42:1337")
        #expect(entry.steps.count == 2)
        #expect(entry.steps[1].hasPrefix("Nightscout Follow URL takes the address and the token as one value."))
        #expect(entry.fields.map(\.label) == ["Nightscout Follow URL"])
        #expect(entry.fields[0].value(withToken: "synthetic-token") == "http://synthetic-token@192.168.1.42:1337")
        #expect(!entry.fields[0].value(withToken: "synthetic-token").contains(FollowerAppEntry.tokenPlaceholder))
        let local = FollowerAppEntry.instructions(for: .xDripPlus, address: "https://192.168.1.42:1337")
        #expect(local.fields[0].value(withToken: "synthetic-token") == "https://synthetic-token@192.168.1.42:1337")
    }

    @Test("LoopFollow names its token field Access Token and ends on its Status checkmark")
    func loopFollowInstructions() {
        let entry = FollowerAppEntry.instructions(for: .loopFollow, address: "http://192.168.1.42:1337")
        #expect(entry.fields.map(\.label) == ["URL", "Access Token"])
        #expect(entry.steps.last == "Check that Status shows a green checkmark.")
        let local = FollowerAppEntry.instructions(for: .loopFollow, address: "https://relay-mac.local:1337")
        #expect(local.fields == [
            .init(label: "URL", value: "https://relay-mac.local:1337"),
            .init(label: "Access Token", value: FollowerAppEntry.tokenPlaceholder),
        ])
    }

    @Test("Nightguard's token is its own API Token field and its Nightscout URL is the bare address")
    func nightguardInstructions() {
        let entry = FollowerAppEntry.instructions(for: .nightguard, address: "http://192.168.1.42:1337")
        #expect(entry.fields == [
            .init(label: "Nightscout URL", value: "http://192.168.1.42:1337"),
            .init(label: "API Token", value: FollowerAppEntry.tokenPlaceholder),
        ])
        #expect(!entry.fields[0].value.contains("?token="))
        #expect(!entry.fields[0].value.hasSuffix("/"))
        let local = FollowerAppEntry.instructions(for: .nightguard, address: "https://relay-mac.local:1337")
        #expect(local.fields[0] == .init(label: "Nightscout URL", value: "https://relay-mac.local:1337"))
    }

    @Test("every app's instructions carry the token only as the placeholder, never a real value")
    func instructionsHoldOnlyThePlaceholder() {
        for entry in FollowerAppEntry.pairingApps(address: "http://192.168.1.42:1337") {
            #expect(entry.fields.contains { $0.value.contains(FollowerAppEntry.tokenPlaceholder) }, Comment(rawValue: entry.name))
        }
        #expect(FollowerAppEntry.pairingApps(address: "https://h.example").map(\.name) == FollowerApp.allCases.map(\.displayName))
    }
}

