import Foundation

/// A C#-style multicast event: `scanner.stateChanged.subscribe { state in … }`. Handlers run on the thread that
/// fires the event (often a background thread); UI code hops to the main actor itself.
/// Keep the returned `Subscription` alive for as long as you want callbacks (it unsubscribes on deinit).
public final class Event<T>: @unchecked Sendable {
    private let lock = NSLock()
    private var handlers: [UUID: (T) -> Void] = [:]

    public init() {}

    @discardableResult
    public func subscribe(_ handler: @escaping (T) -> Void) -> Subscription {
        let id = UUID()
        lock.lock(); handlers[id] = handler; lock.unlock()
        return Subscription { [weak self] in
            guard let self else { return }
            self.lock.lock(); self.handlers[id] = nil; self.lock.unlock()
        }
    }

    public func fire(_ value: T) {
        lock.lock(); let hs = Array(handlers.values); lock.unlock()
        for h in hs { h(value) }
    }
}

public extension Event where T == Void {
    func fire() { fire(()) }
}

/// Unsubscribes when cancelled or deallocated. Store it (`bag.append(sub)` or a property).
public final class Subscription: @unchecked Sendable {
    private var onCancel: (() -> Void)?
    private let lock = NSLock()
    public init(_ onCancel: @escaping () -> Void) { self.onCancel = onCancel }
    public func cancel() {
        lock.lock(); let c = onCancel; onCancel = nil; lock.unlock()
        c?()
    }
    deinit { cancel() }
}

/// Holds subscriptions; drop it to unsubscribe from everything.
public final class SubscriptionBag: @unchecked Sendable {
    private var subs: [Subscription] = []
    private let lock = NSLock()
    public init() {}
    public func add(_ s: Subscription) { lock.lock(); subs.append(s); lock.unlock() }
    public func cancelAll() { lock.lock(); let s = subs; subs = []; lock.unlock(); s.forEach { $0.cancel() } }
}

public extension Subscription {
    func store(in bag: SubscriptionBag) { bag.add(self) }
}
