import Foundation

/// ObservedUpdates records every value a @Sendable callback hands it, in
/// call order, for a test to assert against.
final class ObservedUpdates<Value: Sendable>: @unchecked Sendable {
    private let lock = NSLock()
    private var _values: [Value] = []

    var values: [Value] {
        lock.withLock { _values }
    }

    func append(_ value: Value) {
        lock.withLock { _values.append(value) }
    }
}
