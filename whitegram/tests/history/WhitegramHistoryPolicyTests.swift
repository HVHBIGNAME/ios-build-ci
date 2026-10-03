import Foundation
import XCTest
@testable import WhitegramHistory

final class WhitegramHistoryPolicyTests: XCTestCase {
    func testOriginalDefaultsAndOpacityRangeRejectTypeConfusion() {
        let policy = WhitegramHistoryPolicy(values: [:])
        XCTAssertFalse(policy.showDeleted)
        XCTAssertFalse(policy.showEdited)
        XCTAssertFalse(policy.saveHistory)
        XCTAssertFalse(policy.saveDeletedBackup)
        XCTAssertEqual(policy.deletedOpacity, 0.45)
        XCTAssertEqual(WhitegramHistoryPolicy(values: ["deletedMessagesOpacity": 0.0]).deletedOpacity, 0.01)
        XCTAssertEqual(WhitegramHistoryPolicy(values: ["deletedMessagesOpacity": 9.0]).deletedOpacity, 1.0)
        for value: Any in [true, "0.9", Double.nan, Double.infinity] {
            XCTAssertEqual(WhitegramHistoryPolicy(values: ["deletedMessagesOpacity": value]).deletedOpacity, 0.45)
        }
        XCTAssertFalse(WhitegramHistoryPolicy(values: ["showDeletedMessages": 1]).showDeleted)
        XCTAssertFalse(WhitegramHistoryPolicy(values: ["showDeletedMessages": "true"]).showDeleted)
    }

    func testIndependentCaptureFlagsDoNotTurnOnNativeDeletionPresentation() {
        let policy = WhitegramHistoryPolicy(values: ["saveDeletedMessagesToBackup": true])
        XCTAssertTrue(policy.captures(.deleted, peerId: 200, own: false, bot: false))
        XCTAssertFalse(policy.captures(.received, peerId: 200, own: false, bot: false))
        XCTAssertFalse(policy.captures(.edited, peerId: 200, own: false, bot: false))
        XCTAssertFalse(policy.retainsDeletion(peerId: 200, own: false, bot: false, alreadyDeleted: false, serverInitiated: true))
        let history = WhitegramHistoryPolicy(values: ["saveChatHistory": true])
        for event in WhitegramHistoryEvent.allCases { XCTAssertTrue(history.captures(event, peerId: 200, own: false, bot: false)) }
    }

    func testOwnAndBotFiltersAreIndependentForEditsAndDeletes() {
        let policy = WhitegramHistoryPolicy(values: ["showDeletedMessages": true, "showEditedOriginalText": true, "hideMyDeletedMessages": true, "hideBotEditedMessages": true])
        XCTAssertFalse(policy.captures(.deleted, peerId: 200, own: true, bot: false))
        XCTAssertTrue(policy.captures(.edited, peerId: 200, own: true, bot: false))
        XCTAssertTrue(policy.captures(.deleted, peerId: 200, own: false, bot: true))
        XCTAssertFalse(policy.captures(.edited, peerId: 200, own: false, bot: true))
        XCTAssertTrue(policy.captures(.deleted, peerId: 200, own: false, bot: false))
    }

    func testPerChatAndTrackedFiltersUseExact64BitIds() {
        let policy = WhitegramHistoryPolicy(values: ["showDeletedMessages": true, "showEditedOriginalText": true,
            "trackedPeerIds": "200,201 9007199254740993", "untrackedPeerIds": "201",
            "perChatHideDeleted": "200;invalid", "perChatHideEditedString": "9007199254740993"])
        XCTAssertFalse(policy.captures(.deleted, peerId: 200, own: false, bot: false))
        XCTAssertTrue(policy.captures(.edited, peerId: 200, own: false, bot: false))
        XCTAssertFalse(policy.captures(.edited, peerId: 201, own: false, bot: false))
        XCTAssertFalse(policy.captures(.deleted, peerId: 202, own: false, bot: false))
        XCTAssertTrue(policy.captures(.deleted, peerId: 9007199254740993, own: false, bot: false))
        XCTAssertFalse(policy.captures(.edited, peerId: 9007199254740993, own: false, bot: false))
        XCTAssertFalse(policy.captures(.deleted, peerId: 9007199254740992, own: false, bot: false))
    }

    func testServerReplayKeepsTombstoneAndExplicitSecondDeletePurgesIt() {
        let policy = WhitegramHistoryPolicy(values: ["showDeletedMessages": true])
        XCTAssertTrue(policy.retainsDeletion(peerId: 200, own: false, bot: false, alreadyDeleted: false, serverInitiated: true))
        XCTAssertTrue(policy.retainsDeletion(peerId: 200, own: false, bot: false, alreadyDeleted: false, serverInitiated: false))
        XCTAssertTrue(policy.retainsDeletion(peerId: 200, own: false, bot: false, alreadyDeleted: true, serverInitiated: true))
        XCTAssertFalse(policy.retainsDeletion(peerId: 200, own: false, bot: false, alreadyDeleted: true, serverInitiated: false))
        let hidden = WhitegramHistoryPolicy(values: [:])
        XCTAssertTrue(hidden.retainsDeletion(peerId: 200, own: false, bot: false, alreadyDeleted: true, serverInitiated: true))
        XCTAssertFalse(hidden.retainsDeletion(peerId: 200, own: false, bot: false, alreadyDeleted: true, serverInitiated: false))
    }

    func testRestorationSelectsLatestWholeIdentityAndNeverAnEditOnlyRecord() {
        func entry(_ peer: String, _ id: Int32, _ revision: UInt32, _ event: WhitegramHistoryEvent, _ time: Double, _ text: String) -> WhitegramHistoryEntry {
            return WhitegramHistoryEntry(accountId: "101", peerId: peer, namespace: 0, messageId: id, revision: revision, messageDate: 1700000000 + id, capturedAt: time, event: event, text: text, authorId: nil, outgoing: false, mediaCount: 0)
        }
        let received = entry("200", 7, 1, .received, 1, "received")
        let edited = entry("200", 7, 1, .edited, 2, "received")
        let deleted = entry("200", 7, 2, .deleted, 3, "latest")
        let otherPeer = entry("201", 7, 1, .deleted, 4, "other")
        let editOnly = entry("200", 8, 1, .edited, 5, "not a deleted copy")
        let records = [otherPeer, editOnly, deleted, received, edited]
        let result = whitegramHistoryRestorationEntries(records, scope: .peer("200"))
        XCTAssertEqual(result, [deleted])
        let all = whitegramHistoryRestorationEntries(records, scope: .account)
        XCTAssertEqual(Set(all.map(\.messageIdentity)), Set([deleted.messageIdentity, otherPeer.messageIdentity]))
        XCTAssertEqual(whitegramHistoryRestorationEntries(records, scope: .message(otherPeer.messageIdentity)), [otherPeer])
    }

    func testLegacyPeerPackingPreservesNamespaceAndWideId() throws {
        for namespace: Int32 in 0...2 {
            for id: Int64 in [1, Int64(Int32.max) + 1, 5000000000, 0x00ffffffffffffff] {
                let packed = try XCTUnwrap(whitegramHistoryPackedPeer(namespace: namespace, id: id))
                XCTAssertTrue(whitegramHistoryValidPeer(String(packed)))
                XCTAssertEqual((UInt64(packed) >> 32) & 7, UInt64(namespace))
                XCTAssertEqual(((UInt64(packed) >> 35) << 32) | (UInt64(packed) & 0xffffffff), UInt64(id))
            }
        }
        XCTAssertNil(whitegramHistoryPackedPeer(namespace: 8, id: 1))
        XCTAssertNil(whitegramHistoryPackedPeer(namespace: 3, id: 1))
        XCTAssertNil(whitegramHistoryPackedPeer(namespace: 0, id: Int64.min))
        XCTAssertNil(whitegramHistoryPackedPeer(namespace: 0, id: Int64.max))
    }
}
