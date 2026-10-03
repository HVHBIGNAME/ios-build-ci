import Foundation
import XCTest
@testable import TelegramCore

final class WhitegramReadActionTests: XCTestCase {
    private func scope(account: Int64 = 1, peer: Int64 = 2, thread: Int64? = 3, message: Int32 = 100, timestamp: Int32 = 200) -> WhitegramReadActionScope {
        return .init(accountId: account, peerId: peer, threadId: thread, namespace: 0, messageId: message, timestamp: timestamp)
    }

    func testMismatchedScopesCannotConsumeOrWidenAPermit() {
        let permit = WhitegramReadActionPermit(scope: scope())
        for value in [scope(account: 2), scope(peer: 3), scope(thread: 4), scope(thread: nil), scope(message: 101), scope(timestamp: 201)] {
            XCTAssertFalse(permit.consume(for: value))
        }
        XCTAssertTrue(permit.consume(for: scope()))
        XCTAssertFalse(permit.consume(for: scope()))
    }

    func testConcurrentSubscriptionsConsumeExactlyOnce() {
        let value = scope()
        let permit = WhitegramReadActionPermit(scope: value)
        let lock = NSLock()
        var allowed = 0
        DispatchQueue.concurrentPerform(iterations: 128) { _ in
            if permit.consume(for: value) {
                lock.lock(); allowed += 1; lock.unlock()
            }
        }
        XCTAssertEqual(allowed, 1)
    }

    func testConcurrentActionsAndAccountsRemainIndependent() {
        let first = WhitegramReadActionPermit(scope: scope())
        let second = WhitegramReadActionPermit(scope: scope(account: 10))
        let third = WhitegramReadActionPermit(scope: scope(message: 110))
        XCTAssertFalse(second.consume(for: scope()))
        XCTAssertTrue(first.consume(for: scope()))
        XCTAssertTrue(second.consume(for: scope(account: 10)))
        XCTAssertTrue(third.consume(for: scope(message: 110)))
    }

    func testCancelledConfirmationNeverStartsCall() {
        var calls = 0
        let confirmation = WhitegramContentConfirmation { calls += 1 }
        confirmation.resolve(confirmed: false)
        confirmation.resolve(confirmed: true)
        XCTAssertEqual(calls, 0)
    }

    func testConfirmationCanOnlyStartOneCallAndIsReentrant() {
        var calls = 0
        var confirmation: WhitegramContentConfirmation!
        confirmation = WhitegramContentConfirmation {
            calls += 1
            confirmation.resolve(confirmed: true)
        }
        confirmation.resolve(confirmed: true)
        confirmation.resolve(confirmed: true)
        XCTAssertEqual(calls, 1)
    }

    func testCancelledStoryConfirmationCannotEnableHiddenViewsOrOpen() {
        var writes = 0
        var opens = 0
        let confirmation = WhitegramContentConfirmation { opens += 1 }
        confirmation.resolve(confirmed: false)
        XCTAssertTrue(confirmation.resolve(confirmed: true, prepare: { writes += 1; return true }))
        XCTAssertEqual(writes, 0)
        XCTAssertEqual(opens, 0)
    }

    func testStoryConfirmationRequiresSuccessfulSettingsWriteBeforeOpening() {
        var events: [String] = []
        let confirmation = WhitegramContentConfirmation { events.append("open") }
        XCTAssertTrue(confirmation.resolve(confirmed: true, prepare: { events.append("settings"); return true }))
        confirmation.resolve(confirmed: true)
        XCTAssertEqual(events, ["settings", "open"])

        let failed = WhitegramContentConfirmation { events.append("unexpected-open") }
        XCTAssertFalse(failed.resolve(confirmed: true, prepare: { false }))
        failed.resolve(confirmed: true)
        XCTAssertEqual(events, ["settings", "open"])
    }
}
