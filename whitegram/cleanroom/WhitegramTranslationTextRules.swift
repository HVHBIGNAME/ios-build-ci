import Foundation

public enum WhitegramTranslationTextRules {
    public static let maximumSourceUTF16Length = 4096
    public static let maximumResultUTF16Length = 16384

    public static func validRange(_ range: Range<Int>, in text: String) -> Bool {
        guard range.lowerBound >= 0, range.upperBound > range.lowerBound,
              range.upperBound <= text.utf16.count else { return false }
        return Range(NSRange(location: range.lowerBound, length: range.count), in: text) != nil
    }

    public static func hasText(_ text: String) -> Bool {
        return !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }
}
