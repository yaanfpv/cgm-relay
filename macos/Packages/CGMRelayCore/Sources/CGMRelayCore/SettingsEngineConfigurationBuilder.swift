import Foundation

/// SettingsEngineConfigurationBuilder is the one place AppSettings turns
/// into the engine's own EngineConfiguration: it resolves the bind host
/// for the settings' effective NetworkReach and combines it with the port
/// into listenAddr, and passes retentionDays straight through. Every
/// other field comes from EngineConfigurationBuilder.build unchanged.
public enum SettingsEngineConfigurationBuilder {
    public static func build(
        settings: AppSettings,
        from store: any CredentialStore,
        interfaces: [NetworkInterfaceAddress],
        statusAddr: String,
        databasePath: String,
        librelinkupBaseURL: String? = nil,
        statusSecret: String? = nil
    ) throws -> EngineConfiguration? {
        let bindHost = ReachAddressResolver.bindHost(for: settings.effectiveReach, interfaces: interfaces)
        return try EngineConfigurationBuilder.build(
            from: store,
            listenAddr: "\(bindHost):\(settings.port)",
            statusAddr: statusAddr,
            databasePath: databasePath,
            retentionDays: settings.retentionDays,
            librelinkupBaseURL: librelinkupBaseURL,
            statusSecret: statusSecret
        )
    }
}
