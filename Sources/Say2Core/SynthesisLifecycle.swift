import Foundation

/// Serializes native Siri work and keeps cancellation tied to one logical
/// request. The generic request type makes the state machine deterministic to
/// test without loading the private framework.
final class SynthesisLifecycle<Request: AnyObject>: @unchecked Sendable {
    struct Token: Hashable, Sendable {
        fileprivate let id: UUID
    }

    private struct Active {
        let token: Token
        var request: Request?
        var cancelled = false
        var completed = false
    }

    private let condition = NSCondition()
    private var occupied = false
    private var active: Active?

    func acquire() -> Token {
        condition.lock()
        while occupied {
            condition.wait()
        }
        occupied = true
        let token = Token(id: UUID())
        active = Active(token: token)
        condition.unlock()
        return token
    }

    func attach(_ request: Request, to token: Token) -> Bool {
        condition.withLock {
            guard active?.token == token else { return false }
            active?.request = request
            return active?.cancelled == false
        }
    }

    func isCancelled(_ token: Token) -> Bool {
        condition.withLock {
            guard active?.token == token else { return true }
            return active?.cancelled == true
        }
    }

    func acceptsCallbacks(for token: Token) -> Bool {
        condition.withLock {
            active?.token == token &&
            active?.cancelled == false &&
            active?.completed == false
        }
    }

    @discardableResult
    func cancelActive() -> Request? {
        condition.withLock {
            guard var value = active,
                  !value.cancelled,
                  !value.completed else {
                return nil
            }
            value.cancelled = true
            active = value
            return value.request
        }
    }

    /// Linearization point between cancellation and successful completion.
    /// Once claimed, a later `cancelActive()` is intentionally a no-op.
    func claimCompletion(_ token: Token) -> Bool {
        condition.withLock {
            guard var value = active,
                  value.token == token,
                  !value.cancelled,
                  !value.completed else {
                return false
            }
            value.completed = true
            active = value
            return true
        }
    }

    func finish(_ token: Token) {
        condition.lock()
        if active?.token == token {
            active = nil
            occupied = false
            condition.broadcast()
        }
        condition.unlock()
    }
}
