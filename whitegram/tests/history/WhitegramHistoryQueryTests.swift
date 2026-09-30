import Foundation
import XCTest
@testable import WhitegramHistory

final class WhitegramHistoryQueryTests: XCTestCase {
    private func entry(peer: String = "200", namespace: Int32 = 0, id: Int32 = 7, revision: UInt32 = 1, sent: Int32 = 100, captured: Double = 200, event: WhitegramHistoryEvent = .edited) -> WhitegramHistoryEntry {
        return WhitegramHistoryEntry(accountId: "101", peerId: peer, namespace: namespace, messageId: id, revision: revision, messageDate: sent, capturedAt: captured, event: event, text: "Сохранённый текст", authorId: "300", outgoing: false, mediaCount: 1, peerTitle: "Work chat", authorName: "Alice", media: [WhitegramHistoryMedia(kind: .file, fileName: "Report.PDF")])
    }

    func testMessageScopeUsesFullTupleInsteadOfMessageNumberOrPrefix() {
        let selected = self.entry()
        let query = WhitegramHistoryQuery(scope: .message(selected.messageIdentity))
        let candidates = [selected, self.entry(peer: "2000"), self.entry(namespace: 2), self.entry(id: 70)]
        XCTAssertEqual(query.apply(to: candidates), [selected])
    }

    func testPeerEventAndSearchFiltersIntersect() {
        let selected = self.entry()
        let query = WhitegramHistoryQuery(scope: .peer("200"), event: .edited, text: " report.pdf ")
        XCTAssertEqual(query.apply(to: [selected, self.entry(peer: "201"), self.entry(event: .deleted)]), [selected])
    }

    func testSearchIncludesUnicodeTextNamesAndFileNames() {
        let entry = self.entry()
        for text in ["ТЕКСТ", "work", "ALICE", "report.pdf", "200", "300", "7", "   "] {
            XCTAssertTrue(WhitegramHistoryQuery(text: text).matches(entry), text)
        }
        XCTAssertFalse(WhitegramHistoryQuery(text: "not present").matches(entry))
    }

    func testOriginalTimeAndCaptureTimeAreIndependentWithStableTies() {
        let olderMessage = self.entry(id: 1, sent: 10, captured: 300)
        let newerMessage = self.entry(id: 2, sent: 20, captured: 200)
        XCTAssertEqual(WhitegramHistoryQuery().apply(to: [olderMessage, newerMessage]), [newerMessage, olderMessage])
        XCTAssertEqual(WhitegramHistoryQuery(order: .captureTime).apply(to: [newerMessage, olderMessage]), [olderMessage, newerMessage])
        let versions = [self.entry(revision: 2), self.entry(revision: 1)]
        let expected = versions.sorted { $0.key < $1.key }
        XCTAssertEqual(WhitegramHistoryQuery().apply(to: versions), expected)
        XCTAssertEqual(WhitegramHistoryQuery().apply(to: Array(versions.reversed())), expected)
    }

    func testBoundedUTF8PreservesWholeScalarsAtEveryBoundary() {
        let original = "A🙂Б中Z"
        for limit in 0...original.utf8.count {
            let value = whitegramHistoryBoundedString(original, maximumBytes: limit)
            XCTAssertLessThanOrEqual(value.utf8.count, limit)
            XCTAssertTrue(original.hasPrefix(value))
            XCTAssertFalse(value.contains("\u{fffd}"))
        }
        XCTAssertEqual(whitegramHistoryBoundedString(original, maximumBytes: 100), original)
    }
}
