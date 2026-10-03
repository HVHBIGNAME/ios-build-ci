import Foundation
import CoreFoundation

/// A presentation override only. Never pass this value to a payment or balance context.
public struct WhitegramLocalStars: Equatable {
    public let enabled: Bool
    public let count: Int64
    public static let defaultCount: Int64 = 9999
    public static let sliderRange: ClosedRange<Int64> = 1 ... 9999
    public static let inputRange: ClosedRange<Int64> = 1 ... 9_999_999

    public init(values: [String: Any], legacyDefaults: UserDefaults? = nil) {
        self.enabled = WhitegramAppearancePolicy.boolean(values["localStarsEnabled"] ?? legacyDefaults?.object(forKey: "wg_localStarsEnabled"))
        let value = values["localStarsCount"] ?? legacyDefaults?.object(forKey: "wg_localStarsCount")
        if let count = Self.integer(value), count > 0 {
            self.count = count
        } else {
            self.count = Self.defaultCount
        }
    }

    public static var current: WhitegramLocalStars {
        return WhitegramLocalStars(values: WhitegramPreferences.values(), legacyDefaults: .standard)
    }

    public static func parseCount(_ text: String) -> Int64? {
        let text = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let count = Int64(text), Self.inputRange.contains(count) else { return nil }
        return count
    }

    private static func integer(_ value: Any?) -> Int64? {
        guard let number = value as? NSNumber, CFGetTypeID(number) != CFBooleanGetTypeID(), number.doubleValue.isFinite else { return nil }
        if let value = Int64(number.stringValue) { return value }
        return Int64(exactly: number.doubleValue)
    }

    public func displayBalance(_ actual: StarsAmount) -> StarsAmount {
        return self.enabled ? StarsAmount(value: self.count, nanos: 0) : actual
    }
}
