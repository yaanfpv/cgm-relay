import Foundation

/// EngineStart is what an engine start needs from the settings: the
/// configuration to write to the engine's stdin, where it listens, and what
/// happened to the certificate authority while its certificate was made.
public struct EngineStart: Sendable {
    public let configuration: EngineConfiguration
    public let plan: EngineListenPlan
    /// authorityChange is nil when no certificate was made (every route but
    /// the local network).
    public let authorityChange: LocalCertificateMaterial.AuthorityChange?
}

/// SettingsEngineConfigurationBuilder is the one place AppSettings turns
/// into the engine's own EngineConfiguration: it resolves where the engine
/// listens for the settings' effective NetworkReach and combines the host
/// with the port into listenAddr, and passes retentionDays straight through.
/// On the local network route it also lists every private address as a TLS
/// listener and takes the certificate and key for them from the local
/// certificate authority. Every other field comes from
/// EngineConfigurationBuilder.build unchanged.
public enum SettingsEngineConfigurationBuilder {
    public static func build(
        settings: AppSettings,
        from store: any CredentialStore,
        interfaces: [NetworkInterfaceAddress],
        statusAddr: String,
        databasePath: String,
        librelinkupBaseURL: String? = nil,
        hostName: String = SystemNetworkInterfaces.localHostName()
    ) throws -> EngineConfiguration? {
        try start(
            settings: settings,
            from: store,
            interfaces: interfaces,
            statusAddr: statusAddr,
            databasePath: databasePath,
            librelinkupBaseURL: librelinkupBaseURL,
            hostName: hostName
        )?.configuration
    }

    /// start is build with the listen plan and the authority's change
    /// alongside, so the caller can restart onto a changed address set and
    /// ask the person for the certificate step again after a new authority.
    public static func start(
        settings: AppSettings,
        from store: any CredentialStore,
        interfaces: [NetworkInterfaceAddress],
        statusAddr: String,
        databasePath: String,
        librelinkupBaseURL: String? = nil,
        hostName: String = SystemNetworkInterfaces.localHostName()
    ) throws -> EngineStart? {
        let plan = EngineListenPlan.make(reach: settings.effectiveReach, interfaces: interfaces, hostName: hostName)
        let port = settings.port

        // The account check comes first, so no certificate is made (and no
        // change to the authority is reported) for a start that cannot happen.
        guard
            var configuration = try EngineConfigurationBuilder.build(
                from: store,
                listenAddr: "\(plan.host):\(port)",
                statusAddr: statusAddr,
                databasePath: databasePath,
                retentionDays: settings.retentionDays,
                librelinkupBaseURL: librelinkupBaseURL
            )
        else {
            return nil
        }

        var material: LocalCertificateMaterial?
        if let name = plan.hostName {
            let issued = try LocalCertificateAuthority(store: store).currentMaterial(name: name, ipv4s: plan.lanAddresses)
            configuration.lanListenAddrs = plan.lanAddresses.map { "\($0):\(port)" }
            configuration.tlsCertPEM = issued.serverCertificatePEM
            configuration.tlsKeyPEM = issued.serverKeyPEM
            material = issued
        }
        return EngineStart(configuration: configuration, plan: plan, authorityChange: material?.authorityChange)
    }
}
