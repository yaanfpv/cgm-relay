import Testing
@testable import CGMRelayCore

@Suite("EngineConfigurationBuilder")
struct EngineConfigurationBuilderTests {
    @Test("builds a configuration once every credential is present")
    func buildsWhenComplete() throws {
        let store = FakeCredentialStore(values: [
            .librelinkupEmail: "person@example.invalid",
            .librelinkupPassword: "not-a-real-password",
            .token: "a-token",
            .storeKey: "a-key",
        ])

        let config = try EngineConfigurationBuilder.build(
            from: store,
            listenAddr: "127.0.0.1:1337",
            statusAddr: "127.0.0.1:1338",
            databasePath: "/tmp/readings.db",
            retentionDays: 15
        )

        #expect(config != nil)
        #expect(config?.librelinkupEmail == "person@example.invalid")
        #expect(config?.token == "a-token")
        #expect(config?.key == "a-key")
    }

    @Test("passes librelinkupBaseURL through when given, and leaves it nil when not")
    func passesLibrelinkupBaseURLThrough() throws {
        let store = FakeCredentialStore(values: [
            .librelinkupEmail: "person@example.invalid",
            .librelinkupPassword: "not-a-real-password",
            .token: "a-token",
            .storeKey: "a-key",
        ])

        let withoutOverride = try EngineConfigurationBuilder.build(
            from: store,
            listenAddr: "127.0.0.1:1337",
            statusAddr: "127.0.0.1:1338",
            databasePath: "/tmp/readings.db",
            retentionDays: 15
        )
        #expect(withoutOverride?.librelinkupBaseURL == nil)

        let withOverride = try EngineConfigurationBuilder.build(
            from: store,
            listenAddr: "127.0.0.1:1337",
            statusAddr: "127.0.0.1:1338",
            databasePath: "/tmp/readings.db",
            retentionDays: 15,
            librelinkupBaseURL: "http://127.0.0.1:9999"
        )
        #expect(withOverride?.librelinkupBaseURL == "http://127.0.0.1:9999")
    }

    @Test("refuses to build without an email or a password, which the engine is never started without")
    func nilWhenAccountMissing() throws {
        let store = FakeCredentialStore(values: [
            .token: "a-token",
            .storeKey: "a-key",
        ])

        let config = try EngineConfigurationBuilder.build(
            from: store,
            listenAddr: "127.0.0.1:1337",
            statusAddr: "127.0.0.1:1338",
            databasePath: "/tmp/readings.db",
            retentionDays: 15
        )

        #expect(config == nil)
    }

    @Test("refuses to build before the token and key have been generated")
    func nilBeforeBootstrapped() throws {
        let store = FakeCredentialStore(values: [
            .librelinkupEmail: "person@example.invalid",
            .librelinkupPassword: "not-a-real-password",
        ])

        let config = try EngineConfigurationBuilder.build(
            from: store,
            listenAddr: "127.0.0.1:1337",
            statusAddr: "127.0.0.1:1338",
            databasePath: "/tmp/readings.db",
            retentionDays: 15
        )

        #expect(config == nil)
    }
}
