import Foundation

/// StubURLProtocol answers requests in-process, so a test can see exactly
/// what a URLSession-backed type sent without any network. Each test
/// registers its handler under its own URL, so tests running in parallel
/// never see each other's requests.
final class StubURLProtocol: URLProtocol, @unchecked Sendable {
    typealias Handler = @Sendable (URLRequest) -> (status: Int, body: Data)

    private static let lock = NSLock()
    nonisolated(unsafe) private static var handlers: [String: Handler] = [:]
    nonisolated(unsafe) private static var redirects: [String: URL] = [:]

    static func register(url: URL, handler: @escaping Handler) {
        lock.withLock { handlers[url.absoluteString] = handler }
    }

    /// registerRedirect makes url answer with a 302 to target.
    static func registerRedirect(from url: URL, to target: URL) {
        lock.withLock { redirects[url.absoluteString] = target }
    }

    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }

    override func startLoading() {
        let key = request.url?.absoluteString ?? ""
        if let url = request.url, let target = Self.lock.withLock({ Self.redirects[key] }) {
            let response = HTTPURLResponse(url: url, statusCode: 302, httpVersion: nil, headerFields: ["Location": target.absoluteString])!
            client?.urlProtocol(self, wasRedirectedTo: URLRequest(url: target), redirectResponse: response)
            // A real HTTP stack answers with the redirect itself when the
            // session refuses to follow it.
            client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
            client?.urlProtocolDidFinishLoading(self)
            return
        }
        let handler = Self.lock.withLock { Self.handlers[key] }
        guard let handler, let url = request.url else {
            client?.urlProtocol(self, didFailWithError: URLError(.unsupportedURL))
            return
        }
        let (status, body) = handler(request)
        let response = HTTPURLResponse(url: url, statusCode: status, httpVersion: nil, headerFields: nil)!
        client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
        client?.urlProtocol(self, didLoad: body)
        client?.urlProtocolDidFinishLoading(self)
    }

    override func stopLoading() {}
}
