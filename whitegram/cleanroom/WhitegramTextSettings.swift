import Foundation
import CoreFoundation

public struct WhitegramTextSettings {
    public enum Style: Int, CaseIterable {
        case off, bold, italic, monospace, strikethrough, spoiler
    }

    public let style: Style
    public let mixedScript: Bool
    public let uppercase: Bool
    public let zalgoFilter: Bool
    public let formattingToolbar: Bool
    public let sendOnReturnKey: Bool
    public let inAppVibrationEnabled: Bool

    public init(values: [String: Any], legacyDefaults: UserDefaults? = nil) {
        func value(_ key: String) -> Any? {
            return values[key] ?? legacyDefaults?.object(forKey: "wg_" + key)
        }
        func flag(_ key: String) -> Bool {
            guard let number = value(key) as? NSNumber, CFGetTypeID(number) == CFBooleanGetTypeID() else { return false }
            return number.boolValue
        }
        if let number = value("autoFormatStyle") as? NSNumber, CFGetTypeID(number) != CFBooleanGetTypeID(),
           let raw = Int(number.stringValue) {
            self.style = Style(rawValue: raw) ?? (raw > 0 ? .bold : .off)
        } else {
            self.style = .off
        }
        self.mixedScript = flag("autoFormatMixedScript")
        self.uppercase = flag("autoFormatMixedScriptUppercase")
        self.zalgoFilter = flag("zalgoFilterEnabled")
        self.formattingToolbar = flag("formattingToolbarEnabled")
        self.sendOnReturnKey = flag("sendOnReturnKey")
        self.inAppVibrationEnabled = flag("inAppVibrationEnabled")
    }

    public static var current: Self {
        return Self(values: WhitegramPreferences.values(), legacyDefaults: .standard)
    }

    public var selection: Int {
        return self.mixedScript ? (self.uppercase ? 7 : 6) : self.style.rawValue
    }

    public static func selectionChanges(_ selection: Int) -> [String: Any]? {
        guard (0...7).contains(selection) else { return nil }
        return ["autoFormatStyle": selection > 5 ? 0 : selection,
                "autoFormatMixedScript": selection > 5,
                "autoFormatMixedScriptUppercase": selection == 7]
    }

    public func outgoingText(_ text: String, preserving ranges: [Range<Int>] = []) -> String {
        guard self.mixedScript else { return text }
        return Self.applyMixedScript(text, uppercase: self.uppercase, preserving: ranges)
    }

    public func sendOnHardwareReturn(hasModifiers: Bool, commandPressed: Bool, sendWithCommand: Bool) -> Bool {
        return (self.sendOnReturnKey && !hasModifiers) || (sendWithCommand && commandPressed)
    }

    public func sendOnSoftwareReturn(replacement: String, selectionLength: Int, hasMarkedText: Bool, handlingHardwareReturn: Bool = false) -> Bool {
        return self.sendOnReturnKey && replacement == "\n" && selectionLength == 0 && !hasMarkedText && !handlingHardwareReturn
    }

    private static let mixedScriptMap: [Character: Character] = [
        "в": "v", "В": "V", "д": "d", "Д": "D", "з": "z", "З": "Z",
        "к": "k", "л": "l", "Л": "L", "м": "m", "н": "n", "Н": "N",
        "р": "r", "Р": "R", "с": "s", "С": "S", "т": "t", "ф": "f", "Ф": "F"
    ]

    public static func applyMixedScript(_ text: String, uppercase: Bool, preserving ranges: [Range<Int>] = []) -> String {
        let length = text.utf16.count
        let protected = ranges.filter { $0.lowerBound >= 0 && $0.upperBound <= length && !$0.isEmpty }
            .sorted { $0.lowerBound < $1.lowerBound }
        var protectedIndex = 0
        var offset = 0
        var result = ""
        result.reserveCapacity(text.utf8.count)
        for original in text {
            let end = offset + String(original).utf16.count
            while protectedIndex < protected.count && protected[protectedIndex].upperBound <= offset {
                protectedIndex += 1
            }
            let preserve = protectedIndex < protected.count && protected[protectedIndex].lowerBound < end
            offset = end
            if preserve {
                result.append(original)
                continue
            }
            var character = original
            if uppercase {
                let upper = String(original).uppercased()
                if upper.utf16.count == String(original).utf16.count, upper.count == 1, let first = upper.first {
                    character = first
                }
            }
            result.append(Self.mixedScriptMap[character] ?? character)
        }
        return result
    }

    public static func formattingRanges(in text: String, excluding ranges: [Range<Int>]) -> [Range<Int>] {
        let length = text.utf16.count
        guard length > 0 else { return [] }
        var result: [Range<Int>] = []
        var start = 0
        let string = text as NSString
        for rawRange in ranges.sorted(by: { $0.lowerBound < $1.lowerBound }) {
            let range: Range<Int>
            if rawRange.lowerBound >= 0, rawRange.upperBound <= length, !rawRange.isEmpty {
                let expanded = string.rangeOfComposedCharacterSequences(for: NSRange(location: rawRange.lowerBound, length: rawRange.count))
                range = expanded.location..<(expanded.location + expanded.length)
            } else {
                continue
            }
            if start < range.lowerBound { result.append(start..<range.lowerBound) }
            start = max(start, range.upperBound)
        }
        if start < length { result.append(start..<length) }
        return result
    }

    public func stripZalgo(_ text: String) -> String {
        guard self.zalgoFilter else { return text }
        return String(String.UnicodeScalarView(text.unicodeScalars.filter { !WhitegramFilteredText.isRemoved($0) }))
    }

    public func stripZalgo(_ source: NSAttributedString) -> NSAttributedString {
        guard self.zalgoFilter else { return source }
        let filtered = WhitegramFilteredText(source.string)
        guard filtered.text != source.string else { return source }
        let result = NSMutableAttributedString(string: filtered.text)
        source.enumerateAttributes(in: NSRange(location: 0, length: source.length), options: []) { attributes, range, _ in
            if let mapped = filtered.mapRange(range.location..<(range.location + range.length)) {
                result.addAttributes(attributes, range: NSRange(location: mapped.lowerBound, length: mapped.count))
            }
        }
        return result
    }
}

/// Display-only filtering with a UTF-16 boundary map for message entities.
public struct WhitegramFilteredText {
    public let text: String
    private let offsets: [Int?]

    public init(_ source: String) {
        var scalars = String.UnicodeScalarView()
        var offsets: [Int?] = [0]
        var length = 0
        for scalar in source.unicodeScalars {
            let width = scalar.value > 0xffff ? 2 : 1
            if !Self.isRemoved(scalar) {
                scalars.append(scalar)
                length += width
            }
            if width == 2 { offsets.append(nil) }
            offsets.append(length)
        }
        self.text = String(scalars)
        self.offsets = offsets
    }

    static func isRemoved(_ scalar: Unicode.Scalar) -> Bool {
        switch scalar.value {
        case 0x0300...0x036f, 0x1ab0...0x1aff, 0x1dc0...0x1dff, 0xfe20...0xfe2f: return true
        default: return false
        }
    }

    public func mapRange(_ range: Range<Int>) -> Range<Int>? {
        guard range.lowerBound >= 0, range.upperBound < self.offsets.count,
              let lower = self.offsets[range.lowerBound], let upper = self.offsets[range.upperBound], lower < upper else { return nil }
        return lower..<upper
    }
}
