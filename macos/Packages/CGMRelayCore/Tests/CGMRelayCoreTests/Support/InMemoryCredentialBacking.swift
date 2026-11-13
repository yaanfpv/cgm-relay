import CGMRelayCore
import Foundation

/// InMemoryCredentialBacking stands in for the one Keychain item, so two
/// KeychainCredentialStore instances can share it the way two running
/// copies of the app share the real item. It holds the raw item bytes and
/// decodes them to the JSON dictionary the store writes.
final class InMemoryCredentialBacking: CredentialItemBacking, @unchecked Sendable {
    private let lock = NSLock()
    private var data: Data?

    init(items: [String: String]? = nil) {
        if let items { data = try? JSONEncoder().encode(items) }
    }

    func read() throws -> Data? {
        lock.withLock { data }
    }

    func write(_ newData: Data) throws {
        lock.withLock { data = newData }
    }

    /// items is the stored dictionary, or nil when nothing was ever written.
    var items: [String: String]? {
        lock.withLock { data.flatMap { try? JSONDecoder().decode([String: String].self, from: $0) } }
    }
}

/// ConstantByteGenerator returns the same byte repeated, so two stores
/// given different bytes generate different secrets.
struct ConstantByteGenerator: RandomBytesGenerating {
    let byte: UInt8
    func randomBytes(count: Int) throws -> Data { Data(repeating: byte, count: count) }
}
