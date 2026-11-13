import Foundation

/// SettingsEngineConfigurationBuilder is the one place AppSettings turns
/// into the engine's own EngineConfiguration: it resolves where the engine
/// listens for the settings' effective NetworkReach and combines the host
/// with the port into listenAddr, and passes retentionDays straight through.
/// Every other field comes from EngineConfigurationBuilder.build unchanged.
public enum SettingsEngineConfigurationBuilder {
    public static func build(
        settings: AppSettings,
        from store: any CredentialStore,
        interfaces: [NetworkInterfaceAddress],
        statusAddr: String,
        databasePath: String,
        librelinkupBaseURL: String? = nil
    ) throws -> EngineConfiguration? {
        let host = ReachAddressResolver.bindHost(for: settings.effectiveReach, interfaces: interfaces)
        return try EngineConfigurationBuilder.build(
            from: store,
            listenAddr: "\(host):\(settings.port)",
            statusAddr: statusAddr,
            databasePath: databasePath,
            retentionDays: settings.retentionDays,
            librelinkupBaseURL: librelinkupBaseURL
        )
    }
}
