import Foundation
import Testing
@testable import CGMRelayCore

@Suite("Local network https route")
struct LocalHTTPSRouteTests {
    static let token = "synthetic-token-abc"
    static let name = "relay-mac.local"
    static let port = 1337
    static let first = [
        NetworkInterfaceAddress(name: "en0", address: "192.168.1.42"),
        NetworkInterfaceAddress(name: "utun4", address: "100.101.102.5"),
    ]
    static let moved = [
        NetworkInterfaceAddress(name: "en0", address: "192.168.50.9"),
    ]

    /// route is what the app builds from the interfaces it can see, the way
    /// AppModel does: the listen plan decides the addresses, the first private
    /// one on the default route is the address given to an app that takes one.
    static func route(_ interfaces: [NetworkInterfaceAddress]) throws -> LocalFollowerRoute {
        let ipv4 = try #require(ReachAddressResolver.primaryPrivateLANIPv4(among: interfaces, primaryInterfaceName: "en0"))
        return LocalFollowerRoute(hostName: name, ipv4: ipv4, port: port)
    }

    /// Expected is what one app is shown for the route: its address, every
    /// field it asks for (label and value, the token filled in), the steps
    /// that name a host or port, and the links on its page.
    struct Expected {
        let address: String
        let fields: [String]
        let addressSteps: [String]
        let links: [String]
    }

    static func expected(ip: String) -> [FollowerApp: Expected] {
        let nameAddress = "https://\(name):\(port)"
        return [
            .xDrip4iOS: Expected(
                address: nameAddress,
                fields: ["URL=https://\(name)", "Token=\(token)", "Port=\(port)"],
                addressSteps: ["In Port, enter \(port)."],
                links: ["xdripswift://open"]
            ),
            .xDripPlus: Expected(
                address: "https://\(ip):\(port)",
                fields: ["Nightscout Follow URL=https://\(token)@\(ip):\(port)"],
                addressSteps: [],
                links: []
            ),
            .loopFollow: Expected(
                address: nameAddress,
                fields: ["URL=\(nameAddress)", "Access Token=\(token)"],
                addressSteps: [],
                links: []
            ),
            .nightguard: Expected(
                address: nameAddress,
                fields: ["Nightscout URL=\(nameAddress)", "API Token=\(token)"],
                addressSteps: [],
                links: ["https://apps.apple.com/us/app/nightguard/id1116430352"]
            ),
        ]
    }

    /// namesAHostOrPort is whether a sentence says where the relay is.
    static func namesAHostOrPort(_ text: String, ip: String) -> Bool {
        text.contains("://") || text.contains("@") || text.contains(".local") || text.contains(ip) || text.contains(String(port))
    }

    /// checkOutputs holds the route's helpers composed (the Connect pane
    /// state, each app's instructions, the pairing page's apps, each QR
    /// payload) to the exact value each should show for a Mac whose private
    /// address is ip. It proves the pieces agree with each other on the
    /// route. The wording and the format of each output are held by that
    /// output's own tests.
    static func checkOutputs(_ route: LocalFollowerRoute, ip: String) throws {
        let want = expected(ip: ip)
        let state = ConnectPaneAddressState.decide(
            reach: .myLocalNetwork, boundHost: "b", impliedBindHost: "b", port: port,
            displayHostAvailability: .available(route.ipv4), localHostName: name
        )
        #expect(state == .ready(address: "https://\(name):\(port)"))

        var pages = FollowerAppEntry.pairingApps(addressFor: route.address(for:))
        #expect(pages.map(\.name) == FollowerApp.allCases.map(\.displayName))
        for app in FollowerApp.allCases {
            let w = try #require(want[app])
            let address = route.address(for: app)
            #expect(address == w.address, "\(app) is given another address")
            let shown = [FollowerAppEntry.instructions(for: app, address: address), pages.removeFirst()]
            for entry in shown {
                #expect(entry.fields.map { "\($0.label)=\($0.value(withToken: token))" } == w.fields, "\(app) fields")
                #expect(entry.steps.filter { namesAHostOrPort($0, ip: ip) } == w.addressSteps, "\(app) steps")
                #expect(entry.links.map(\.url) == w.links, "\(app) links")
            }
            #expect(!namesAHostOrPort(FollowerQRPlanner.caption(for: app), ip: ip), "\(app) caption names a host")
        }

        for app in [FollowerApp.xDrip4iOS, .nightguard] {
            let qr = try #require(FollowerQRPlanner.qr(for: app, address: route.address(for: app), token: token, pairingCode: "CODE_abc-123"))
            #expect(qr.payload == "https://\(name):\(port)/connect/CODE_abc-123", "\(app) qr")
        }

        let plus = try #require(FollowerQRPlanner.qr(for: .xDripPlus, address: route.address(for: .xDripPlus), token: token, pairingCode: nil))
        var encoded = String(plus.payload.dropFirst(XDripPlusSettingsQR.marker.count))
        while encoded.count % 4 != 0 { encoded += "=" }
        let compressed = try #require(Data(base64Encoded: encoded))
        let inflated = try #require(ZlibStream.decompress(compressed))
        let preferences = try #require(JSONSerialization.jsonObject(with: inflated) as? [String: String])
        #expect(preferences == ["dex_collection_method": "NSFollower", "nsfollow_url": "https://\(token)@\(ip):\(port)"], "xDrip+ qr")

        let loop = try #require(FollowerQRPlanner.qr(for: .loopFollow, address: route.address(for: .loopFollow), token: token, pairingCode: nil))
        let settings = try #require(JSONSerialization.jsonObject(with: Data(loop.payload.utf8)) as? [String: Any])
        let nightscout = try #require(settings["nightscout"] as? [String: String])
        #expect(nightscout["url"] == "https://\(name):\(port)", "LoopFollow qr")
        #expect(nightscout["token"] == token)
    }

    @Test("the route's helpers, composed, give each app its exact https address in every output it shows")
    func everyLocalOutputCarriesItsExactAddress() throws {
        try Self.checkOutputs(try Self.route(Self.first), ip: "192.168.1.42")
    }

    @Test("an app that takes an address is given the private address, and the rest are given the .local name")
    func addressFormPerApp() throws {
        let route = try Self.route(Self.first)
        #expect(route.nameAddress == "https://relay-mac.local:1337")
        #expect(route.ipAddress == "https://192.168.1.42:1337")
        #expect(route.address(for: .xDripPlus) == route.ipAddress)
        for app in [FollowerApp.xDrip4iOS, .loopFollow, .nightguard] {
            #expect(route.address(for: app) == route.nameAddress)
        }
    }

    @Test("after the IP set changes, the addresses and the listen plan follow the new set")
    func addressesFollowAnIPChange() throws {
        let before = EngineListenPlan.make(reach: .myLocalNetwork, interfaces: Self.first, hostName: Self.name)
        let after = EngineListenPlan.make(reach: .myLocalNetwork, interfaces: Self.moved, hostName: Self.name)
        #expect(before.lanAddresses == ["192.168.1.42"])
        #expect(after.lanAddresses == ["192.168.50.9"])
        #expect(before.identity != after.identity)

        let route = try Self.route(Self.moved)
        #expect(route.ipAddress == "https://192.168.50.9:1337")
        try Self.checkOutputs(route, ip: "192.168.50.9")
    }

    @Test("the listen identity changes with the name or the address set and is the bare host on every other route")
    func listenIdentity() {
        let a = EngineListenPlan.make(reach: .myLocalNetwork, interfaces: Self.first, hostName: "a.local")
        let b = EngineListenPlan.make(reach: .myLocalNetwork, interfaces: Self.first, hostName: "b.local")
        #expect(a.identity != b.identity)
        #expect(a.host == "127.0.0.1")
        #expect(EngineListenPlan.make(reach: .thisMacOnly, interfaces: Self.first, hostName: "a.local").identity == "127.0.0.1")
        #expect(EngineListenPlan.make(reach: .myTailnet, interfaces: Self.first, hostName: "a.local").identity == "100.101.102.5")
        let none = EngineListenPlan.make(reach: .myLocalNetwork, interfaces: [], hostName: "a.local")
        #expect(!none.servesLocalNetwork && none.hostName == nil && none.identity == "127.0.0.1")
    }

    @Test(
        "a system name becomes a valid .local name",
        arguments: [
            ("Alex-MacBook-Pro", "alex-macbook-pro.local"),
            ("Alex-MacBook-Pro.local", "alex-macbook-pro.local"),
            ("  Relay Mac  ", "relay-mac.local"),
            ("host.example.com", "host.local"),
            ("Alex's Mac", "alex-s-mac.local"),
            ("---", nil),
            ("", nil),
        ] as [(String, String?)]
    )
    func mdnsName(_ testCase: (raw: String, want: String?)) {
        #expect(LocalHostName.mdnsName(from: testCase.raw) == testCase.want)
        if let want = testCase.want {
            #expect((try? LocalCertificateAuthority.normalizedName(want)) == want, "the certificate accepts it")
        }
    }

    @Test("the certificate step is asked for only on the local network route, and ends when it is finished")
    func certificateStepNeeded() {
        var settings = AppSettings.default
        #expect(!settings.needsCertificateStep, "This Mac only")
        settings.reach = .myTailnet
        #expect(!settings.needsCertificateStep, "My tailnet")
        settings.reach = .myLocalNetwork
        #expect(settings.needsCertificateStep)
        settings.tailscaleHTTPSEnabled = true
        #expect(!settings.needsCertificateStep, "Tailscale HTTPS binds this Mac only")
        settings.tailscaleHTTPSEnabled = false
        settings.localCertificateStepFinished = true
        #expect(!settings.needsCertificateStep)
    }

    @Test("a replaced authority clears the finished step and says why, a new one clears it quietly, an unchanged one leaves it")
    func authorityChangeClearsTheStep() {
        var settings = AppSettings.default
        settings.localCertificateStepFinished = true
        #expect(settings.noteAuthorityChange(.unchanged) == nil)
        #expect(settings.localCertificateStepFinished)

        #expect(settings.noteAuthorityChange(.replaced) == "This Mac's name changed, so each phone needs the HTTPS step again.")
        #expect(!settings.localCertificateStepFinished)

        #expect(settings.noteAuthorityChange(.replaced) == nil, "nothing was finished, so there is nothing to say")

        settings.localCertificateStepFinished = true
        #expect(settings.noteAuthorityChange(.created) == nil)
        #expect(!settings.localCertificateStepFinished)
    }

    @Test("the sentence about a replaced authority is the menu's detail line, and never replaces a failure's own detail")
    func menuDetailLine() {
        let now = Date(timeIntervalSince1970: 1_800_000_000)
        let notice = AppSettings.authorityReplacedNotice
        let running = MenuDisplayState.make(
            credentialsConfigured: true, engineState: .running,
            status: EngineStatus(running: true, lastReadingTime: now, lastReadingMgDl: 120), now: now, certificateNotice: notice
        )
        #expect(running.statusDetail == notice)
        let signInFailing = MenuDisplayState.make(
            credentialsConfigured: true, engineState: .running,
            status: EngineStatus(running: true, lastReadingTime: now, lastReadingMgDl: 120, signInFailing: true), now: now, certificateNotice: notice
        )
        #expect(signInFailing.statusDetail == "Check your LibreLinkUp email and password in Settings.")
        let none = MenuDisplayState.make(credentialsConfigured: true, engineState: .stopped, status: nil, now: now)
        #expect(none.statusDetail == nil)
    }
}
