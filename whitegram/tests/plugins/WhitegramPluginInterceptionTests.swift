import Foundation
import XCTest
@testable import TelegramCore

final class WhitegramPluginInterceptionTests: XCTestCase {
    private let js = DispatchQueue(label: "interception-tests.js")

    @discardableResult
    private func register(_ hub: WhitegramPluginInterceptionHub, _ scope: AnyObject, owner: String, name: String = "message.beforeSend", priority: Int = 0,
                          before: [String] = [], after: [String] = [], legacy: Bool = false, permitted: @escaping () -> Bool = { true },
                          invoke: @escaping ([String: Any]) -> [String: Any]) -> WhitegramPluginInterceptToken? {
        return hub.register(scope: scope, owner: owner, id: owner, name: name, legacy: legacy, priority: priority, before: before, after: after, queue: self.js,
                            permitted: permitted, invoke: invoke, diagnostic: { _ in })
    }

    func testPriorityMutationAndFinalResultPrecedeCompletion() {
        let scope = NSObject(), hub = WhitegramPluginInterceptionHub()
        let done = self.expectation(description: "native continuation")
        var steps: [String] = []
        self.register(hub, scope, owner: "last", priority: -1) { _ in XCTFail("Final result must stop the chain"); return ["action": "cancel"] }
        self.register(hub, scope, owner: "first", priority: 10) { payload in
            steps.append(payload["text"] as! String); return ["action": "modify", "value": "second"]
        }
        self.register(hub, scope, owner: "second", priority: 5) { payload in
            steps.append(payload["text"] as! String); return ["strategy": "modifyFinal", "value": ["text": "final", "peerId": "cannot redirect"]]
        }
        hub.intercept(scope: scope, name: "message.beforeSend", payload: ["text": "original", "peerId": "123"]) { decision in
            XCTAssertFalse(decision.cancelled); XCTAssertEqual(decision.payload["text"] as? String, "final")
            XCTAssertEqual(decision.payload["peerId"] as? String, "123"); XCTAssertEqual(steps, ["original", "second"]); done.fulfill()
        }
        self.wait(for: [done], timeout: 2)
    }

    func testCancellationReturnsOnceAndDoesNotRunLaterHandlers() {
        let scope = NSObject(), hub = WhitegramPluginInterceptionHub()
        let done = self.expectation(description: "cancelled")
        done.assertForOverFulfill = true
        self.register(hub, scope, owner: "first", priority: 2) { _ in ["action": "cancel", "reason": "blocked"] }
        self.register(hub, scope, owner: "last") { _ in XCTFail("Cancelled operation reached a later handler"); return [:] }
        hub.intercept(scope: scope, name: "message.beforeSend", payload: ["text": "private"]) { decision in
            XCTAssertTrue(decision.cancelled); XCTAssertEqual(decision.reason, "blocked"); done.fulfill()
        }
        self.wait(for: [done], timeout: 2)
    }

    func testAccountsAndRegistrationGenerationsAreIsolated() {
        let first = NSObject(), second = NSObject(), hub = WhitegramPluginInterceptionHub()
        self.register(hub, first, owner: "same-id") { _ in XCTFail("Other account callback"); return ["action": "cancel"] }
        let removed = self.register(hub, second, owner: "old") { _ in XCTFail("Disposed generation callback"); return [:] }
        removed?.dispose()
        let done = self.expectation(description: "other account")
        hub.intercept(scope: second, name: "message.beforeSend", payload: ["text": "unchanged"]) { decision in
            XCTAssertFalse(decision.cancelled); XCTAssertEqual(decision.payload["text"] as? String, "unchanged"); done.fulfill()
        }
        self.wait(for: [done], timeout: 2)
    }

    func testCallerDisposalSuppressesQueuedEvaluationAndCompletion() {
        let scope = NSObject(), hub = WhitegramPluginInterceptionHub()
        self.js.suspend()
        self.register(hub, scope, owner: "paused") { _ in XCTFail("Disposed invocation ran"); return [:] }
        let never = self.expectation(description: "no late continuation"); never.isInverted = true
        let token = hub.intercept(scope: scope, name: "message.beforeSend", payload: ["text": "unsent"]) { _ in never.fulfill() }
        token.dispose()
        self.js.resume()
        self.wait(for: [never], timeout: 0.1)
    }

    func testBusyJavaScriptQueueTimesOutWithoutLateCommit() {
        let scope = NSObject(), hub = WhitegramPluginInterceptionHub(deadline: 0.02)
        self.js.suspend()
        self.register(hub, scope, owner: "busy") { _ in XCTFail("Expired invocation ran"); return ["action": "modify", "value": "late"] }
        let done = self.expectation(description: "deadline")
        hub.intercept(scope: scope, name: "message.beforeSend", payload: ["text": "original"]) { decision in
            XCTAssertTrue(decision.cancelled); XCTAssertEqual(decision.reason, "INTERCEPT_TIMEOUT"); done.fulfill()
        }
        self.wait(for: [done], timeout: 2)
        self.js.resume()
        self.js.sync {}
    }

    func testRevocationBeforeResultIsAppliedCancelsInsteadOfSendingModifiedText() {
        let scope = NSObject(), hub = WhitegramPluginInterceptionHub()
        let lock = NSLock()
        var permitted = true
        self.register(hub, scope, owner: "revoked", permitted: { lock.lock(); defer { lock.unlock() }; return permitted }) { _ in
            lock.lock(); permitted = false; lock.unlock(); return ["action": "modify", "value": "must not send"]
        }
        let done = self.expectation(description: "revoked")
        hub.intercept(scope: scope, name: "message.beforeSend", payload: ["text": "original"]) { decision in
            XCTAssertTrue(decision.cancelled); XCTAssertEqual(decision.reason, "PLUGIN_STOPPED"); done.fulfill()
        }
        self.wait(for: [done], timeout: 2)
    }

    func testDependenciesOverridePriorityAndRejectCyclesAtomically() {
        let scope = NSObject(), hub = WhitegramPluginInterceptionHub()
        var order: [String] = []
        XCTAssertNotNil(self.register(hub, scope, owner: "a", priority: -1, before: ["b"]) { _ in order.append("a"); return [:] })
        XCTAssertNil(self.register(hub, scope, owner: "b", before: ["a"]) { _ in XCTFail("Cyclic registration ran"); return [:] })
        XCTAssertNotNil(self.register(hub, scope, owner: "b", priority: 9) { _ in order.append("b"); return [:] })
        let done = self.expectation(description: "dependency order")
        hub.intercept(scope: scope, name: "message.beforeSend", payload: [:]) { _ in XCTAssertEqual(order, ["a", "b"]); done.fulfill() }
        self.wait(for: [done], timeout: 2)
    }

    func testRequestReplacementCannotFabricateNativeResponseOrRewriteRequest() {
        let scope = NSObject(), hub = WhitegramPluginInterceptionHub()
        self.register(hub, scope, owner: "request", name: "tg.request") { _ in ["action": "replace", "value": ["method": "different", "ok": true]] }
        let done = self.expectation(description: "original request")
        hub.intercept(scope: scope, name: "tg.request", payload: ["method": "messages.getHistory"]) { decision in
            XCTAssertFalse(decision.cancelled); XCTAssertEqual(decision.payload["method"] as? String, "messages.getHistory"); XCTAssertNil(decision.payload["ok"]); done.fulfill()
        }
        self.wait(for: [done], timeout: 2)
    }
}
