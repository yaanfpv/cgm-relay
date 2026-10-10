import Foundation

/// EngineConfiguration is the JSON object the app writes to the engine's
/// standard input, per the `serve --config-stdin` contract: the engine
/// reads exactly one JSON value from stdin and never takes a secret as an
/// argument or an environment variable. The app keeps that same pipe open
/// for as long as the engine is supposed to run, so the engine's own
/// later EOF on it, however it happens, is the signal that the app is
/// gone. Decodable conformance exists only so a test can round-trip a
/// value for comparison; the app itself only ever encodes this type,
/// never decodes it, and the encoder's own key order is not guaranteed
/// stable across calls, so two encodings are compared as decoded values,
/// never as raw bytes.
public struct EngineConfiguration: Codable, Equatable, Sendable {
    public var librelinkupEmail: String
    public var librelinkupPassword: String
    /// token is the bearer token a Nightscout-compatible follower app
    /// presents to read from the engine.
    public var token: String
    public var listenAddr: String
    public var statusAddr: String
    public var databasePath: String
    public var retentionDays: Int
    /// key is the store's 32-byte encryption key, standard base64.
    public var key: String
    /// librelinkupBaseURL, when set, points sign-in and every fetch at
    /// something other than the official LibreLinkUp service: a
    /// development-only escape for driving the engine against a fake
    /// instead of a real account. nil is the ordinary case; the engine
    /// itself refuses anything but https, or plain http to a loopback
    /// address, at load time.
    public var librelinkupBaseURL: String?
    /// statusSecret is the LocalStatusSecret value of the engine process
    /// this configuration is written to, which the engine requires of every
    /// caller of its local status listener. nil leaves the engine without
    /// one, so it refuses to mint pairing codes.
    public var statusSecret: String?
    /// lanListenAddrs are the private host:port addresses the engine serves
    /// over TLS only, tlsCertPEM and tlsKeyPEM the certificate chain and key
    /// it presents there. All three are nil, and left out of the JSON, unless
    /// the local network route is on. The key travels here on stdin and is
    /// never written anywhere else.
    public var lanListenAddrs: [String]?
    public var tlsCertPEM: String?
    public var tlsKeyPEM: String?

    private enum CodingKeys: String, CodingKey {
        case librelinkupEmail = "librelinkup_email"
        case librelinkupPassword = "librelinkup_password"
        case token
        case listenAddr = "listen_addr"
        case statusAddr = "status_addr"
        case databasePath = "database_path"
        case retentionDays = "retention_days"
        case key
        case librelinkupBaseURL = "librelinkup_base_url"
        case statusSecret = "status_secret"
        case lanListenAddrs = "lan_listen_addrs"
        case tlsCertPEM = "tls_cert_pem"
        case tlsKeyPEM = "tls_key_pem"
    }

    public init(
        librelinkupEmail: String,
        librelinkupPassword: String,
        token: String,
        listenAddr: String,
        statusAddr: String,
        databasePath: String,
        retentionDays: Int,
        key: String,
        librelinkupBaseURL: String? = nil,
        statusSecret: String? = nil,
        lanListenAddrs: [String] = [],
        tlsCertPEM: String? = nil,
        tlsKeyPEM: String? = nil
    ) {
        self.librelinkupEmail = librelinkupEmail
        self.librelinkupPassword = librelinkupPassword
        self.token = token
        self.listenAddr = listenAddr
        self.statusAddr = statusAddr
        self.databasePath = databasePath
        self.retentionDays = retentionDays
        self.key = key
        self.librelinkupBaseURL = librelinkupBaseURL
        self.statusSecret = statusSecret
        self.lanListenAddrs = lanListenAddrs.isEmpty ? nil : lanListenAddrs
        self.tlsCertPEM = lanListenAddrs.isEmpty ? nil : tlsCertPEM
        self.tlsKeyPEM = lanListenAddrs.isEmpty ? nil : tlsKeyPEM
    }

    /// withStatusSecret returns this configuration carrying secret as its
    /// status secret, so every engine process can be given its own.
    public func withStatusSecret(_ secret: String?) -> EngineConfiguration {
        var copy = self
        copy.statusSecret = secret
        return copy
    }

    /// encodedForStandardInput renders the configuration as the single
    /// JSON value the engine expects on stdin.
    public func encodedForStandardInput() throws -> Data {
        try JSONEncoder().encode(self)
    }
}

/// EngineConfigurationBuilder assembles an EngineConfiguration from the
/// credentials store, or reports that the account is not configured yet.
public enum EngineConfigurationBuilder {
    /// build returns nil, rather than a configuration with empty strings,
    /// when the LibreLinkUp email or password is missing: the engine is
    /// never started without both, so a caller uses a nil result to show
    /// "Setup needed" instead of launching a process that cannot sign in.
    public static func build(
        from store: any CredentialStore,
        listenAddr: String,
        statusAddr: String,
        databasePath: String,
        retentionDays: Int,
        librelinkupBaseURL: String? = nil,
        lanListenAddrs: [String] = [],
        tlsCertPEM: String? = nil,
        tlsKeyPEM: String? = nil
    ) throws -> EngineConfiguration? {
        guard
            let email = try store.string(for: .librelinkupEmail), !email.isEmpty,
            let password = try store.string(for: .librelinkupPassword), !password.isEmpty,
            let token = try store.string(for: .token), !token.isEmpty,
            let key = try store.string(for: .storeKey), !key.isEmpty
        else {
            return nil
        }
        return EngineConfiguration(
            librelinkupEmail: email,
            librelinkupPassword: password,
            token: token,
            listenAddr: listenAddr,
            statusAddr: statusAddr,
            databasePath: databasePath,
            retentionDays: retentionDays,
            key: key,
            librelinkupBaseURL: librelinkupBaseURL,
            lanListenAddrs: lanListenAddrs,
            tlsCertPEM: tlsCertPEM,
            tlsKeyPEM: tlsKeyPEM
        )
    }
}
