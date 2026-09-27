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
