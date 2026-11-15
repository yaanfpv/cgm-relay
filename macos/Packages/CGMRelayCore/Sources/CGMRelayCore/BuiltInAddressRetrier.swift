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
