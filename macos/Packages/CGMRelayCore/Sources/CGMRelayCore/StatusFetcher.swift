import Foundation

/// StatusFetchError is raised when the status endpoint answers with
/// anything other than a decodable 200 response.
public enum StatusFetchError: Error, Sendable, Equatable {
    case unexpectedResponse
}

/// StatusFetcher retrieves the engine's current status. Production code
/// uses URLSessionStatusFetcher, pointed at the engine's local status
/// endpoint; tests use a fake that returns a scripted result.
public protocol StatusFetcher: Sendable {
    func fetchStatus() async throws -> EngineStatus
}

/// URLSessionStatusFetcher fetches `GET /status` from the engine's local
/// status endpoint, presenting the app's LocalStatusSecret, and decodes it.
public struct URLSessionStatusFetcher: StatusFetcher {
    private let statusURL: URL
    private let secret: LocalStatusSecret
    private let session: URLSession

    public init(statusURL: URL, secret: LocalStatusSecret, session: URLSession? = nil) {
        self.statusURL = statusURL
        self.secret = secret
        self.session = session ?? LoopbackURLSession.make()
    }

    public func fetchStatus() async throws -> EngineStatus {
        var request = URLRequest(url: statusURL)
        secret.authorize(&request)
        let (data, response) = try await session.data(for: request)
        guard let http = response as? HTTPURLResponse, http.statusCode == 200 else {
            throw StatusFetchError.unexpectedResponse
        }
        return try JSONDecoder.engineStatusDecoder.decode(EngineStatus.self, from: data)
    }
}
