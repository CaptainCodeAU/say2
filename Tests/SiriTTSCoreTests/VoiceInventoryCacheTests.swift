import Foundation
import XCTest
@testable import SiriTTSCore

final class VoiceInventoryCacheTests: XCTestCase {
    func testCachedReadAvoidsSecondLoadAndRefreshReplacesSnapshot() throws {
        let cache = VoiceInventoryCache<[String]>()
        var calls = 0
        XCTAssertEqual(try cache.value(refresh: false) {
            calls += 1
            return ["A"]
        }, ["A"])
        XCTAssertEqual(try cache.value(refresh: false) {
            calls += 1
            return ["stale loader should not run"]
        }, ["A"])
        XCTAssertEqual(calls, 1)
        XCTAssertEqual(try cache.value(refresh: true) {
            calls += 1
            return ["B"]
        }, ["B"])
        XCTAssertEqual(calls, 2)
        XCTAssertEqual(try cache.value(refresh: false) { ["C"] }, ["B"])
    }

    func testFailedRefreshPreservesLastKnownGoodSnapshot() throws {
        enum Failure: Error { case unavailable }
        let cache = VoiceInventoryCache<[Int]>()
        _ = try cache.value(refresh: false) { [1, 2] }
        XCTAssertThrowsError(try cache.value(refresh: true) {
            throw Failure.unavailable
        })
        XCTAssertEqual(try cache.value(refresh: false) { [3] }, [1, 2])
    }

    func testInvalidationForcesNextRead() throws {
        let cache = VoiceInventoryCache<String>()
        XCTAssertEqual(try cache.value(refresh: false) { "old" }, "old")
        cache.invalidate()
        XCTAssertEqual(try cache.value(refresh: false) { "new" }, "new")
    }

    func testConcurrentColdReadsAreCoalesced() {
        let cache = VoiceInventoryCache<Int>()
        let group = DispatchGroup()
        let calls = LockedCounter()
        let values = LockedValues<Int>()
        for _ in 0..<8 {
            group.enter()
            DispatchQueue.global().async {
                defer { group.leave() }
                let value = try? cache.value(refresh: false) {
                    calls.increment()
                    Thread.sleep(forTimeInterval: 0.02)
                    return 42
                }
                if let value { values.append(value) }
            }
        }
        XCTAssertEqual(group.wait(timeout: .now() + 2), .success)
        XCTAssertEqual(calls.value, 1)
        XCTAssertEqual(values.values, Array(repeating: 42, count: 8))
    }
}

private final class LockedCounter: @unchecked Sendable {
    private let lock = NSLock()
    private var storage = 0
    var value: Int { lock.withLock { storage } }
    func increment() { lock.withLock { storage += 1 } }
}

private final class LockedValues<Value>: @unchecked Sendable {
    private let lock = NSLock()
    private var storage: [Value] = []
    var values: [Value] { lock.withLock { storage } }
    func append(_ value: Value) { lock.withLock { storage.append(value) } }
}
