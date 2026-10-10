import Foundation
import Network

/// CertificateDownloadFormat is the kind of phone the certificate is for,
/// which decides what the phone is handed.
public enum CertificateDownloadFormat: Sendable, Equatable {
    /// A configuration profile that installs the certificate as a trusted
    /// root on an iPhone or iPad.
    case iPhone
    /// The certificate itself, in DER form, which Android offers to install.
    case android
}

/// CertificateDownloadError names the ways a download link can not be made.
public enum CertificateDownloadError: Error, Sendable, Equatable {
    case randomSourceFailed
    case listenerFailed
    /// The link was replaced or closed before it finished starting.
    case superseded
}

/// CertificateDownloadServer lets a phone fetch CGM Relay's authority
/// certificate by scanning a code. It listens on one private IPv4 address of
/// this Mac, over plain http, for a short time, and serves exactly one thing:
/// the certificate, once, at a URL that holds a random token.
///
/// Only one link is live at a time: making a new one ends the previous one.
/// A link works once. It ends when its lifetime runs out, when `close` is
/// called or when a newer link replaces it, and the listener is closed when
/// the last link ends. Until then every request that is not a GET for the
/// live token, including one for a used or replaced token, gets an empty 404
/// and changes nothing.
public actor CertificateDownloadServer {
    /// defaultLifetime is how long a link works after it is made.
    public static let defaultLifetime: Duration = .seconds(120)

    private let authorityCertificateDER: Data
    private let address: String
    private let lifetime: Duration
    private let randomBytes: any RandomBytesGenerating
    private let queue = DispatchQueue(label: "CertificateDownloadServer")

    private var listener: ListenerBox?

    /// init refuses an address that is not a private IPv4 address.
    public init(
        authorityCertificateDER: Data,
        address: String,
        lifetime: Duration = CertificateDownloadServer.defaultLifetime,
        randomBytes: any RandomBytesGenerating = SecureRandomBytesGenerator()
    ) throws {
        guard let checked = try LocalCertificateAuthority.normalizedAddresses([address]).first else {
            throw LocalCertificateError.invalidAddress(address)
        }
        self.init(
            authorityCertificateDER: authorityCertificateDER,
            unrestrictedAddress: checked,
            lifetime: lifetime,
            randomBytes: randomBytes
        )
    }

    /// The same server without the private-address check, so tests can use
    /// the loopback address.
    init(
        authorityCertificateDER: Data,
        unrestrictedAddress address: String,
        lifetime: Duration = CertificateDownloadServer.defaultLifetime,
        randomBytes: any RandomBytesGenerating = SecureRandomBytesGenerator()
    ) {
        self.authorityCertificateDER = authorityCertificateDER
        self.address = address
        self.lifetime = lifetime
        self.randomBytes = randomBytes
    }

    /// mint ends any earlier link and returns the URL a phone should open:
    /// `http://<address>:<port>/<token>`. If no link can be made, the earlier
    /// one is still ended and nothing is offered.
    public func mint(format: CertificateDownloadFormat) async throws -> URL {
        let response = try Self.response(for: format, certificateDER: authorityCertificateDER)

        let token: String
        do {
            token = try randomBytes.randomBytes(count: 16).base64URLEncodedStringWithoutPadding()
        } catch {
            await shutDown()
            throw CertificateDownloadError.randomSourceFailed
        }

        let capability = DownloadCapability(token: token, response: response, lifetime: lifetime)
        let box: ListenerBox
        if let existing = listener, !existing.isShutDown {
            box = existing
        } else {
            do {
                box = try ListenerBox(address: address, queue: queue)
            } catch {
                throw CertificateDownloadError.listenerFailed
            }
            listener = box
            box.begin()
        }
        box.install(capability)

        let port: UInt16
        do {
            port = try await box.waitReady()
        } catch {
            box.shutDown()
            throw CertificateDownloadError.listenerFailed
        }
        guard box.isCurrent(capability) else {
            throw CertificateDownloadError.superseded
        }
        return URL(string: "http://\(address):\(port)/\(token)")!
    }

    /// close ends the live link, if any, and returns once the listener has
    /// stopped accepting connections. A download already under way finishes.
    public func close() async {
        await shutDown()
    }

    private func shutDown() async {
        guard let box = listener else { return }
        listener = nil
        box.shutDown()
        await box.waitStopped()
    }

    private static func response(for format: CertificateDownloadFormat, certificateDER: Data) throws -> DownloadResponse {
        switch format {
        case .iPhone:
            return DownloadResponse(
                body: try CertificateProfile.mobileconfig(certificateDER: certificateDER),
                contentType: "application/x-apple-aspen-config",
                fileName: "CGM Relay.mobileconfig"
            )
        case .android:
            return DownloadResponse(
                body: certificateDER,
                contentType: "application/x-x509-ca-cert",
                fileName: "CGM Relay.crt"
            )
        }
    }
}

// MARK: Profile

/// CertificateProfile builds the configuration profile an iPhone installs to
/// trust the authority certificate.
enum CertificateProfile {
    static let identifier = "com.yaanfpv.cgmrelay.certificate"

    /// mobileconfig is an XML property list with one payload: the authority
    /// certificate as a trusted root. It holds no key.
    static func mobileconfig(certificateDER: Data) throws -> Data {
        let payload: [String: Any] = [
            "PayloadType": "com.apple.security.root",
            "PayloadVersion": 1,
            "PayloadIdentifier": "\(identifier).root",
            "PayloadUUID": "6C1D2E5A-3B0F-4D7E-9A41-5F2B8C7D9E10",
            "PayloadDisplayName": "CGM Relay Certificate",
            "PayloadContent": certificateDER,
        ]
        let profile: [String: Any] = [
            "PayloadType": "Configuration",
            "PayloadVersion": 1,
            "PayloadIdentifier": identifier,
            "PayloadUUID": "A7E3B1C4-52D8-4F69-8B0A-3E91D4C6F2B5",
            "PayloadDisplayName": "CGM Relay",
            "PayloadDescription": "Lets this device trust CGM Relay on your home network.",
            "PayloadContent": [payload],
        ]
        return try PropertyListSerialization.data(fromPropertyList: profile, format: .xml, options: 0)
    }
}

// MARK: Capability

struct DownloadResponse: Sendable {
    let body: Data
    let contentType: String
    let fileName: String
}

/// DownloadCapability is the one live link: a token, what it serves and its
/// lifetime. Reserving, consuming, releasing and ending all go through one
/// lock, so two requests for the same token can not both be given the body.
final class DownloadCapability: @unchecked Sendable {
    /// Reservation is proof that a request holds the token.
    struct Reservation: Sendable {
        fileprivate let id: UInt64
    }

    /// live: the token can be taken. reserved: a request holds it. used: the
    /// body was delivered, the token is dead. ended: the link is over.
    private enum Phase { case live, reserved, used, ended }

    let response: DownloadResponse

    private let token: [UInt8]
    private let clock = ContinuousClock()
    private let deadline: ContinuousClock.Instant
    private let lock = NSLock()
    private var phase = Phase.live
    private var closing = false
    private var reservationID: UInt64 = 0
    private var onEnded: (@Sendable () -> Void)?
    private var timer: Task<Void, Never>?

    init(token: String, response: DownloadResponse, lifetime: Duration) {
        self.token = Array(token.utf8)
        self.response = response
        let clock = self.clock
        let deadline = clock.now.advanced(by: lifetime)
        self.deadline = deadline
        timer = Task { [weak self] in
            try? await clock.sleep(until: deadline)
            self?.end()
        }
    }

    /// whenEnded runs `action` once the link has ended, at once if it
    /// already has.
    func whenEnded(_ action: @escaping @Sendable () -> Void) {
        let runNow = lock.withLock {
            if phase == .ended { return true }
            onEnded = action
            return false
        }
        if runNow { action() }
    }

    /// reserve takes the token for one request, and only when `candidate` is
    /// the live token, nobody holds it and the lifetime has not run out.
    func reserve(_ candidate: [UInt8]) -> Reservation? {
        let (reservation, ended): (Reservation?, (@Sendable () -> Void)?) = lock.withLock {
            guard phase == .live, !closing, tokensMatch(candidate) else { return (nil, nil) }
            if clock.now >= deadline {
                return (nil, finishLocked())
            }
            phase = .reserved
            reservationID &+= 1
            return (Reservation(id: reservationID), nil)
        }
        ended?()
        return reservation
    }

    /// complete consumes the token after the whole body was sent. The link
    /// itself ends with its lifetime, a close or a replacement, or now if one
    /// of those already happened during the send.
    func complete(_ reservation: Reservation) {
        let ended: (@Sendable () -> Void)? = lock.withLock {
            guard phase == .reserved, reservation.id == reservationID else { return nil }
            if closing || clock.now >= deadline {
                return finishLocked()
            }
            phase = .used
            return nil
        }
        ended?()
    }

    /// release gives the token back after a failed or interrupted send, when
    /// the link is still meant to be live.
    func release(_ reservation: Reservation) {
        let ended: (@Sendable () -> Void)? = lock.withLock {
            guard phase == .reserved, reservation.id == reservationID else { return nil }
            if closing || clock.now >= deadline {
                return finishLocked()
            }
            phase = .live
            return nil
        }
        ended?()
    }

    /// end stops the link: a token nobody holds is dead at once, a reserved
    /// one stays with its request until that request is done.
    func end() {
        let ended: (@Sendable () -> Void)? = lock.withLock {
            closing = true
            return phase == .reserved ? nil : finishLocked()
        }
        ended?()
    }

    /// finishLocked must be called with the lock held. It returns the
    /// ended-callback for the caller to run after unlocking.
    private func finishLocked() -> (@Sendable () -> Void)? {
        guard phase != .ended else { return nil }
        phase = .ended
        timer?.cancel()
        timer = nil
        defer { onEnded = nil }
        return onEnded
    }

    /// tokensMatch compares without stopping at the first difference.
    private func tokensMatch(_ candidate: [UInt8]) -> Bool {
        guard candidate.count == token.count else { return false }
        var difference: UInt8 = 0
        for (a, b) in zip(candidate, token) { difference |= a ^ b }
        return difference == 0
    }
}

// MARK: Listener

/// ListenerGate lets async code wait for a listener to be ready or stopped.
private final class ListenerGate: @unchecked Sendable {
    private let lock = NSLock()
    private var ready: Result<UInt16, Error>?
    private var readyWaiters: [CheckedContinuation<UInt16, Error>] = []
    private var stopped = false
    private var stoppedWaiters: [CheckedContinuation<Void, Never>] = []

    func update(_ state: NWListener.State, port: UInt16?) {
        switch state {
        case .ready:
            if let port { settle(.success(port)) }
        case .failed, .cancelled:
            settle(.failure(CertificateDownloadError.listenerFailed))
            stop()
        default:
            break
        }
    }

    func waitReady() async throws -> UInt16 {
        try await withCheckedThrowingContinuation { continuation in
            let result: Result<UInt16, Error>? = lock.withLock {
                if let ready { return ready }
                readyWaiters.append(continuation)
                return nil
            }
            if let result { continuation.resume(with: result) }
        }
    }

    func waitStopped() async {
        await withCheckedContinuation { continuation in
            let done = lock.withLock {
                if stopped { return true }
                stoppedWaiters.append(continuation)
                return false
            }
            if done { continuation.resume() }
        }
    }

    private func settle(_ result: Result<UInt16, Error>) {
        let waiters: [CheckedContinuation<UInt16, Error>] = lock.withLock {
            guard ready == nil else { return [] }
            ready = result
            defer { readyWaiters = [] }
            return readyWaiters
        }
        for waiter in waiters { waiter.resume(with: result) }
    }

    private func stop() {
        let waiters: [CheckedContinuation<Void, Never>] = lock.withLock {
            stopped = true
            defer { stoppedWaiters = [] }
            return stoppedWaiters
        }
        for waiter in waiters { waiter.resume() }
    }
}

/// ListenerBox owns the one listener and the link it currently serves. A new
/// link takes over the same listener, so the previous link's URL keeps
/// getting an empty 404 until the listener closes; the listener closes when
/// the current link ends or is closed.
private final class ListenerBox: @unchecked Sendable {
    private let listener: NWListener
    private let gate = ListenerGate()
    private let queue: DispatchQueue
    private let lock = NSLock()
    private var current: DownloadCapability?
    private var shut = false

    init(address: String, queue: DispatchQueue) throws {
        let parameters = NWParameters.tcp
        parameters.requiredLocalEndpoint = .hostPort(host: NWEndpoint.Host(address), port: .any)
        self.listener = try NWListener(using: parameters)
        self.queue = queue
    }

    var isShutDown: Bool { lock.withLock { shut } }

    func isCurrent(_ capability: DownloadCapability) -> Bool {
        lock.withLock { !shut && current === capability }
    }

    func begin() {
        let gate = gate
        let queue = queue
        listener.stateUpdateHandler = { [weak listener] state in
            gate.update(state, port: listener?.port?.rawValue)
        }
        let lookup: @Sendable () -> DownloadCapability? = { [weak self] in self?.currentCapability() }
        listener.newConnectionHandler = { connection in
            DownloadConnection(connection: connection, currentCapability: lookup, queue: queue).start()
        }
        listener.start(queue: queue)
    }

    func waitReady() async throws -> UInt16 {
        try await gate.waitReady()
    }

    func waitStopped() async {
        await gate.waitStopped()
    }

    /// install makes capability the live link and ends the one it replaces.
    func install(_ capability: DownloadCapability) {
        let previous: DownloadCapability? = lock.withLock {
            let previous = current
            current = capability
            return previous
        }
        capability.whenEnded { [weak self, id = ObjectIdentifier(capability)] in
            self?.linkEnded(id)
        }
        previous?.end()
    }

    /// shutDown ends the current link and stops the listener.
    func shutDown() {
        let capability: DownloadCapability? = lock.withLock {
            shut = true
            defer { current = nil }
            return current
        }
        listener.cancel()
        capability?.end()
    }

    private func currentCapability() -> DownloadCapability? {
        lock.withLock { current }
    }

    private func linkEnded(_ id: ObjectIdentifier) {
        let stop: Bool = lock.withLock {
            guard let live = current, ObjectIdentifier(live) == id else { return false }
            shut = true
            current = nil
            return true
        }
        if stop { listener.cancel() }
    }
}

// MARK: Connection

/// DownloadConnection reads one request and answers it. It runs on the
/// server's serial queue; the token is reserved as soon as the request line
/// shows a GET for it, and consumed only when the whole response was sent.
private final class DownloadConnection: @unchecked Sendable {
    private static let maxRequestBytes = 8192
    private static let requestTimeout: DispatchTimeInterval = .seconds(10)
    private static let lineEnd = Data("\r\n".utf8)
    private static let headerEnd = Data("\r\n\r\n".utf8)

    private enum Stage { case reading, sending, done }

    private let connection: NWConnection
    private let currentCapability: @Sendable () -> DownloadCapability?
    private let queue: DispatchQueue
    /// capability is the link this request was matched against, looked up
    /// when its request line arrived rather than when it connected.
    private var capability: DownloadCapability?
    private var stage = Stage.reading
    private var buffer = Data()
    private var decided = false
    private var reservation: DownloadCapability.Reservation?

    init(connection: NWConnection, currentCapability: @escaping @Sendable () -> DownloadCapability?, queue: DispatchQueue) {
        self.connection = connection
        self.currentCapability = currentCapability
        self.queue = queue
    }

    func start() {
        connection.stateUpdateHandler = { [self] state in
            switch state {
            case .failed, .cancelled:
                abandon()
            default:
                break
            }
        }
        connection.start(queue: queue)
        queue.asyncAfter(deadline: .now() + Self.requestTimeout) { [self] in
            if stage == .reading { abandon() }
        }
        receive()
    }

    private func receive() {
        connection.receive(minimumIncompleteLength: 1, maximumLength: 2048) { [self] data, _, isComplete, error in
            guard stage == .reading else { return }
            if let data { buffer.append(data) }
            if error != nil {
                abandon()
                return
            }
            if !decided, let lineRange = buffer.range(of: Self.lineEnd) {
                decided = true
                reservation = reserve(requestLine: buffer[buffer.startIndex..<lineRange.lowerBound])
            }
            if buffer.range(of: Self.headerEnd) != nil {
                respond()
            } else if isComplete || buffer.count > Self.maxRequestBytes {
                abandon()
            } else {
                receive()
            }
        }
    }

    /// reserve takes the token when the request line is exactly a GET for
    /// the live token.
    private func reserve(requestLine: Data) -> DownloadCapability.Reservation? {
        let parts = requestLine.split(separator: UInt8(ascii: " "), omittingEmptySubsequences: false)
        guard parts.count == 3,
            Array(parts[0]) == Array("GET".utf8),
            parts[1].first == UInt8(ascii: "/"),
            parts[2].starts(with: Array("HTTP/1.".utf8))
        else { return nil }
        capability = currentCapability()
        return capability?.reserve(Array(parts[1].dropFirst()))
    }

    private func respond() {
        stage = .sending
        let payload: Data
        if reservation != nil, let response = capability?.response {
            let head =
                "HTTP/1.1 200 OK\r\n"
                + "Content-Type: \(response.contentType)\r\n"
                + "Content-Length: \(response.body.count)\r\n"
                + "Content-Disposition: attachment; filename=\"\(response.fileName)\"\r\n"
                + "Cache-Control: no-store\r\n"
                + "Connection: close\r\n\r\n"
            payload = Data(head.utf8) + response.body
        } else {
            payload = Data("HTTP/1.1 404 Not Found\r\nContent-Length: 0\r\nConnection: close\r\n\r\n".utf8)
        }
        connection.send(content: payload, contentContext: .finalMessage, isComplete: true, completion: .contentProcessed { [self] error in
            if let held = reservation {
                reservation = nil
                if error == nil {
                    capability?.complete(held)
                } else {
                    capability?.release(held)
                }
            }
            stage = .done
            connection.cancel()
        })
    }

    /// abandon drops the connection before a response went out and gives
    /// the token back if this request held it.
    private func abandon() {
        guard stage != .done else { return }
        if stage == .reading, let held = reservation {
            reservation = nil
            capability?.release(held)
        }
        if stage == .reading {
            stage = .done
            connection.cancel()
        }
    }
}
