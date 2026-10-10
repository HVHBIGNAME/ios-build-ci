import Foundation

public enum WhitegramMessageShortening {
    // Original UI 0x312f48/0x312f7c and 0x320358: eligibility and retained lines.
    public static func canShorten(_ text: String) -> Bool {
        return text.count > 1000 || text.components(separatedBy: "\n").count > 15
    }

    public static func prefix(_ text: String) -> String {
        return text.components(separatedBy: "\n").prefix(15).joined(separator: "\n")
    }

    public static func clippedRange(_ range: Range<Int>, prefixUTF16Count: Int) -> Range<Int>? {
        guard range.lowerBound >= 0, range.lowerBound < prefixUTF16Count, range.upperBound > range.lowerBound else { return nil }
        return range.lowerBound ..< min(range.upperBound, prefixUTF16Count)
    }
}
