import Foundation

/// Coalesces inventory reads and commits only successful snapshots. A failed
/// refresh therefore never destroys the last known-good installed inventory.
final class VoiceInventoryCache<Value>: @unchecked Sendable {
    private let lock = NSLock()
    private var cached: Value?

    func value(refresh: Bool, load: () throws -> Value) throws -> Value {
        try lock.withLock {
            if !refresh, let cached {
                return cached
            }
            let fresh = try load()
            cached = fresh
            return fresh
        }
    }

    func invalidate() {
        lock.withLock { cached = nil }
    }
}
