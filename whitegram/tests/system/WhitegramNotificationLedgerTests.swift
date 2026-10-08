import Foundation
import TelegramCore
import XCTest

final class WhitegramNotificationLedgerTests: XCTestCase {
    private func id(_ message: Int32, account: Int64 = 9007199254740993, peer: Int64 = -1001234567890, namespace: Int32 = 0) -> WhitegramLocalNotificationId {
        return WhitegramLocalNotificationId(accountId: account, peerId: peer, namespace: namespace, messageId: message)
    }

    func testOriginalIdentityFormatAndExactLargeAccountPayloadRoundTrip() throws {
        let value = id(42)
        XCTAssertEqual(value.rawValue, "wg_local_9007199254740993_-1001234567890_0_42")
        XCTAssertEqual(WhitegramLocalNotificationId(rawValue: value.rawValue), value)
        let payload = value.userInfo(threadId: 9007199254740995)
        XCTAssertEqual(payload["accountId"] as? String, "9007199254740993")
        XCTAssertEqual(payload["peerId"] as? String, "-1001234567890")
        XCTAssertEqual(payload["messageId"] as? String, "42")
        XCTAssertEqual(payload["msg_id"] as? String, "42")
        XCTAssertEqual(payload["messageId.namespace"] as? Int32, 0)
        XCTAssertEqual(payload["messageId.id"] as? Int32, 42)
        XCTAssertEqual(payload["threadId"] as? Int64, 9007199254740995)
        XCTAssertEqual(payload["whitegramLocal"] as? Bool, true)
        XCTAssertNil(value.userInfo(threadId: nil)["threadId"])
    }

    func testMalformedOrUnrelatedNotificationIdentifiersAreRejected() {
        for value in ["m1:0:42", "wg_local_1_2_0", "wg_local_1_2_0_42_extra", "wg_local_1__0_42",
                      "wg_local_9223372036854775808_2_0_42", "wg_local_1_2_0_2147483648",
                      "wg_local_01_2_0_42", "wg_local_1_2_+0_42", "wg_local_1_2_0_42 "] {
            XCTAssertNil(WhitegramLocalNotificationId(rawValue: value), value)
        }
    }

    func testGroupingSeparatesAccountsAndTopics() {
        XCTAssertEqual(id(1).threadIdentifier(threadId: nil), "wg_9007199254740993_-1001234567890")
        XCTAssertEqual(id(1).threadIdentifier(threadId: 8), "wg_9007199254740993_-1001234567890_8")
        XCTAssertNotEqual(id(1).threadIdentifier(threadId: 8), id(1, account: 7).threadIdentifier(threadId: 8))
        XCTAssertNotEqual(id(1).threadIdentifier(threadId: 8), id(1).threadIdentifier(threadId: 9))
    }

    func testReadClearingCannotCrossAccountPeerOrNamespace() {
        let maximum = id(10)
        XCTAssertTrue(id(1).isRead(by: maximum))
        XCTAssertTrue(id(10).isRead(by: maximum))
        XCTAssertFalse(id(11).isRead(by: maximum))
        XCTAssertFalse(id(1, account: 4).isRead(by: maximum))
        XCTAssertFalse(id(1, peer: 5).isRead(by: maximum))
        XCTAssertFalse(id(1, namespace: 7).isRead(by: maximum))
    }

    func testPendingAndDeliveredDuplicatesAreSuppressed() throws {
        let ledger = WhitegramNotificationLedger()
        let ticket = try XCTUnwrap(ledger.reserve(id(1)))
        XCTAssertNil(ledger.reserve(id(1)))
        ledger.finish(ticket, delivered: true)
        XCTAssertNil(ledger.reserve(id(1)))
        XCTAssertNotNil(ledger.reserve(id(1, account: 2)))
    }

    func testFailureCanRetryAndOldCompletionCannotFinishTheNewAttempt() throws {
        let ledger = WhitegramNotificationLedger()
        let first = try XCTUnwrap(ledger.reserve(id(1)))
        ledger.finish(first, delivered: false)
        let retry = try XCTUnwrap(ledger.reserve(id(1)))
        ledger.finish(first, delivered: true)
        XCTAssertTrue(ledger.isCurrent(retry))
        ledger.finish(retry, delivered: false)
        XCTAssertNotNil(ledger.reserve(id(1)))
    }

    func testForegroundOrDisableInvalidatesOutstandingPermissionCallbacks() throws {
        let ledger = WhitegramNotificationLedger()
        let ticket = try XCTUnwrap(ledger.reserve(id(1)))
        XCTAssertEqual(ledger.invalidatePending(), [id(1).rawValue])
        XCTAssertFalse(ledger.isCurrent(ticket))
        ledger.finish(ticket, delivered: true)
        XCTAssertFalse(ledger.contains(id(1)))
        XCTAssertNotNil(ledger.reserve(id(1)))
    }

    func testReadWhileWaitingCancelsOnlyMatchingMessagesAndWatermarkNeverRegresses() throws {
        let ledger = WhitegramNotificationLedger()
        let first = try XCTUnwrap(ledger.reserve(id(1)))
        let otherAccount = try XCTUnwrap(ledger.reserve(id(1, account: 2)))
        ledger.recordRead([id(20), id(5)])
        XCTAssertFalse(ledger.isCurrent(first))
        XCTAssertTrue(ledger.isCurrent(otherAccount))
        XCTAssertNil(ledger.reserve(id(15)))
        XCTAssertNotNil(ledger.reserve(id(21)))
        XCTAssertNotNil(ledger.reserve(id(1, namespace: 4)))
    }

    func testPendingWorkIsBoundedWhenSystemCallbacksStall() throws {
        let ledger = WhitegramNotificationLedger()
        for number in 1 ... 500 { XCTAssertNotNil(ledger.reserve(id(Int32(number)))) }
        XCTAssertNil(ledger.reserve(id(501)))
        XCTAssertEqual(ledger.invalidatePending().count, 500)
        XCTAssertNotNil(ledger.reserve(id(501)))
    }

    func testForegroundCancelsAcceptedRequestsBeforeTheirDelayedTrigger() throws {
        let ledger = WhitegramNotificationLedger()
        let ticket = try XCTUnwrap(ledger.reserve(id(1)))
        ledger.finish(ticket, delivered: true)
        XCTAssertEqual(ledger.invalidatePending(), [id(1).rawValue])
        XCTAssertNil(ledger.reserve(id(1)))
    }

    func testReadCancelsAcceptedAndInFlightRequestsWithoutCrossingAccounts() throws {
        let ledger = WhitegramNotificationLedger()
        let scheduled = try XCTUnwrap(ledger.reserve(id(1)))
        ledger.finish(scheduled, delivered: true)
        let pending = try XCTUnwrap(ledger.reserve(id(2)))
        let other = try XCTUnwrap(ledger.reserve(id(2, account: 2)))
        XCTAssertEqual(Set(ledger.recordRead([id(2)])), [id(1).rawValue, id(2).rawValue])
        XCTAssertFalse(ledger.isCurrent(pending))
        XCTAssertTrue(ledger.isCurrent(other))
        XCTAssertNil(ledger.reserve(id(1)))
    }

    func testOriginalFiveHundredEntryDedupWindowKeepsTheNewestAtReset() throws {
        let ledger = WhitegramNotificationLedger()
        for number in 1 ... 501 {
            let ticket = try XCTUnwrap(ledger.reserve(id(Int32(number))))
            ledger.finish(ticket, delivered: true)
        }
        XCTAssertNil(ledger.reserve(id(501)))
        XCTAssertNotNil(ledger.reserve(id(1)))
    }
}
