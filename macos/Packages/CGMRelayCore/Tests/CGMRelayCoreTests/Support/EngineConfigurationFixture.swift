import CGMRelayCore

extension EngineConfiguration {
    static func fixture() -> EngineConfiguration {
        EngineConfiguration(
            librelinkupEmail: "person@example.invalid",
            librelinkupPassword: "not-a-real-password",
            token: "test-token",
            listenAddr: "127.0.0.1:0",
            statusAddr: "127.0.0.1:0",
            databasePath: "/tmp/cgm-relay-tests/readings.db",
            retentionDays: 15,
            key: "AAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAA="
        )
    }
}
