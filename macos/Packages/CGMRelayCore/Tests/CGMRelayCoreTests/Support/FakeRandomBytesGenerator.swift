import CGMRelayCore
import Foundation

/// FakeRandomBytesGenerator returns a fixed, distinguishable byte pattern
/// instead of real entropy, so a bootstrap test can assert on the exact
/// generated value.
struct FakeRandomBytesGenerator: RandomBytesGenerating {
    func randomBytes(count: Int) throws -> Data {
        Data((0..<count).map { UInt8($0 % 256) })
    }
}

/// CountingRandomBytesGenerator returns a different, predictable byte
/// pattern on every call, so a test can tell one renewal from the next.
final class CountingRandomBytesGenerator: RandomBytesGenerating, @unchecked Sendable {
    private let lock = NSLock()
    private var calls = 0

    func randomBytes(count: Int) throws -> Data {
        let call = lock.withLock {
            calls += 1
            return calls
        }
        return Data(repeating: UInt8(call), count: count)
    }
}
