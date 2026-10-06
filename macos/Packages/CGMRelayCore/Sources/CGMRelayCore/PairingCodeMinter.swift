import Foundation

/// PairingCode is a short-lived code the engine accepts at
/// `/connect/<code>`, made by PairingCodeMinting.
public struct PairingCode: Equatable, Sendable {
    public let code: String
    public let expiresAt: Date

    public init(code: String, expiresAt: Date) {
        self.code = code
        self.expiresAt = expiresAt
    }
}

/// PairingCodeMintingError is raised when the engine does not answer a mint
/// request with a code, or when no request was made because the engine has
/// not yet reported that it is listening.
public enum PairingCodeMintingError: Error, Sendable, Equatable {
    case unexpectedResponse
    case notReady
}

/// PairingCodeMinting asks the running engine for a new pairing code, which
/// replaces any earlier one.
public protocol PairingCodeMinting: Sendable {
    /// mint asks for a code whose page shows apps, the instructions for
    /// every follower app for the address a phone opens.
    func mint(apps: [FollowerAppEntry.Instructions]) async throws -> PairingCode
}

/// URLSessionPairingCodeMinter posts to the engine's local status
/// endpoint, the one listener a phone cannot reach, presenting the app's
/// LocalStatusSecret, which the engine requires to mint. Nothing is sent
/// until the secret is armed.
public struct URLSessionPairingCodeMinter: PairingCodeMinting {
    private let pairingURL: URL
    private let secret: LocalStatusSecret
    private let session: URLSession

    public init(pairingURL: URL, secret: LocalStatusSecret, session: URLSession? = nil) {
        self.pairingURL = pairingURL
        self.secret = secret
        self.session = session ?? LoopbackURLSession.make()
    }

    private struct MintRequest: Encodable {
        let apps: [FollowerAppEntry.Instructions]
    }

    private struct Response: Decodable {
        let code: String
        let expiresAt: String

        enum CodingKeys: String, CodingKey {
            case code
            case expiresAt = "expires_at"
        }
    }

    public func mint(apps: [FollowerAppEntry.Instructions]) async throws -> PairingCode {
        var request = URLRequest(url: pairingURL)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.httpBody = try JSONEncoder().encode(MintRequest(apps: apps))
        guard secret.authorize(&request) else { throw PairingCodeMintingError.notReady }

        let (data, response) = try await session.data(for: request)
        guard
            let http = response as? HTTPURLResponse, http.statusCode == 200,
            let decoded = try? JSONDecoder().decode(Response.self, from: data),
            !decoded.code.isEmpty,
            let expiresAt = Self.parse(decoded.expiresAt)
        else {
            throw PairingCodeMintingError.unexpectedResponse
        }
        return PairingCode(code: decoded.code, expiresAt: expiresAt)
    }

    /// parse reads the engine's RFC 3339 time, which carries fractional
    /// seconds that a plain ISO8601DateFormatter rejects.
    static func parse(_ text: String) -> Date? {
        let withFraction = ISO8601DateFormatter()
        withFraction.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        if let date = withFraction.date(from: text) { return date }
        return ISO8601DateFormatter().date(from: text)
    }
}
