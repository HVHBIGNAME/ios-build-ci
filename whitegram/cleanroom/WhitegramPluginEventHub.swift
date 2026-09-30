import Foundation

public struct WhitegramPluginEvent {
    public let name: String
    public let payload: [String: Any]
}

// Foundation-only so queueing, account isolation and teardown can be tested
// without constructing a Telegram account or a JavaScriptCore context.
public final class WhitegramPluginEventHub {
    private let lock = NSLock()
    private var subscriptions: [UUID: WhitegramPluginEventSubscription] = [:]

    public init() {}

    public func subscribe(scope: AnyObject, queue: DispatchQueue, afterTransaction: @escaping (@escaping () -> Void) -> Void,
                          receive: @escaping ([WhitegramPluginEvent], Int) -> Void) -> WhitegramPluginEventSubscription {
        let id = UUID()
        let subscription = WhitegramPluginEventSubscription(scope: scope, queue: queue, afterTransaction: afterTransaction, receive: receive, removed: { [weak self] in
            guard let self = self else { return }
            self.lock.lock()
            self.subscriptions.removeValue(forKey: id)
            self.lock.unlock()
        })
        self.lock.lock()
        self.subscriptions[id] = subscription
        self.lock.unlock()
        return subscription
    }

    private func listeners(_ scope: AnyObject, name: String) -> [WhitegramPluginEventSubscription] {
        self.lock.lock()
        let subscriptions = Array(self.subscriptions.values)
        self.lock.unlock()
        return subscriptions.filter { $0.accepts(scope: scope, name: name) }
    }

    public func hasListeners(scope: AnyObject, names: [String]) -> Bool {
        return names.contains { !self.listeners(scope, name: $0).isEmpty }
    }

    public func publish(scope: AnyObject, name: String, payload: [String: Any]) {
        let listeners = self.listeners(scope, name: name)
        guard !listeners.isEmpty else { return }
        let data: Data?
        do {
            if JSONSerialization.isValidJSONObject(payload) { data = try JSONSerialization.data(withJSONObject: payload) }
            else { data = nil }
        } catch { data = nil }
        // Reject an oversized observation as a unit. Do not truncate a JSON
        // envelope into an apparently successful but incomplete message.
        for listener in listeners { listener.enqueue(name: name, data: data) }
    }
}

public final class WhitegramPluginEventSubscription {
    private struct Pending {
        let name: String
        let generation: UInt64
        let data: Data
    }

    private weak var scope: AnyObject?
    private let queue: DispatchQueue
    private let afterTransaction: (@escaping () -> Void) -> Void
    private let removed: () -> Void
    private let lock = NSLock()
    private var receive: (([WhitegramPluginEvent], Int) -> Void)?
    private var events: [String: UInt64] = [:]
    private var generation: UInt64 = 0
    private var pending: [Pending] = []
    private var pendingBytes = 0
    private var dropped = 0
    private var draining = false
    private var active = true

    fileprivate init(scope: AnyObject, queue: DispatchQueue, afterTransaction: @escaping (@escaping () -> Void) -> Void,
                     receive: @escaping ([WhitegramPluginEvent], Int) -> Void, removed: @escaping () -> Void) {
        self.scope = scope
        self.queue = queue
        self.afterTransaction = afterTransaction
        self.receive = receive
        self.removed = removed
    }

    fileprivate func accepts(scope: AnyObject, name: String) -> Bool {
        self.lock.lock()
        defer { self.lock.unlock() }
        return self.active && self.scope === scope && self.events[name] != nil
    }

    public func setEvents(_ names: Set<String>) {
        self.lock.lock()
        defer { self.lock.unlock() }
        guard self.active else { return }
        self.events = self.events.filter { names.contains($0.key) }
        for name in names where self.events[name] == nil {
            self.generation &+= 1
            self.events[name] = self.generation
        }
        self.pending.removeAll { self.events[$0.name] != $0.generation }
        self.pendingBytes = self.pending.reduce(0) { $0 + $1.data.count }
    }

    fileprivate func enqueue(name: String, data: Data?) {
        self.lock.lock()
        guard self.active, let generation = self.events[name] else { self.lock.unlock(); return }
        if let data = data, data.count <= 65536 {
            while self.pending.count >= 256 || self.pendingBytes + data.count > 1024 * 1024 {
                self.pendingBytes -= self.pending.removeFirst().data.count
                self.dropped += 1
            }
            self.pending.append(Pending(name: name, generation: generation, data: data))
            self.pendingBytes += data.count
        } else { self.dropped += 1 }
        let start = !self.draining
        self.draining = true
        self.lock.unlock()
        if start { self.scheduleBatch() }
    }

    private func scheduleBatch() {
        self.lock.lock()
        guard self.active else { self.lock.unlock(); return }
        let batch = self.pending
        let dropped = self.dropped
        self.pending.removeAll()
        self.pendingBytes = 0
        self.dropped = 0
        self.lock.unlock()
        // Snapshot BEFORE the barrier. Events arriving from later transactions
        // must wait for their own barrier, even while this batch is in flight.
        self.afterTransaction { [weak self] in
            guard let self = self else { return }
            self.queue.async { [weak self] in self?.deliver(batch, dropped: dropped) }
        }
    }

    private func deliver(_ batch: [Pending], dropped: Int) {
        dispatchPrecondition(condition: .onQueue(self.queue))
        var dropped = dropped
        for item in batch {
            self.lock.lock()
            let receive = self.active && self.events[item.name] == item.generation ? self.receive : nil
            self.lock.unlock()
            guard let receive = receive else { continue }
            do {
                guard let payload = try JSONSerialization.jsonObject(with: item.data) as? [String: Any] else { dropped += 1; continue }
                receive([WhitegramPluginEvent(name: item.name, payload: payload)], dropped)
                dropped = 0
            } catch { dropped += 1 }
        }
        self.lock.lock()
        let receive = self.active ? self.receive : nil
        let again = self.active && (!self.pending.isEmpty || self.dropped != 0)
        if !again { self.draining = false }
        self.lock.unlock()
        if dropped != 0 { receive?([], dropped) }
        if again { self.scheduleBatch() }
    }

    public func dispose() {
        self.lock.lock()
        guard self.active else { self.lock.unlock(); return }
        self.active = false
        self.events.removeAll()
        self.pending.removeAll()
        self.pendingBytes = 0
        self.dropped = 0
        self.receive = nil
        self.lock.unlock()
        self.removed()
    }
}
