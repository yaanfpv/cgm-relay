import Foundation

/// LocalStatusSecret is the secret that proves a request to the engine's
/// local status listener comes from this app rather than from another
/// process or user on the same Mac. Each engine process gets its own: the
/// supervisor renews it for every spawn and hands it to the engine only in
/// the stdin configuration. It is held in memory only, never written to
/// disk, logs, diagnostics or the pasteboard.
///
/// A new secret is only pending. Whatever answers on the status port before
/// the engine reports that it is listening could be another process, so the
/// header is attached only once the supervisor has armed the secret.
public final class LocalStatusSecret: @unchecked Sendable {
    /// headerName is the request header the engine reads the secret from
    /// (internal/config's StatusSecretHeader; the two must always agree).
    public static let headerName = "X-CGM-Relay-Status-Secret"

    /// byteCount is the entropy of each secret, matching the bearer token.
    static let byteCount = 32

    private enum State {
        case none
        case pending(String)
        case armed(String)
    }

    private let randomBytes: any RandomBytesGenerating
    private let lock = NSLock()
    private var state = State.none

    public init(randomBytes: any RandomBytesGenerating = SecureRandomBytesGenerator()) {
        self.randomBytes = randomBytes
    }

    /// isArmed is true only while the engine process this secret was made
    /// for has reported that it is listening.
    public var isArmed: Bool {
        lock.withLock {
            if case .armed = state { return true }
            return false
        }
    }

    /// renew replaces whatever secret exists with a fresh pending one and
    /// returns it. The previous secret is discarded even when generating the
    /// new one fails, so a failed launch never leaves an old secret in use.
    @discardableResult
    public func renew() throws -> String {
        clear()
        let fresh = try randomBytes.randomBytes(count: Self.byteCount).base64URLEncodedStringWithoutPadding()
        lock.withLock { state = .pending(fresh) }
        return fresh
    }

    /// arm makes the pending secret usable, but only when it is secret
    /// itself: a report from an engine process that has since been
    /// replaced names an older secret and arms nothing.
    public func arm(_ secret: String) {
        lock.withLock {
            if case .pending(let pending) = state, pending == secret {
                state = .armed(secret)
            }
        }
    }

    /// clear forgets the secret, so nothing is presented until the next
    /// engine process has been renewed and armed.
    public func clear() {
        lock.withLock { state = .none }
    }

    /// authorize adds the secret header to request and returns true, or
    /// returns false and leaves request untouched when no secret is armed.
    func authorize(_ request: inout URLRequest) -> Bool {
        let secret: String? = lock.withLock {
            if case .armed(let value) = state { return value }
            return nil
        }
        guard let secret else { return false }
        request.setValue(secret, forHTTPHeaderField: Self.headerName)
        return true
    }
}

/// LoopbackURLSession builds the session the app uses for its requests to
/// the engine's loopback listener: ephemeral, so nothing reaches disk, with
/// no proxy, so a system proxy can never see these requests or the secret
/// they carry, and refusing every redirect, so the secret never reaches a
/// second endpoint.
enum LoopbackURLSession {
    static func make(protocolClasses: [AnyClass]? = nil) -> URLSession {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.connectionProxyDictionary = [:]
        if let protocolClasses {
            configuration.protocolClasses = protocolClasses
        }
        return URLSession(configuration: configuration, delegate: RedirectRefuser(), delegateQueue: nil)
    }

    private final class RedirectRefuser: NSObject, URLSessionTaskDelegate, @unchecked Sendable {
        func urlSession(
            _ session: URLSession,
            task: URLSessionTask,
            willPerformHTTPRedirection response: HTTPURLResponse,
            newRequest request: URLRequest,
            completionHandler: @escaping @Sendable (URLRequest?) -> Void
        ) {
            completionHandler(nil)
        }
    }
}
