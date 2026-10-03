import Foundation

public struct WhitegramVoiceWord: Equatable {
    public let text: String
    public let timestamp: Double
    public let duration: Double

    public init(text: String, timestamp: Double, duration: Double) {
        self.text = text
        self.timestamp = timestamp
        self.duration = duration
    }
}

public struct WhitegramVoiceProfanityMatcher {
    private let roots: Set<String>
    private let prefixes: [String]

    // IPA fallback arrays at TelegramCore 0x1146828 and 0x1146a50.
    public static let originalRoots = [
        "хуй", "хуе", "хуя", "хуи", "пизд", "бля", "ебат", "ебан", "ебал", "ебу",
        "сука", "сучк", "мудак", "мудил", "гандон", "гондон", "пидор", "пидар",
        "залуп", "дроч", "говн", "срань", "чмо", "уебищ",
        "fuck", "shit", "bitch", "cunt", "asshole", "bastard", "whore", "slut"
    ]
    public static let originalPrefixes = [
        "за", "по", "на", "до", "у", "вы", "от", "раз", "рас", "пере", "при", "с",
        "из", "о", "об", "под", "не", "бес", "без", "въ", "съ", "отъ", "разъ",
        "недо", "пре", "про", "во", "в"
    ]

    public init(roots: [String] = Self.originalRoots, prefixes: [String] = Self.originalPrefixes) {
        self.roots = Set(roots.map(Self.normalize).filter { $0.count >= 3 })
        self.prefixes = [""] + prefixes.map(Self.normalize).filter { !$0.isEmpty }
    }

    public func matches(_ word: String) -> Bool {
        if word.contains("*") && word.contains(where: { $0.isLetter }) { return true }
        let normalized = Self.normalize(word)
        guard normalized.count >= 3 else { return false }
        for prefix in self.prefixes where normalized.hasPrefix(prefix) {
            let suffix = normalized.dropFirst(prefix.count)
            if suffix.count < 3 { continue }
            var candidate = ""
            for letter in suffix {
                candidate.append(letter)
                if candidate.count >= 3 && self.roots.contains(candidate) { return true }
            }
        }
        return false
    }

    private static func normalize(_ value: String) -> String {
        return String(String.UnicodeScalarView(value.lowercased().replacingOccurrences(of: "ё", with: "е").unicodeScalars.filter { CharacterSet.letters.contains($0) }))
    }
}

public enum WhitegramVoiceSelectiveBleep {
    public static func ranges(words: [WhitegramVoiceWord], sampleRate: Int, sampleCount: Int, matcher: WhitegramVoiceProfanityMatcher) -> [Range<Int>] {
        guard (8000 ... 192000).contains(sampleRate), sampleCount > 0 else { return [] }
        let duration = Double(sampleCount) / Double(sampleRate)
        var result: [Range<Int>] = []
        for word in words where matcher.matches(word.text) {
            guard word.timestamp.isFinite, word.duration.isFinite, word.timestamp >= 0, word.timestamp < duration else { continue }
            let wordDuration = word.duration > 0.02 ? word.duration : 0.3
            let lower = Int(word.timestamp * Double(sampleRate))
            let upper = Int(min(duration, word.timestamp + wordDuration) * Double(sampleRate))
            let count = upper - lower
            guard count > 0 else { continue }
            let start = lower + max(sampleRate / 100, Int(Double(count) * 0.3))
            let end = upper - max(sampleRate / 100, Int(Double(count) * 0.35))
            if start < end { result.append(start ..< end) }
        }
        result.sort { $0.lowerBound < $1.lowerBound }
        var merged: [Range<Int>] = []
        for range in result {
            if let last = merged.last, range.lowerBound <= last.upperBound {
                merged[merged.count - 1] = last.lowerBound ..< max(last.upperBound, range.upperBound)
            } else {
                merged.append(range)
            }
        }
        return merged
    }

    public static func apply(_ samples: inout [Int16], sampleRate: Int, ranges: [Range<Int>], mode: WhitegramVoiceBleepMode) {
        guard (8000 ... 192000).contains(sampleRate) else { return }
        for range in ranges {
            let lower = max(0, range.lowerBound)
            let upper = min(samples.count, range.upperBound)
            guard lower < upper else { continue }
            let count = upper - lower
            let ramp = min(sampleRate / 200, count / 4)
            for index in lower ..< upper {
                if mode == .silence {
                    samples[index] = 0
                } else {
                    let offset = index - lower
                    let envelope = min(1.0, min(Double(offset) / Double(max(1, ramp)), Double(count - offset) / Double(max(1, ramp))))
                    let sample = sin(2 * .pi * 1000 * Double(offset) / Double(sampleRate)) * 9000 * envelope
                    samples[index] = Int16(sample)
                }
            }
        }
    }
}
