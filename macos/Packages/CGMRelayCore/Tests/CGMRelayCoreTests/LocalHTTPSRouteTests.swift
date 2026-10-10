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

    /// everyAddress collects each place a follower is shown an address on the
    /// local route: the Connect pane's state, every app's instructions (the
    /// Connect pane, setup step 3 and the engine's pairing page all render
    /// these), every QR payload and the xDrip+ combined value.
    static func everyAddress(_ route: LocalFollowerRoute) throws -> [(place: String, text: String)] {
        var found: [(String, String)] = []
        let state = ConnectPaneAddressState.decide(
            reach: .myLocalNetwork, boundHost: "b", impliedBindHost: "b", port: port,
            displayHostAvailability: .available(route.ipv4), localHostName: name
        )
        if case .ready(let address) = state { found.append(("connect pane", address)) }

        for app in FollowerApp.allCases {
            let address = route.address(for: app)
            found.append(("address for \(app)", address))
            let instructions = FollowerAppEntry.instructions(for: app, address: address)
            for field in instructions.fields where field.label != "Token" && field.label != "API Token" && field.label != "Access Token" {
                found.append(("\(app) field \(field.label)", field.value(withToken: token)))
            }
            for step in instructions.steps { found.append(("\(app) step", step)) }
            found.append(("\(app) caption", FollowerQRPlanner.caption(for: app)))
        }
        for page in FollowerAppEntry.pairingApps(addressFor: route.address(for:)) {
            for field in page.fields { found.append(("pairing page \(page.name) \(field.label)", field.value(withToken: token))) }
            for step in page.steps { found.append(("pairing page \(page.name) step", step)) }
        }

        for app in [FollowerApp.xDrip4iOS, .nightguard] {
            let qr = try #require(FollowerQRPlanner.qr(for: app, address: route.address(for: app), token: token, pairingCode: "CODE_abc-123"))
            found.append(("\(app) qr", qr.payload))
        }
        let plus = try #require(FollowerQRPlanner.qr(for: .xDripPlus, address: route.address(for: .xDripPlus), token: token, pairingCode: nil))
        var encoded = String(plus.payload.dropFirst(XDripPlusSettingsQR.marker.count))
        while encoded.count % 4 != 0 { encoded += "=" }
        let compressed = try #require(Data(base64Encoded: encoded))
        let inflated = try #require(ZlibStream.decompress(compressed))
        found.append(("xDrip+ qr", String(decoding: inflated, as: UTF8.self)))
        let loop = try #require(FollowerQRPlanner.qr(for: .loopFollow, address: route.address(for: .loopFollow), token: token, pairingCode: nil))
        found.append(("LoopFollow qr", loop.payload))
        return found
    }

    @Test("every address shown for the local route is https, never plain http, and carries the right host and port")
    func everyLocalAddressIsHTTPS() throws {
        let route = try Self.route(Self.first)
        let all = try Self.everyAddress(route)
        #expect(all.count > 20, "the sweep covers every surface")
        for (place, text) in all {
            #expect(!text.contains("http://"), "\(place) offers a plain http address: \(text)")
        }
        let hostsSeen = all.filter { $0.text.contains("https://") }
        #expect(!hostsSeen.isEmpty)
        for (place, text) in hostsSeen where !place.hasSuffix("xDrip+ qr") && !text.contains("apps.apple.com") {
            #expect(
                text.contains("https://\(Self.name):\(Self.port)") || text.contains("https://192.168.1.42:\(Self.port)") || text.contains("@192.168.1.42:\(Self.port)")
                    || text == "https://\(Self.name)" /* xDrip4iOS's URL field, its Port field is separate */,
                "\(place) names another host or port: \(text)"
            )
        }
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
        let plus = FollowerAppEntry.instructions(for: .xDripPlus, address: route.address(for: .xDripPlus))
        #expect(plus.fields[0].value(withToken: Self.token) == "https://\(Self.token)@192.168.1.42:1337")
        let xdrip = FollowerAppEntry.instructions(for: .xDrip4iOS, address: route.address(for: .xDrip4iOS))
        #expect(xdrip.fields.first { $0.label == "URL" }?.value == "https://relay-mac.local")
        #expect(xdrip.fields.first { $0.label == "Port" }?.value == "1337")
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
        for (place, text) in try Self.everyAddress(route) {
            #expect(!text.contains("192.168.1.42"), "\(place) still shows the old address: \(text)")
        }
        #expect(try Self.everyAddress(route).contains { $0.text.contains("192.168.50.9") })
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
