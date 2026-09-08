import Foundation
import XCTest
@testable import Say2Core

final class SynthesisLifecycleTests: XCTestCase {
    private final class Request {}

    func testSerializesCallersInArrivalOrder() {
        let lifecycle = SynthesisLifecycle<Request>()
        let firstAcquired = expectation(description: "first acquired")
        let secondAttempted = expectation(description: "second attempted")
        let secondAcquired = expectation(description: "second acquired")
        let releaseFirst = DispatchSemaphore(value: 0)
        let order = LockedArray<Int>()

        DispatchQueue.global().async {
            let token = lifecycle.acquire()
            order.append(1)
            firstAcquired.fulfill()
            releaseFirst.wait()
            lifecycle.finish(token)
        }
        wait(for: [firstAcquired], timeout: 1)

        DispatchQueue.global().async {
            secondAttempted.fulfill()
            let token = lifecycle.acquire()
            order.append(2)
            secondAcquired.fulfill()
            lifecycle.finish(token)
        }
        wait(for: [secondAttempted], timeout: 1)
        Thread.sleep(forTimeInterval: 0.05)
        XCTAssertEqual(order.values, [1])
        releaseFirst.signal()
        wait(for: [secondAcquired], timeout: 1)
        XCTAssertEqual(order.values, [1, 2])
    }

    func testIdleCancellationDoesNotPoisonNextRequest() {
        let lifecycle = SynthesisLifecycle<Request>()
        XCTAssertNil(lifecycle.cancelActive())
        let token = lifecycle.acquire()
        XCTAssertFalse(lifecycle.isCancelled(token))
        lifecycle.finish(token)
    }

    func testCancellationIsIdempotentAndScopedToActiveToken() {
        let lifecycle = SynthesisLifecycle<Request>()
        let token = lifecycle.acquire()
        let request = Request()
        XCTAssertTrue(lifecycle.attach(request, to: token))
        XCTAssertTrue(lifecycle.cancelActive() === request)
        XCTAssertNil(lifecycle.cancelActive())
        XCTAssertTrue(lifecycle.isCancelled(token))
        XCTAssertFalse(lifecycle.acceptsCallbacks(for: token))
        lifecycle.finish(token)

        let next = lifecycle.acquire()
        XCTAssertFalse(lifecycle.isCancelled(next))
        XCTAssertTrue(lifecycle.acceptsCallbacks(for: next))
        lifecycle.finish(next)
    }

    func testLateTokenCannotAttachOrPublishIntoSuccessor() {
        let lifecycle = SynthesisLifecycle<Request>()
        let old = lifecycle.acquire()
        lifecycle.finish(old)
        let current = lifecycle.acquire()

        XCTAssertFalse(lifecycle.attach(Request(), to: old))
        XCTAssertFalse(lifecycle.acceptsCallbacks(for: old))
        XCTAssertTrue(lifecycle.acceptsCallbacks(for: current))
        lifecycle.finish(current)
    }

    func testCompletionAndCancellationHaveOneAtomicWinner() {
        let completedFirst = SynthesisLifecycle<Request>()
        let completedToken = completedFirst.acquire()
        XCTAssertTrue(completedFirst.attach(Request(), to: completedToken))
        XCTAssertTrue(completedFirst.claimCompletion(completedToken))
        XCTAssertNil(completedFirst.cancelActive())
        XCTAssertFalse(completedFirst.acceptsCallbacks(for: completedToken))
        completedFirst.finish(completedToken)

        let cancelledFirst = SynthesisLifecycle<Request>()
        let cancelledToken = cancelledFirst.acquire()
        let request = Request()
        XCTAssertTrue(cancelledFirst.attach(request, to: cancelledToken))
        XCTAssertTrue(cancelledFirst.cancelActive() === request)
        XCTAssertFalse(cancelledFirst.claimCompletion(cancelledToken))
        cancelledFirst.finish(cancelledToken)
    }
}

private final class LockedArray<Element>: @unchecked Sendable {
    private let lock = NSLock()
    private var storage: [Element] = []

    var values: [Element] {
        lock.withLock { storage }
    }

    func append(_ value: Element) {
        lock.withLock { storage.append(value) }
    }
}
