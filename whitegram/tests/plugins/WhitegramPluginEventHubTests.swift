import Foundation
import XCTest
import TelegramCore

private final class PluginTestCommitBarrier {
    private let lock = NSLock()
    private var completions: [() -> Void] = []

    var count: Int {
        self.lock.lock()
        defer { self.lock.unlock() }
        return self.completions.count
    }

    func schedule(_ completion: @escaping () -> Void) {
        self.lock.lock()
        self.completions.append(completion)
        self.lock.unlock()
    }

    func commit() {
        self.lock.lock()
        let completion = self.completions.isEmpty ? nil : self.completions.removeFirst()
        self.lock.unlock()
        XCTAssertNotNil(completion)
        completion?()
    }
}

final class WhitegramPluginEventHubTests: XCTestCase {
    func testDeliveryWaitsForCommitAndUsesTheSubscriberQueue() {
        let hub = WhitegramPluginEventHub(), account = NSObject(), barrier = PluginTestCommitBarrier()
        let queue = DispatchQueue(label: "PluginTest.delivery")
        let key = DispatchSpecificKey<Bool>()
        queue.setSpecific(key: key, value: true)
        var names: [String] = []
        let subscription = hub.subscribe(scope: account, queue: queue, afterTransaction: barrier.schedule, receive: { events, dropped in
            XCTAssertEqual(DispatchQueue.getSpecific(key: key), true)
            XCTAssertEqual(dropped, 0)
            names.append(contentsOf: events.map { $0.name })
        })
        subscription.setEvents(["received"])
        hub.publish(scope: account, name: "ignored", payload: [:])
        XCTAssertEqual(barrier.count, 0)
        hub.publish(scope: account, name: "received", payload: ["id": 1])
        queue.sync { XCTAssertTrue(names.isEmpty) }
        barrier.commit()
        queue.sync { XCTAssertEqual(names, ["received"]) }
        subscription.dispose()
    }

    func testLaterTransactionsWaitForTheirOwnBarrier() {
        let hub = WhitegramPluginEventHub(), account = NSObject(), barrier = PluginTestCommitBarrier()
        let queue = DispatchQueue(label: "PluginTest.order")
        var values: [Int] = []
        let subscription = hub.subscribe(scope: account, queue: queue, afterTransaction: barrier.schedule, receive: { events, _ in
            values.append(contentsOf: events.compactMap { $0.payload["id"] as? Int })
        })
        subscription.setEvents(["changed"])
        hub.publish(scope: account, name: "changed", payload: ["id": 1])
        hub.publish(scope: account, name: "changed", payload: ["id": 2])
        XCTAssertEqual(barrier.count, 1)
        barrier.commit()
        queue.sync { XCTAssertEqual(values, [1]) }
        XCTAssertEqual(barrier.count, 1)
        barrier.commit()
        queue.sync { XCTAssertEqual(values, [1, 2]) }
        subscription.dispose()
    }

    func testScopeIsolationAndRestartDoNotReplayAnOldSessionsEvents() {
        let hub = WhitegramPluginEventHub(), firstAccount = NSObject(), secondAccount = NSObject()
        let barrier = PluginTestCommitBarrier(), queue = DispatchQueue(label: "PluginTest.scope")
        var first = 0, second = 0, restarted = 0
        let one = hub.subscribe(scope: firstAccount, queue: queue, afterTransaction: barrier.schedule, receive: { events, _ in first += events.count })
        let two = hub.subscribe(scope: secondAccount, queue: queue, afterTransaction: barrier.schedule, receive: { events, _ in second += events.count })
        one.setEvents(["message"])
        two.setEvents(["message"])
        hub.publish(scope: firstAccount, name: "message", payload: [:])
        one.dispose()
        let replacement = hub.subscribe(scope: firstAccount, queue: queue, afterTransaction: barrier.schedule, receive: { events, _ in restarted += events.count })
        replacement.setEvents(["message"])
        barrier.commit()
        queue.sync { XCTAssertEqual(first + second + restarted, 0) }
        hub.publish(scope: secondAccount, name: "message", payload: [:])
        barrier.commit()
        queue.sync { XCTAssertEqual(second, 1); XCTAssertEqual(restarted, 0) }
        replacement.dispose()
        two.dispose()
        XCTAssertFalse(hub.hasListeners(scope: firstAccount, names: ["message"]))
    }

    func testUnsubscribeAndReregisterDropsOldGeneration() {
        let hub = WhitegramPluginEventHub(), account = NSObject(), barrier = PluginTestCommitBarrier()
        let queue = DispatchQueue(label: "PluginTest.generation")
        var values: [Int] = []
        let subscription = hub.subscribe(scope: account, queue: queue, afterTransaction: barrier.schedule, receive: { events, _ in
            values.append(contentsOf: events.compactMap { $0.payload["id"] as? Int })
        })
        subscription.setEvents(["edit"])
        hub.publish(scope: account, name: "edit", payload: ["id": 1])
        subscription.setEvents([])
        subscription.setEvents(["edit"])
        hub.publish(scope: account, name: "edit", payload: ["id": 2])
        barrier.commit()
        queue.sync { XCTAssertTrue(values.isEmpty) }
        barrier.commit()
        queue.sync { XCTAssertEqual(values, [2]) }
        subscription.dispose()
    }

    func testSlowJavaScriptHasBoundedFIFOAndReportedDrops() {
        let hub = WhitegramPluginEventHub(), account = NSObject(), barrier = PluginTestCommitBarrier()
        let queue = DispatchQueue(label: "PluginTest.slowJS")
        var values: [Int] = [], lost = 0
        let subscription = hub.subscribe(scope: account, queue: queue, afterTransaction: barrier.schedule, receive: { events, dropped in
            values.append(contentsOf: events.compactMap { $0.payload["id"] as? Int })
            lost += dropped
        })
        subscription.setEvents(["message"])
        for id in 0 ..< 300 { hub.publish(scope: account, name: "message", payload: ["id": id]) }
        XCTAssertEqual(barrier.count, 1)
        barrier.commit()
        queue.sync { XCTAssertEqual(values, [0]) }
        barrier.commit()
        queue.sync {
            XCTAssertEqual(values, [0] + Array(44 ..< 300))
            XCTAssertEqual(lost, 43)
        }
        subscription.dispose()
    }

    func testByteBudgetAndInvalidPayloadsAreObservable() {
        let hub = WhitegramPluginEventHub(), account = NSObject(), barrier = PluginTestCommitBarrier()
        let queue = DispatchQueue(label: "PluginTest.bytes")
        var received = 0, lost = 0
        let subscription = hub.subscribe(scope: account, queue: queue, afterTransaction: barrier.schedule, receive: { events, dropped in
            received += events.count
            lost += dropped
        })
        subscription.setEvents(["message"])
        for id in 0 ..< 100 { hub.publish(scope: account, name: "message", payload: ["id": id, "text": String(repeating: "x", count: 32768)]) }
        hub.publish(scope: account, name: "message", payload: ["invalid": Double.nan])
        hub.publish(scope: account, name: "message", payload: ["oversized": String(repeating: "x", count: 65536)])
        barrier.commit()
        queue.sync {}
        barrier.commit()
        queue.sync {
            XCTAssertLessThanOrEqual(received, 33)
            XCTAssertEqual(received + lost, 102)
        }
        subscription.dispose()
    }

    func testDisposingInsideCallbackSuppressesRemainingBatchWithoutDeadlock() {
        let hub = WhitegramPluginEventHub(), account = NSObject(), barrier = PluginTestCommitBarrier()
        let queue = DispatchQueue(label: "PluginTest.reentrant")
        var received = 0
        var subscription: WhitegramPluginEventSubscription?
        subscription = hub.subscribe(scope: account, queue: queue, afterTransaction: barrier.schedule, receive: { events, _ in
            received += events.count
            if received == 2 { subscription?.dispose() }
        })
        subscription?.setEvents(["message"])
        for id in 0 ..< 10 { hub.publish(scope: account, name: "message", payload: ["id": id]) }
        barrier.commit()
        queue.sync {}
        barrier.commit()
        queue.sync { XCTAssertEqual(received, 2) }
        XCTAssertFalse(hub.hasListeners(scope: account, names: ["message"]))
        subscription = nil
    }
}
