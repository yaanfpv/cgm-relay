import Foundation
import Network
import Testing
@testable import CGMRelayCore

/// These tests bind 127.0.0.1 to serve, through the internal initializer
/// that skips the private-address check, and talk to the server with a raw
/// socket client written here, so a response is read the way a phone reads
/// it and not through the code under test. The refusal of non-private
/// addresses is tested separately and binds nothing.
@Suite("CertificateDownloadServer")
struct CertificateDownloadServerTests {
    private static let followerToken = "follower-token-4f1d9c"
    private static let accountPassword = "account-password-71ab"

    private struct Fixture {
        let server: CertificateDownloadServer
        let material: LocalCertificateMaterial
    }

    private static func makeFixture(
        lifetime: Duration = .seconds(20),
        randomBytes: any RandomBytesGenerating = SecureRandomBytesGenerator(),
        expiresOnTimer: Bool = true
    ) throws -> Fixture {
        let store = FakeCredentialStore(values: [
            .token: followerToken,
            .librelinkupPassword: accountPassword,
        ])
        let material = try LocalCertificateAuthority(store: store)
            .currentMaterial(name: "relay-test.local", ipv4s: ["192.168.1.20"])
        let server = CertificateDownloadServer(
            authorityCertificateDER: material.authorityCertificateDER,
            unrestrictedAddress: "127.0.0.1",
            lifetime: lifetime,
            randomBytes: randomBytes,
            expiresOnTimer: expiresOnTimer
        )
        return Fixture(server: server, material: material)
    }

    // MARK: What is served

    @Test("the iPhone profile holds exactly one root payload with the authority certificate and no key")
    func profileHoldsOnlyTheCertificate() async throws {
        let fixture = try Self.makeFixture()
        let url = try await fixture.server.mint(format: .iPhone)
        let reply = try await HTTPReply.get(url)
        await fixture.server.close()

        #expect(reply.status == 200)
        #expect(reply.headers["content-type"] == "application/x-apple-aspen-config")
        #expect(reply.headers["content-length"] == String(reply.body.count))

        let plist = try PropertyListSerialization.propertyList(from: reply.body, options: [], format: nil)
        let profile = try #require(plist as? [String: Any])
        let payloads = try #require(profile["PayloadContent"] as? [[String: Any]])
        #expect(payloads.count == 1)
        #expect(payloads[0]["PayloadType"] as? String == "com.apple.security.root")
        #expect(payloads[0]["PayloadContent"] as? Data == fixture.material.authorityCertificateDER)

        // The profile itself and its one payload are the only dictionaries
        // that declare a payload type anywhere in the document.
        var payloadTypes: [String] = []
        Self.collectPayloadTypes(plist, into: &payloadTypes)
        #expect(payloadTypes.sorted() == ["Configuration", "com.apple.security.root"])

        let text = String(decoding: reply.body, as: UTF8.self)
        #expect(!text.contains("PRIVATE KEY"))
        #expect(!text.contains(Self.pemBody(fixture.material.serverKeyPEM)))
    }

    @Test("the Android download is the authority certificate in DER, unchanged")
    func androidServesTheDER() async throws {
        let fixture = try Self.makeFixture()
        let url = try await fixture.server.mint(format: .android)
        let reply = try await HTTPReply.get(url)
        await fixture.server.close()

        #expect(reply.status == 200)
        #expect(reply.headers["content-type"] == "application/x-x509-ca-cert")
        #expect(reply.body == fixture.material.authorityCertificateDER)
    }

    @Test("the link carries a 128-bit URL-safe token from the random source")
    func tokenShape() async throws {
        let recorder = RecordingRandomBytes()
        let fixture = try Self.makeFixture(randomBytes: recorder)
        let url = try await fixture.server.mint(format: .android)
        await fixture.server.close()

        #expect(recorder.requestedCounts == [16])
        let token = String(url.path.dropFirst())
        #expect(token.count == 22)
        #expect(token.allSatisfy { $0.isASCII && ($0.isLetter || $0.isNumber || $0 == "-" || $0 == "_") })
        #expect(url.scheme == "http")
        #expect(url.host == "127.0.0.1")
    }

    @Test("the production lifetime is 120 seconds")
    func defaultLifetime() {
        #expect(CertificateDownloadServer.defaultLifetime == .seconds(120))
    }

    // MARK: One live link

    @Test("a new link ends the old one: the old URL gets an empty 404 and the new one serves")
    func newLinkReplacesOld() async throws {
        let fixture = try Self.makeFixture()
        let first = try await fixture.server.mint(format: .android)
        let second = try await fixture.server.mint(format: .android)
        #expect(first.path != second.path)

        let old = try await HTTPReply.get(first)
        #expect(old.isEmptyNotFound)
        let new = try await HTTPReply.get(second)
        #expect(new.status == 200)
        #expect(new.body == fixture.material.authorityCertificateDER)
        await fixture.server.close()
    }

    @Test("a missing, guessed, altered or used token gets an empty 404 beside one genuine success")
    func wrongTokensAreNotFound() async throws {
        let fixture = try Self.makeFixture()
        let url = try await fixture.server.mint(format: .android)
        let token = String(url.path.dropFirst())
        let flipped = String(token.dropLast()) + (token.last == "A" ? "B" : "A")

        let paths = [
            "/",
            "/" + String(repeating: "A", count: 22),
            "/" + flipped,
            "/" + token.dropLast(),
            "/" + token + token,
            "/" + String(token.reversed()),
        ]
        for path in paths {
            let reply = try await HTTPReply.request(port: url.port!, line: "GET \(path) HTTP/1.1")
            #expect(reply.isEmptyNotFound, "path \(path)")
        }

        let genuine = try await HTTPReply.get(url)
        // Let the server finish recording the delivery before asking again.
        try await Task.sleep(for: .milliseconds(200))
        let used = try await HTTPReply.get(url)
        await fixture.server.close()
        #expect(genuine.status == 200)
        #expect(genuine.body == fixture.material.authorityCertificateDER)
        #expect(used.isEmptyNotFound)
    }

    @Test("a link works just before its lifetime ends and nothing answers after")
    func lifetime() async throws {
        let lifetime = Duration.seconds(3)
        let clock = ContinuousClock()

        let early = try Self.makeFixture(lifetime: lifetime)
        let earlyURL = try await early.server.mint(format: .android)
        let started = clock.now
        try await Task.sleep(for: .milliseconds(2000))
        let before = try await HTTPReply.get(earlyURL)
        #expect(clock.now - started < lifetime)
        #expect(before.status == 200)
        await early.server.close()

        let late = try Self.makeFixture(lifetime: lifetime)
        let lateURL = try await late.server.mint(format: .android)
        try await Task.sleep(for: .milliseconds(3400))
        // Expiry closes the listener, so an expired link is not answered at
        // all, which is stricter than an empty 404.
        await #expect(throws: (any Error).self) {
            _ = try await HTTPReply.get(lateURL)
        }
        await late.server.close()
    }

    // MARK: Racing and held requests

    @Test("two GETs racing on one token yield exactly one full body and one empty 404")
    func racingGets() async throws {
        let runs = 100
        let fixture = try Self.makeFixture()
        var winners = 0
        for run in 0..<runs {
            let url = try await fixture.server.mint(format: .android)
            async let a = HTTPReply.get(url)
            async let b = HTTPReply.get(url)
            let replies = try await [a, b]
            let successes = replies.filter { $0.status == 200 && $0.body == fixture.material.authorityCertificateDER }
            let misses = replies.filter { $0.isEmptyNotFound }
            #expect(successes.count == 1 && misses.count == 1, "run \(run)")
            winners += successes.count
        }
        await fixture.server.close()
        // Behavioural evidence over many runs, not a proof of atomicity: the
        // single lock-guarded reserve step is what guarantees it.
        #expect(winners == runs)
    }

    @Test("HEAD on a live token is an empty 404 and does not use the token")
    func headDoesNotConsume() async throws {
        let fixture = try Self.makeFixture()
        let url = try await fixture.server.mint(format: .android)
        let head = try await HTTPReply.request(port: url.port!, line: "HEAD \(url.path) HTTP/1.1")
        let get = try await HTTPReply.get(url)
        await fixture.server.close()

        #expect(head.isEmptyNotFound)
        #expect(get.status == 200)
    }

    @Test("a token held by a request in progress gets an empty 404 for anyone else")
    func reservedTokenIsNotServedTwice() async throws {
        let fixture = try Self.makeFixture()
        let url = try await fixture.server.mint(format: .android)
        let slow = try await RawClient.connect(port: url.port!)
        try await slow.send("GET \(url.path) HTTP/1.1\r\n")
        try await Task.sleep(for: .milliseconds(300))

        let other = try await HTTPReply.get(url)
        #expect(other.isEmptyNotFound)

        try await slow.send("Host: x\r\n\r\n")
        let reply = HTTPReply(parsing: await slow.readToEnd())
        await fixture.server.close()
        #expect(reply?.status == 200)
        #expect(reply?.body == fixture.material.authorityCertificateDER)
    }

    @Test("closing while a response is held lets it finish, and nothing is served afterwards")
    func closeLetsHeldResponseFinish() async throws {
        let fixture = try Self.makeFixture()
        let url = try await fixture.server.mint(format: .android)
        let port = url.port!
        let slow = try await RawClient.connect(port: port)
        try await slow.send("GET \(url.path) HTTP/1.1\r\n")
        try await Task.sleep(for: .milliseconds(300))

        await fixture.server.close()
        // The held request does not keep the listener open.
        await #expect(throws: (any Error).self) {
            _ = try await RawClient.connect(port: port)
        }
        try await slow.send("Host: x\r\n\r\n")
        let reply = HTTPReply(parsing: await slow.readToEnd())
        #expect(reply?.status == 200)
        #expect(reply?.body == fixture.material.authorityCertificateDER)

        await #expect(throws: (any Error).self) {
            _ = try await HTTPReply.get(url)
        }
    }

    @Test("a link that expires while a response is held stops accepting connections at once and lets it finish")
    func expiryLetsHeldResponseFinish() async throws {
        let fixture = try Self.makeFixture(lifetime: .milliseconds(800))
        let url = try await fixture.server.mint(format: .android)
        let port = url.port!
        let slow = try await RawClient.connect(port: port)
        try await slow.send("GET \(url.path) HTTP/1.1\r\n")
        try await Task.sleep(for: .milliseconds(300))

        // Well past the lifetime, and well inside the request timeout.
        try await Task.sleep(for: .milliseconds(1200))
        await #expect(throws: (any Error).self) {
            _ = try await RawClient.connect(port: port)
        }
        try await slow.send("Host: x\r\n\r\n")
        let reply = HTTPReply(parsing: await slow.readToEnd())
        await fixture.server.close()
        #expect(reply?.status == 200)
        #expect(reply?.body == fixture.material.authorityCertificateDER)
    }

    @Test("a new link while a response is held lets it finish, and the old token is gone afterwards")
    func newLinkLetsHeldResponseFinish() async throws {
        let fixture = try Self.makeFixture()
        let first = try await fixture.server.mint(format: .android)
        let slow = try await RawClient.connect(port: first.port!)
        try await slow.send("GET \(first.path) HTTP/1.1\r\n")
        try await Task.sleep(for: .milliseconds(300))

        let second = try await fixture.server.mint(format: .android)
        try await slow.send("Host: x\r\n\r\n")
        let held = HTTPReply(parsing: await slow.readToEnd())
        #expect(held?.status == 200)
        #expect(held?.body == fixture.material.authorityCertificateDER)

        let old = try await HTTPReply.get(first)
        #expect(old.isEmptyNotFound)
        let new = try await HTTPReply.get(second)
        #expect(new.status == 200)
        await fixture.server.close()
    }

    @Test("a client that drops before its request is complete leaves the token usable")
    func droppedRequestReleasesToken() async throws {
        let fixture = try Self.makeFixture()
        let url = try await fixture.server.mint(format: .android)
        let dropped = try await RawClient.connect(port: url.port!)
        try await dropped.send("GET \(url.path) HTTP/1.1\r\n")
        try await Task.sleep(for: .milliseconds(300))
        dropped.cancel()

        // The server notices the drop on its own schedule, so ask until the
        // token comes back; a token that never comes back fails here.
        let served = ServedBox()
        _ = await waitUntil(timeout: .seconds(5), pollInterval: .milliseconds(50)) {
            guard let reply = try? await HTTPReply.get(url), reply.status == 200 else { return false }
            served.set(reply)
            return true
        }
        await fixture.server.close()
        #expect(served.value?.body == fixture.material.authorityCertificateDER)
    }

    // MARK: Token state

    @Test("a failed send gives the token back until the link ends, a finished one uses it up")
    func capabilityLifecycle() throws {
        let response = DownloadResponse(body: Data([1]), contentType: "x", fileName: "f")
        let token = Array("tok".utf8)

        let failing = DownloadCapability(token: "tok", response: response, lifetime: .seconds(60))
        let held = try #require(failing.reserve(token))
        #expect(failing.reserve(token) == nil)
        failing.release(held)
        let again = try #require(failing.reserve(token))
        failing.complete(again)
        #expect(failing.reserve(token) == nil)

        let ending = DownloadCapability(token: "tok", response: response, lifetime: .seconds(60))
        let inFlight = try #require(ending.reserve(token))
        ending.end()
        #expect(ending.reserve(token) == nil)
        ending.release(inFlight)
        #expect(ending.reserve(token) == nil)

        let expired = DownloadCapability(token: "tok", response: response, lifetime: .zero)
        #expect(expired.reserve(token) == nil)

        let lapsed = DownloadCapability(token: "tok", response: response, lifetime: .zero, expiresOnTimer: false)
        #expect(lapsed.endIfExpired())
        let current = DownloadCapability(token: "tok", response: response, lifetime: .seconds(60))
        #expect(!current.endIfExpired())
        #expect(current.reserve(token) != nil)
    }

    // MARK: Everything else is an empty 404

    @Test("other paths, query strings, path variants and methods each get an empty 404 and use nothing up")
    func otherRequestsAreNotFound() async throws {
        let fixture = try Self.makeFixture()
        let url = try await fixture.server.mint(format: .android)
        let token = String(url.path.dropFirst())
        let encoded = "%" + String(token.utf8.first!, radix: 16) + token.dropFirst()

        let lines = [
            "GET /\(token)/ HTTP/1.1",
            "GET //\(token) HTTP/1.1",
            "GET /\(encoded) HTTP/1.1",
            "GET /\(token)?x=1 HTTP/1.1",
            "GET /\(token)? HTTP/1.1",
            "GET /\(token)#frag HTTP/1.1",
            "GET /\(token)/extra HTTP/1.1",
            "GET /./\(token) HTTP/1.1",
            "GET /a/../\(token) HTTP/1.1",
            "GET /\(token) HTTP/2",
            "GET /\(token)",
            "GET  /\(token) HTTP/1.1",
            "get /\(token) HTTP/1.1",
            "GET / HTTP/1.1",
            "GET /index.html HTTP/1.1",
            "GET /favicon.ico HTTP/1.1",
            "GET /.well-known/ HTTP/1.1",
            "GET /api/v1/entries HTTP/1.1",
            "GET /status HTTP/1.1",
            "GET * HTTP/1.1",
            "POST /\(token) HTTP/1.1",
            "PUT /\(token) HTTP/1.1",
            "DELETE /\(token) HTTP/1.1",
            "PATCH /\(token) HTTP/1.1",
            "OPTIONS /\(token) HTTP/1.1",
            "OPTIONS * HTTP/1.1",
            "CONNECT /\(token) HTTP/1.1",
            "TRACE /\(token) HTTP/1.1",
            "HEAD /\(token) HTTP/1.1",
            "nonsense",
        ]
        for line in lines {
            let reply = try await HTTPReply.request(port: url.port!, line: line)
            #expect(reply.isEmptyNotFound, "request line \(line)")
        }

        let genuine = try await HTTPReply.get(url)
        await fixture.server.close()
        #expect(genuine.status == 200)
    }

    // MARK: Nothing else is reachable

    @Test("no key, follower token, password or link token appears in any response")
    func nothingSecretLeaves() async throws {
        let fixture = try Self.makeFixture()
        var replies: [HTTPReply] = []
        var tokens: [String] = []

        for format in [CertificateDownloadFormat.iPhone, .android] {
            let url = try await fixture.server.mint(format: format)
            tokens.append(String(url.path.dropFirst()))
            replies.append(try await HTTPReply.request(port: url.port!, line: "GET / HTTP/1.1"))
            replies.append(try await HTTPReply.request(port: url.port!, line: "HEAD \(url.path) HTTP/1.1"))
            replies.append(try await HTTPReply.get(url))
            replies.append(try await HTTPReply.get(url))
        }
        await fixture.server.close()

        let forbidden = [
            Self.followerToken, Self.accountPassword, "PRIVATE KEY",
            Self.pemBody(fixture.material.serverKeyPEM),
        ] + tokens
        for reply in replies {
            let everything = String(decoding: reply.raw, as: UTF8.self)
            for secret in forbidden {
                #expect(!everything.contains(secret))
            }
            #expect(reply.headers["server"] == nil)
        }
        // An error response is the status line and two headers, nothing more.
        for reply in replies where reply.status == 404 {
            #expect(Set(reply.headers.keys) == ["content-length", "connection"])
            #expect(reply.raw.count == Data("HTTP/1.1 404 Not Found\r\nContent-Length: 0\r\nConnection: close\r\n\r\n".utf8).count)
        }
    }

    // MARK: Listener

    @Test("nothing accepts connections once the link has been closed")
    func listenerClosedAfterClose() async throws {
        let fixture = try Self.makeFixture()
        let url = try await fixture.server.mint(format: .android)
        await fixture.server.close()
        await #expect(throws: (any Error).self) {
            _ = try await RawClient.connect(port: url.port!)
        }
    }

    @Test("nothing accepts connections once the link has expired")
    func listenerClosedAfterExpiry() async throws {
        let fixture = try Self.makeFixture(lifetime: .milliseconds(400))
        let url = try await fixture.server.mint(format: .android)
        let port = url.port!
        let closed = await waitUntil(timeout: .seconds(5), pollInterval: .milliseconds(50)) {
            do {
                let client = try await RawClient.connect(port: port)
                client.cancel()
                return false
            } catch {
                return true
            }
        }
        #expect(closed)
        await fixture.server.close()
    }

    @Test("a connection after the lifetime is refused and closes the listener, even before the timer fires")
    func lateConnectionClosesTheListener() async throws {
        let fixture = try Self.makeFixture(lifetime: .milliseconds(300), expiresOnTimer: false)
        let url = try await fixture.server.mint(format: .android)
        try await Task.sleep(for: .milliseconds(500))
        // The first late connection gets no answer at all, and after it
        // nothing accepts connections.
        await #expect(throws: (any Error).self) {
            _ = try await HTTPReply.get(url)
        }
        let closed = await waitUntil(timeout: .seconds(5), pollInterval: .milliseconds(50)) {
            do {
                let client = try await RawClient.connect(port: url.port!)
                client.cancel()
                return false
            } catch {
                return true
            }
        }
        #expect(closed)
        await fixture.server.close()
    }

    @Test("a random source that fails offers no link and ends the previous one")
    func randomFailure() async throws {
        let random = FlakyRandomBytes()
        let fixture = try Self.makeFixture(randomBytes: random)
        let first = try await fixture.server.mint(format: .android)

        random.failing = true
        await #expect(throws: CertificateDownloadError.randomSourceFailed) {
            _ = try await fixture.server.mint(format: .android)
        }
        await #expect(throws: (any Error).self) {
            _ = try await HTTPReply.get(first)
        }
    }

    @Test("only private IPv4 addresses are accepted, and nothing is bound to find out")
    func privateAddressesOnly() throws {
        let der = Data([1, 2, 3])
        for address in ["192.168.1.20", "10.0.0.7", "172.16.5.9", "172.31.255.1"] {
            _ = try CertificateDownloadServer(authorityCertificateDER: der, address: address)
        }
        for address in [
            "127.0.0.1", "0.0.0.0", "8.8.8.8", "169.254.1.1", "172.32.0.1", "192.169.0.1",
            "::1", "fe80::1", "example.local", "192.168.1", "192.168.1.256", "", "192.168.01.20",
        ] {
            #expect(throws: LocalCertificateError.invalidAddress(address)) {
                _ = try CertificateDownloadServer(authorityCertificateDER: der, address: address)
            }
        }
    }

    // MARK: Helpers

    private static func collectPayloadTypes(_ value: Any, into types: inout [String]) {
        if let dictionary = value as? [String: Any] {
            if let type = dictionary["PayloadType"] as? String { types.append(type) }
            for child in dictionary.values { collectPayloadTypes(child, into: &types) }
        } else if let array = value as? [Any] {
            for child in array { collectPayloadTypes(child, into: &types) }
        }
    }

    private static func pemBody(_ pem: String) -> String {
        pem.split(separator: "\n").filter { !$0.hasPrefix("-----") }.joined()
    }
}

// MARK: Test doubles

private final class ServedBox: @unchecked Sendable {
    private let lock = NSLock()
    private var reply: HTTPReply?
    var value: HTTPReply? { lock.withLock { reply } }
    func set(_ newValue: HTTPReply) { lock.withLock { reply = newValue } }
}

private final class RecordingRandomBytes: RandomBytesGenerating, @unchecked Sendable {
    private let lock = NSLock()
    private var counts: [Int] = []
    var requestedCounts: [Int] { lock.withLock { counts } }

    func randomBytes(count: Int) throws -> Data {
        lock.withLock { counts.append(count) }
        return try SecureRandomBytesGenerator().randomBytes(count: count)
    }
}

private final class FlakyRandomBytes: RandomBytesGenerating, @unchecked Sendable {
    private let lock = NSLock()
    private var shouldFail = false
    var failing: Bool {
        get { lock.withLock { shouldFail } }
        set { lock.withLock { shouldFail = newValue } }
    }

    func randomBytes(count: Int) throws -> Data {
        if failing { throw RandomBytesError.generationFailed(-1) }
        return try SecureRandomBytesGenerator().randomBytes(count: count)
    }
}

/// RawClient is a plain TCP client: connect, write bytes, read until the
/// server closes.
private final class RawClient: @unchecked Sendable {
    private let connection: NWConnection
    private static let queue = DispatchQueue(label: "CertificateDownloadServerTests.client")

    private init(port: Int) {
        connection = NWConnection(host: "127.0.0.1", port: NWEndpoint.Port(rawValue: UInt16(port))!, using: .tcp)
    }

    struct ConnectFailed: Error {}

    static func connect(port: Int) async throws -> RawClient {
        let client = RawClient(port: port)
        try await client.start()
        return client
    }

    private func start() async throws {
        let resumed = NSLock()
        nonisolated(unsafe) var done = false
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
            connection.stateUpdateHandler = { state in
                let result: Result<Void, Error>?
                switch state {
                case .ready: result = .success(())
                case .failed, .waiting, .cancelled: result = .failure(ConnectFailed())
                default: result = nil
                }
                guard let result else { return }
                let first = resumed.withLock {
                    defer { done = true }
                    return !done
                }
                if first { continuation.resume(with: result) }
            }
            connection.start(queue: Self.queue)
        }
    }

    func send(_ text: String) async throws {
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
            connection.send(content: Data(text.utf8), completion: .contentProcessed { error in
                if let error { continuation.resume(throwing: error) } else { continuation.resume() }
            })
        }
    }

    /// readToEnd reads until the server closes the connection, giving up
    /// after five seconds.
    func readToEnd() async -> Data {
        let connection = connection
        let watchdog = Task {
            try? await Task.sleep(for: .seconds(5))
            connection.cancel()
        }
        var data = Data()
        while true {
            let (chunk, finished): (Data?, Bool) = await withCheckedContinuation { continuation in
                connection.receive(minimumIncompleteLength: 1, maximumLength: 65536) { chunk, _, isComplete, error in
                    continuation.resume(returning: (chunk, isComplete || error != nil))
                }
            }
            if let chunk { data.append(chunk) }
            if finished { break }
        }
        watchdog.cancel()
        connection.cancel()
        return data
    }

    func cancel() {
        connection.cancel()
    }
}

/// HTTPReply is a response split into status, headers and body.
private struct HTTPReply {
    let raw: Data
    let status: Int
    let headers: [String: String]
    let body: Data

    var isEmptyNotFound: Bool {
        status == 404 && body.isEmpty && headers["content-length"] == "0"
    }

    init?(parsing raw: Data) {
        guard let split = raw.range(of: Data("\r\n\r\n".utf8)) else { return nil }
        let head = String(decoding: raw[raw.startIndex..<split.lowerBound], as: UTF8.self)
        let lines = head.components(separatedBy: "\r\n")
        let statusParts = lines[0].split(separator: " ")
        guard statusParts.count >= 2, let status = Int(statusParts[1]) else { return nil }
        var headers: [String: String] = [:]
        for line in lines.dropFirst() {
            guard let colon = line.firstIndex(of: ":") else { continue }
            headers[line[..<colon].lowercased()] = line[line.index(after: colon)...].trimmingCharacters(in: .whitespaces)
        }
        self.raw = raw
        self.status = status
        self.headers = headers
        self.body = Data(raw[split.upperBound...])
    }

    struct Malformed: Error {}

    static func get(_ url: URL) async throws -> HTTPReply {
        try await request(port: url.port!, line: "GET \(url.path) HTTP/1.1")
    }

    /// request sends one complete request with the given request line and
    /// reads the reply to the end.
    static func request(port: Int, line: String) async throws -> HTTPReply {
        let client = try await RawClient.connect(port: port)
        try await client.send("\(line)\r\nHost: 127.0.0.1\r\nConnection: close\r\n\r\n")
        guard let reply = HTTPReply(parsing: await client.readToEnd()) else { throw Malformed() }
        return reply
    }
}
