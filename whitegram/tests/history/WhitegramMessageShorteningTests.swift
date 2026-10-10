import XCTest
@testable import WhitegramHistory

final class WhitegramMessageShorteningTests: XCTestCase {
    func testOriginalLineAndCharacterThresholds() {
        XCTAssertFalse(WhitegramMessageShortening.canShorten(String(repeating: "x", count: 1000)))
        XCTAssertTrue(WhitegramMessageShortening.canShorten(String(repeating: "x", count: 1001)))
        XCTAssertFalse(WhitegramMessageShortening.canShorten(Array(repeating: "x", count: 15).joined(separator: "\n")))
        XCTAssertTrue(WhitegramMessageShortening.canShorten(Array(repeating: "x", count: 16).joined(separator: "\n")))
        XCTAssertFalse(WhitegramMessageShortening.canShorten(String(repeating: "👨‍👩‍👧‍👦", count: 1000)))
    }

    func testRetainsExactlyFifteenLinesIncludingEmptyLines() {
        let lines = (1 ... 20).map { $0 == 3 ? "" : "line \($0)" }
        XCTAssertEqual(WhitegramMessageShortening.prefix(lines.joined(separator: "\n")), lines.prefix(15).joined(separator: "\n"))
        XCTAssertEqual(WhitegramMessageShortening.prefix(String(repeating: "\n", count: 20)), String(repeating: "\n", count: 14))
        // The original action takes lines even when eligibility came from the character threshold.
        let longLine = String(repeating: "x", count: 1001)
        XCTAssertEqual(WhitegramMessageShortening.prefix(longLine), longLine)
    }

    func testClipsEntityRangesBeforeTheEllipsis() {
        XCTAssertEqual(WhitegramMessageShortening.clippedRange(2 ..< 20, prefixUTF16Count: 8), 2 ..< 8)
        XCTAssertEqual(WhitegramMessageShortening.clippedRange(0 ..< 2, prefixUTF16Count: 8), 0 ..< 2)
        XCTAssertNil(WhitegramMessageShortening.clippedRange(8 ..< 20, prefixUTF16Count: 8))
        XCTAssertNil(WhitegramMessageShortening.clippedRange(-1 ..< 2, prefixUTF16Count: 8))
        XCTAssertNil(WhitegramMessageShortening.clippedRange(0 ..< 0, prefixUTF16Count: 8))
    }
}
