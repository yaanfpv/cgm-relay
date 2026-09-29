import Testing
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

    @Test("My local network reach binds every interface at the chosen port")
    func myLocalNetworkBindsEveryInterface() throws {
        var settings = AppSettings.default
        settings.port = 9999
        settings.reach = .myLocalNetwork

        let config = try SettingsEngineConfigurationBuilder.build(
            settings: settings,
            from: Self.store(),
            interfaces: [NetworkInterfaceAddress(name: "en0", address: "192.168.1.42")],
            statusAddr: "127.0.0.1:1338",
            databasePath: "/tmp/readings.db"
        )

        #expect(config?.listenAddr == "0.0.0.0:9999")
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
