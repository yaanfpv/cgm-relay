import Foundation

/// BuiltInAddressRetrying asks the running engine to test the built-in
/// address now and take the next repair step if the test fails.
public protocol BuiltInAddressRetrying: Sendable {
    func tryAgain() async throws
}

/// URLSessionBuiltInAddressRetrier posts to the engine's local status
/// endpoint with the app's LocalStatusSecret, the way the pairing code is
/// minted. Nothing is sent until the secret is armed.
public struct URLSessionBuiltInAddressRetrier: BuiltInAddressRetrying {
    private let url: URL
    private let secret: LocalStatusSecret
    private let session: URLSession

    public init(url: URL, secret: LocalStatusSecret, session: URLSession? = nil) {
        self.url = url
        self.secret = secret
        self.session = session ?? LoopbackURLSession.make()
    }

    public func tryAgain() async throws {
        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        guard secret.authorize(&request) else { throw PairingCodeMintingError.notReady }
        let (_, response) = try await session.data(for: request)
        guard let http = response as? HTTPURLResponse, http.statusCode == 204 else {
            throw PairingCodeMintingError.unexpectedResponse
        }
    }
}

/// BuiltInSignInStarting asks the running engine to start the built-in
/// node's Tailscale sign-in while it keeps running. The page to open is then
/// in the engine's status.
public protocol BuiltInSignInStarting: Sendable {
    func startSignIn() async throws
}

/// URLSessionBuiltInSignInStarter posts to the engine's local status
/// endpoint with the app's LocalStatusSecret.
public struct URLSessionBuiltInSignInStarter: BuiltInSignInStarting {
    private let poster: URLSessionBuiltInAddressRetrier

    public init(url: URL, secret: LocalStatusSecret, session: URLSession? = nil) {
        poster = URLSessionBuiltInAddressRetrier(url: url, secret: secret, session: session)
    }

    public func startSignIn() async throws {
        try await poster.tryAgain()
    }
}

/// BuiltInRouteLeaving asks the running engine to log the built-in node out of
/// the person's Tailscale account and remove its state folder, and waits for
/// the answer.
public protocol BuiltInRouteLeaving: Sendable {
    func leave() async -> LeaveTailnetOutcome
}

/// URLSessionBuiltInRouteLeaver posts to the engine's local status endpoint
/// with the app's LocalStatusSecret. Anything but the engine's answer that the
/// node left (an engine that is not running, a refusal, no answer within its
/// own time) reads as not yet removed, so the folder and key are kept.
public struct URLSessionBuiltInRouteLeaver: BuiltInRouteLeaving {
    /// timeout is longer than the engine's own limit on a logout, so the engine
    /// is the one that gives up.
    public static let timeout: TimeInterval = 30

    private let url: URL
    private let secret: LocalStatusSecret
    private let session: URLSession

    public init(url: URL, secret: LocalStatusSecret, session: URLSession? = nil) {
        self.url = url
        self.secret = secret
        self.session = session ?? LoopbackURLSession.make()
    }

    public func leave() async -> LeaveTailnetOutcome {
        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.timeoutInterval = Self.timeout
        guard secret.authorize(&request) else { return .notYetRemoved }
        guard let (_, response) = try? await session.data(for: request),
              let http = response as? HTTPURLResponse, http.statusCode == 204 else {
            return .notYetRemoved
        }
        return .removed
    }
}
