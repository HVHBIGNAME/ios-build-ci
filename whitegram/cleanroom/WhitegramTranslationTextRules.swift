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
