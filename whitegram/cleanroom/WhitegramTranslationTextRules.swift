import Foundation

public enum WhitegramTranslationTextRules {
    public static let maximumSourceUTF16Length = 4096
    public static let maximumResultUTF16Length = 16384

    public static func validRange(_ range: Range<Int>, in text: String) -> Bool {
        let utf16 = text.utf16
        let count = utf16.count
        guard range.lowerBound >= 0, range.upperBound > range.lowerBound,
              range.upperBound <= count else { return false }
        for offset in [range.lowerBound, range.upperBound] where offset < count {
            let index = utf16.index(utf16.startIndex, offsetBy: offset)
            // A low surrogate at an endpoint splits the preceding scalar.
            guard !(0xdc00...0xdfff).contains(utf16[index]) else { return false }
        }
        return true
    }

    public static func hasText(_ text: String) -> Bool {
        return !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }
}

/// Splits at actual entity boundaries and maps those boundaries after translation.
/// Protected spans and whitespace are copied byte-for-byte; offsets are never guessed.
public struct WhitegramTranslationSegments {
    private struct Segment {
        let range: Range<Int>
        let original: String
        let prefix: String
        let suffix: String
        let requestIndex: Int?
    }

    public let requests: [String]
    private let segments: [Segment]

    public init?(text: String, entityRanges: [Range<Int>], protectedRanges: [Range<Int>]) {
        guard text.utf16.count <= WhitegramTranslationTextRules.maximumSourceUTF16Length,
              entityRanges.count <= 256, protectedRanges.count <= 256,
              (entityRanges + protectedRanges).allSatisfy({ WhitegramTranslationTextRules.validRange($0, in: text) }) else { return nil }
        let boundaries = Set([0, text.utf16.count] + (entityRanges + protectedRanges).flatMap { [$0.lowerBound, $0.upperBound] }).sorted()
        var segments: [Segment] = []
        var requests: [String] = []
        for (lower, upper) in zip(boundaries, boundaries.dropFirst()) where lower < upper {
            let range = lower..<upper
            let original = (text as NSString).substring(with: NSRange(location: lower, length: upper - lower))
            let scalars = Array(original.unicodeScalars)
            let count = original.utf16.count
            let leading = scalars.prefix(while: { CharacterSet.whitespacesAndNewlines.contains($0) }).reduce(0) { $0 + ($1.value > 0xffff ? 2 : 1) }
            let trailing = leading == count ? 0 : scalars.reversed().prefix(while: { CharacterSet.whitespacesAndNewlines.contains($0) }).reduce(0) { $0 + ($1.value > 0xffff ? 2 : 1) }
            let isProtected = protectedRanges.contains(where: { $0.overlaps(range) }) || leading == count
            let body = isProtected ? "" : (original as NSString).substring(with: NSRange(location: leading, length: count - leading - trailing))
            let index: Int? = isProtected ? nil : requests.count
            segments.append(Segment(range: range, original: original,
                prefix: (original as NSString).substring(to: leading),
                suffix: (original as NSString).substring(from: count - trailing), requestIndex: index))
            if index != nil { requests.append(body) }
        }
        self.requests = requests
        self.segments = segments
    }

    public func assemble(_ results: [String], entityRanges: [Range<Int>]) -> (text: String, ranges: [Range<Int>])? {
        guard results.count == self.requests.count,
              results.allSatisfy({ WhitegramTranslationTextRules.hasText($0) && $0.utf16.count <= WhitegramTranslationTextRules.maximumResultUTF16Length }) else { return nil }
        var text = ""
        var offsets: [Int: Int] = [0: 0]
        for segment in self.segments {
            offsets[segment.range.lowerBound] = text.utf16.count
            if let index = segment.requestIndex {
                text += segment.prefix + results[index] + segment.suffix
            } else {
                text += segment.original
            }
            guard text.utf16.count <= WhitegramTranslationTextRules.maximumResultUTF16Length else { return nil }
            offsets[segment.range.upperBound] = text.utf16.count
        }
        var ranges: [Range<Int>] = []
        for range in entityRanges {
            guard let lower = offsets[range.lowerBound], let upper = offsets[range.upperBound], lower < upper else { return nil }
            ranges.append(lower..<upper)
        }
        return (text, ranges)
    }
}
