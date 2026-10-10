import Crypto
import Foundation
import SwiftASN1
import Testing
import X509
@testable import CGMRelayCore

@Suite("SettingsEngineConfigurationBuilder")
struct SettingsEngineConfigurationBuilderTests {
    static func store() -> FakeCredentialStore {
        FakeCredentialStore(values: [
            .librelinkupEmail: "person@example.invalid",
            .librelinkupPassword: "not-a-real-password",
            .token: "a-token",
            .storeKey: "a-key",
        ])
    }

    @Test("port and This Mac only reach reach the engine's listen_addr")
    func portAndThisMacOnlyReachListenAddr() throws {
        var settings = AppSettings.default
        settings.port = 5555
        settings.reach = .thisMacOnly

        let config = try SettingsEngineConfigurationBuilder.build(
            settings: settings,
            from: Self.store(),
            interfaces: [],
            statusAddr: "127.0.0.1:1338",
            databasePath: "/tmp/readings.db"
        )

        #expect(config?.listenAddr == "127.0.0.1:5555")
    }

    static let lan = [
        NetworkInterfaceAddress(name: "en0", address: "192.168.1.42"),
        NetworkInterfaceAddress(name: "en1", address: "10.0.0.7"),
        NetworkInterfaceAddress(name: "utun4", address: "100.101.102.5"),
    ]

    private func localReach(port: Int = 9999) -> AppSettings {
        var settings = AppSettings.default
        settings.port = port
        settings.reach = .myLocalNetwork
        return settings
    }

    @Test("My local network keeps the plain listener on loopback and serves every private address over TLS at the chosen port")
    func myLocalNetworkListensOnLoopbackAndEveryPrivateAddress() throws {
        let config = try #require(try SettingsEngineConfigurationBuilder.build(
            settings: localReach(),
            from: Self.store(),
            interfaces: Self.lan,
            statusAddr: "127.0.0.1:1338",
            databasePath: "/tmp/readings.db",
            hostName: "relay-mac.local"
        ))

        #expect(config.listenAddr == "127.0.0.1:9999")
        #expect(config.lanListenAddrs == ["10.0.0.7:9999", "192.168.1.42:9999"], "the Tailscale address is not a local network address")

        let sent = try #require(JSONSerialization.jsonObject(with: config.encodedForStandardInput()) as? [String: Any])
        #expect(sent["listen_addr"] as? String == "127.0.0.1:9999")
        #expect(sent["lan_listen_addrs"] as? [String] == ["10.0.0.7:9999", "192.168.1.42:9999"])
    }

    @Test("the certificate and key sent for the local network are a matching pair that names this Mac and every listening address")
    func localNetworkCertificateMatchesItsKeyAndNames() throws {
        let config = try #require(try SettingsEngineConfigurationBuilder.build(
            settings: localReach(),
            from: Self.store(),
            interfaces: Self.lan,
            statusAddr: "127.0.0.1:1338",
            databasePath: "/tmp/readings.db",
            hostName: "relay-mac.local"
        ))

        let certificate = try Certificate(pemEncoded: try #require(config.tlsCertPEM))
        let key = try P256.Signing.PrivateKey(pemRepresentation: try #require(config.tlsKeyPEM))
        #expect(certificate.publicKey == Certificate.PublicKey(key.publicKey))
        let names = try #require(try certificate.extensions.subjectAlternativeNames)
        #expect(Set(names) == Set(LocalCertificateAuthority.serverNames(host: "relay-mac.local", addresses: ["10.0.0.7", "192.168.1.42"])))
    }

    @Test("a changed address set on the local network route is a new listen plan and a certificate for the new set")
    func changedAddressSetReissuesTheCertificate() throws {
        let store = Self.store()
        let first = try #require(try SettingsEngineConfigurationBuilder.start(
            settings: localReach(), from: store, interfaces: Self.lan, statusAddr: "127.0.0.1:1338",
            databasePath: "/tmp/readings.db", hostName: "relay-mac.local"
        ))
        let moved = [NetworkInterfaceAddress(name: "en0", address: "192.168.50.9")]
        let second = try #require(try SettingsEngineConfigurationBuilder.start(
            settings: localReach(), from: store, interfaces: moved, statusAddr: "127.0.0.1:1338",
            databasePath: "/tmp/readings.db", hostName: "relay-mac.local"
        ))

        #expect(first.plan.identity != second.plan.identity, "the engine restarts onto the new address set")
        #expect(second.configuration.lanListenAddrs == ["192.168.50.9:9999"])
        #expect(first.configuration.tlsCertPEM != second.configuration.tlsCertPEM)
        #expect(first.authorityChange == .created)
        #expect(second.authorityChange == .unchanged, "phones keep trusting the same authority")
        #expect(first.configuration.tlsKeyPEM != second.configuration.tlsKeyPEM)
    }

    @Test("a renamed Mac replaces the authority, and the start says so")
    func renamedMacReplacesTheAuthority() throws {
        let store = Self.store()
        _ = try SettingsEngineConfigurationBuilder.start(
            settings: localReach(), from: store, interfaces: Self.lan, statusAddr: "127.0.0.1:1338",
            databasePath: "/tmp/readings.db", hostName: "relay-mac.local"
        )
        let renamed = try #require(try SettingsEngineConfigurationBuilder.start(
            settings: localReach(), from: store, interfaces: Self.lan, statusAddr: "127.0.0.1:1338",
            databasePath: "/tmp/readings.db", hostName: "new-name.local"
        ))
        #expect(renamed.authorityChange == .replaced)
    }

    @Test("This Mac only and My tailnet send no LAN listener, no certificate and no key, and do no certificate work")
    func otherReachesCarryNoCertificate() throws {
        for reach in [NetworkReach.thisMacOnly, .myTailnet] {
            var settings = AppSettings.default
            settings.reach = reach
            let store = Self.store()
            let start = try #require(try SettingsEngineConfigurationBuilder.start(
                settings: settings, from: store, interfaces: Self.lan, statusAddr: "127.0.0.1:1338",
                databasePath: "/tmp/readings.db", hostName: "relay-mac.local"
            ))
            #expect(start.configuration.lanListenAddrs == nil && start.configuration.tlsCertPEM == nil && start.configuration.tlsKeyPEM == nil)
            #expect(start.authorityChange == nil)
            #expect(store.snapshot()[.authorityKey] == nil && store.snapshot()[.serverKey] == nil, "nothing was made for \(reach)")
            let sent = try #require(JSONSerialization.jsonObject(with: start.configuration.encodedForStandardInput()) as? [String: Any])
            #expect(sent["lan_listen_addrs"] == nil && sent["tls_cert_pem"] == nil && sent["tls_key_pem"] == nil)
        }
    }

    @Test("Tailscale HTTPS keeps the relay on loopback with no certificate, whatever reach was chosen before it")
    func tailscaleHTTPSBuildsNoCertificate() throws {
        var settings = localReach()
        settings.tailscaleHTTPSEnabled = true
        let start = try #require(try SettingsEngineConfigurationBuilder.start(
            settings: settings, from: Self.store(), interfaces: Self.lan, statusAddr: "127.0.0.1:1338",
            databasePath: "/tmp/readings.db", hostName: "relay-mac.local"
        ))
        #expect(start.configuration.listenAddr == "127.0.0.1:9999")
        #expect(start.configuration.lanListenAddrs == nil)
        #expect(start.authorityChange == nil)
    }

    @Test("a start that cannot happen yet makes no certificate on the local network route")
    func noAccountNoCertificate() throws {
        let store = FakeCredentialStore()
        let start = try SettingsEngineConfigurationBuilder.start(
            settings: localReach(), from: store, interfaces: Self.lan, statusAddr: "127.0.0.1:1338",
            databasePath: "/tmp/readings.db", hostName: "relay-mac.local"
        )
        #expect(start == nil)
        #expect(store.snapshot().isEmpty)
    }

    @Test("the local network route with no private address starts loopback only and makes no certificate")
    func noPrivateAddressNoCertificate() throws {
        let start = try #require(try SettingsEngineConfigurationBuilder.start(
            settings: localReach(), from: Self.store(),
            interfaces: [NetworkInterfaceAddress(name: "utun4", address: "100.101.102.5")], statusAddr: "127.0.0.1:1338",
            databasePath: "/tmp/readings.db", hostName: "relay-mac.local"
        ))
        #expect(start.configuration.listenAddr == "127.0.0.1:9999")
        #expect(start.configuration.lanListenAddrs == nil && start.configuration.tlsKeyPEM == nil)
        #expect(start.authorityChange == nil)
    }

    @Test("My tailnet reach binds the discovered Tailscale address")
    func myTailnetBindsTheTailscaleAddress() throws {
        var settings = AppSettings.default
        settings.port = 1337
        settings.reach = .myTailnet

        let config = try SettingsEngineConfigurationBuilder.build(
            settings: settings,
            from: Self.store(),
            interfaces: [NetworkInterfaceAddress(name: "utun4", address: "100.101.102.5")],
            statusAddr: "127.0.0.1:1338",
            databasePath: "/tmp/readings.db"
        )

        #expect(config?.listenAddr == "100.101.102.5:1337")
    }

    @Test("never-saved settings hand the engine the build's default pair")
    func defaultSettingsReachTheEngineAsTheDefaultPair() throws {
        let config = try SettingsEngineConfigurationBuilder.build(
            settings: .default,
            from: Self.store(),
            interfaces: [],
            statusAddr: RelayDefaults.statusAddr,
            databasePath: "/tmp/readings.db"
        )

        #if DEBUG
        #expect(config?.listenAddr == "127.0.0.1:1347")
        #expect(config?.statusAddr == "127.0.0.1:1348")
        #else
        #expect(config?.listenAddr == "127.0.0.1:1337")
        #expect(config?.statusAddr == "127.0.0.1:1338")
        #endif
    }

    @Test("retentionDays reaches the engine's retention_days")
    func retentionDaysReachesRetentionDays() throws {
        var settings = AppSettings.default
        settings.retentionDays = 42

        let config = try SettingsEngineConfigurationBuilder.build(
            settings: settings,
            from: Self.store(),
            interfaces: [],
            statusAddr: "127.0.0.1:1338",
            databasePath: "/tmp/readings.db"
        )

        #expect(config?.retentionDays == 42)
    }

    @Test("no configuration is built while the account is not yet configured, exactly as the plain builder")
    func nilWhenAccountMissing() throws {
        let config = try SettingsEngineConfigurationBuilder.build(
            settings: .default,
            from: FakeCredentialStore(),
            interfaces: [],
            statusAddr: "127.0.0.1:1338",
            databasePath: "/tmp/readings.db"
        )
        #expect(config == nil)
    }
}
