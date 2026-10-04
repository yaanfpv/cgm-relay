import Foundation

/// LocalStatusSecret is the per-launch secret that proves a request to the
/// engine's local status listener comes from this app rather than from
/// another process or user on the same Mac. The app renews it for every
/// engine launch and hands it to the engine only in the stdin
/// configuration; the status reader and the pairing-code minter read the
/// current value for each request. It is held in memory only, never
/// written to disk, logs, diagnostics or the pasteboard.
public final class LocalStatusSecret: @unchecked Sendable {
    /// headerName is the request header the engine reads the secret from
    /// (internal/config's StatusSecretHeader; the two must always agree).
    public static let headerName = "X-CGM-Relay-Status-Secret"

    /// byteCount is the entropy of each secret, matching the bearer token.
    static let byteCount = 32

    private let randomBytes: any RandomBytesGenerating
    private let lock = NSLock()
    private var value: String?

    public init(randomBytes: any RandomBytesGenerating = SecureRandomBytesGenerator()) {
        self.randomBytes = randomBytes
    }

    /// current is the secret of the latest engine launch, nil until the
    /// first renew.
    public var current: String? {
        lock.withLock { value }
    }

    /// renew replaces the secret with a fresh one and returns it. The
    /// previous secret is discarded even when generating the new one fails,
    /// so a failed launch never leaves an old secret in use.
    @discardableResult
    public func renew() throws -> String {
        lock.withLock { value = nil }
        let fresh = try randomBytes.randomBytes(count: Self.byteCount).base64URLEncodedStringWithoutPadding()
        lock.withLock { value = fresh }
        return fresh
    }

    /// authorize adds the secret header to request when a secret exists.
    func authorize(_ request: inout URLRequest) {
        if let secret = current {
            request.setValue(secret, forHTTPHeaderField: Self.headerName)
        }
    }
}

/// LoopbackURLSession builds the session the app uses for its requests to
/// the engine's loopback listener: ephemeral, so nothing reaches disk, and
/// with no proxy, so a system proxy can never see these requests or the
/// secret they carry.
enum LoopbackURLSession {
    static func make(protocolClasses: [AnyClass]? = nil) -> URLSession {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.connectionProxyDictionary = [:]
        if let protocolClasses {
            configuration.protocolClasses = protocolClasses
        }
        return URLSession(configuration: configuration)
    }
}
