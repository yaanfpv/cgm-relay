import Foundation

/// EngineStatus mirrors the JSON body the engine's local status endpoint
/// (`GET /status`) reports. It is the one shape the menu bar app decodes
/// that response into; every display decision downstream reads from it
/// rather than from the raw JSON again.
public struct EngineStatus: Decodable, Equatable, Sendable {
    /// Running is always true in a decoded response: reaching the
    /// endpoint at all means the engine that serves it is up. The app
    /// still carries it because the field exists on the wire, but display
    /// logic uses its own knowledge of whether the engine process is
    /// running, not this field.
    public var running: Bool
    public var lastFetchTime: Date?
    public var lastReadingTime: Date?
    /// lastReadingMgDl is nil both when the engine has never fetched a
    /// reading and when the one it has happens to encode as the JSON
    /// field's zero value, since the engine's own `omitempty` tag cannot
    /// tell those two cases apart on the wire.
    public var lastReadingMgDl: Int?
    /// lastReadingTrend is the Nightscout direction name of the last
    /// reading ("Flat", "FortyFiveUp", ...); nil when the device computed
    /// none or the engine is older than the field.
    public var lastReadingTrend: String?
    public var signInFailing: Bool
    public var lastError: String?
    /// clients maps each follower app's User-Agent to the last time it
    /// made an authenticated request to the Nightscout API.
    public var clients: [String: Date]?
    /// lanReadingClients maps the User-Agent of each app that was handed at
    /// least one reading over the engine's encrypted local-network address
    /// to the time of its latest such request. It is nil when none has been,
    /// and when the engine is older than the field.
    public var lanReadingClients: [String: Date]?

    private enum CodingKeys: String, CodingKey {
        case running
        case lastFetchTime = "last_fetch_time"
        case lastReadingTime = "last_reading_time"
        case lastReadingMgDl = "last_reading_mg_dl"
        case lastReadingTrend = "last_reading_trend"
        case signInFailing = "sign_in_failing"
        case lastError = "last_error"
        case clients
        case lanReadingClients = "lan_reading_clients"
    }

    public init(
        running: Bool,
        lastFetchTime: Date? = nil,
        lastReadingTime: Date? = nil,
        lastReadingMgDl: Int? = nil,
        lastReadingTrend: String? = nil,
        signInFailing: Bool = false,
        lastError: String? = nil,
        clients: [String: Date]? = nil,
        lanReadingClients: [String: Date]? = nil
    ) {
        self.running = running
        self.lastFetchTime = lastFetchTime
        self.lastReadingTime = lastReadingTime
        self.lastReadingMgDl = lastReadingMgDl
        self.lastReadingTrend = lastReadingTrend
        self.signInFailing = signInFailing
        self.lastError = lastError
        self.clients = clients
        self.lanReadingClients = lanReadingClients
    }

    /// The most recent request that fetched readings over the encrypted
    /// local-network address at or after `since`, or nil when there is none.
    public func lanReadingFetch(since: Date) -> (userAgent: String, at: Date)? {
        guard let latest = lanReadingClients?.filter({ $0.value >= since }).max(by: { $0.value < $1.value }) else {
            return nil
        }
        return (userAgent: latest.key, at: latest.value)
    }
}

/// A JSON decoder configured to read the engine's status responses. Go's
/// default `time.Time` encoding is RFC 3339 and includes fractional
/// seconds whenever the timestamp carries any, which Foundation's built-in
/// `.iso8601` strategy cannot parse; `decodeGoTimestamp` tries the
/// fractional form first and falls back to the whole-second form.
extension JSONDecoder {
    public static var engineStatusDecoder: JSONDecoder {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .custom(decodeGoTimestamp)
        return decoder
    }
}

/// A fresh formatter is built on every call rather than shared from a
/// global, since ISO8601DateFormatter is not Sendable and a JSONDecoder's
/// custom date strategy offers no isolation guarantee about which thread
/// calls it.
private func decodeGoTimestamp(_ decoder: Decoder) throws -> Date {
    let container = try decoder.singleValueContainer()
    let raw = try container.decode(String.self)

    let withFraction = ISO8601DateFormatter()
    withFraction.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
    if let date = withFraction.date(from: raw) {
        return date
    }

    let withoutFraction = ISO8601DateFormatter()
    withoutFraction.formatOptions = [.withInternetDateTime]
    if let date = withoutFraction.date(from: raw) {
        return date
    }
    throw DecodingError.dataCorruptedError(
        in: container,
        debugDescription: "expected an RFC 3339 timestamp, got \(raw)"
    )
}
