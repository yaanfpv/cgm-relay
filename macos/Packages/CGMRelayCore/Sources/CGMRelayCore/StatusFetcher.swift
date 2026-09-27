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
/// status endpoint and decodes it.
public struct URLSessionStatusFetcher: StatusFetcher {
    private let statusURL: URL
    private let session: URLSession

    public init(statusURL: URL, session: URLSession = .shared) {
        self.statusURL = statusURL
        self.session = session
    }

    public func fetchStatus() async throws -> EngineStatus {
        let (data, response) = try await session.data(from: statusURL)
        guard let http = response as? HTTPURLResponse, http.statusCode == 200 else {
            throw StatusFetchError.unexpectedResponse
        }
        return try JSONDecoder.engineStatusDecoder.decode(EngineStatus.self, from: data)
    }
}
