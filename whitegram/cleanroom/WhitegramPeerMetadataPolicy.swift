import Foundation
import CoreFoundation

public struct WhitegramPeerMetadataSettings: Equatable {
    public let showMutualContactsCard: Bool
    public let showRegistrationDateCard: Bool

    public init(values: [String: Any], legacyDefaults: UserDefaults? = nil) {
        func enabled(_ key: String) -> Bool {
            let value = values[key] ?? legacyDefaults?.object(forKey: "wg_" + key)
            guard let number = value as? NSNumber, CFGetTypeID(number) == CFBooleanGetTypeID() else { return false }
            return number.boolValue
        }
        self.showMutualContactsCard = enabled("showMutualContactsCard")
        self.showRegistrationDateCard = enabled("showRegistrationDateCard")
    }
}

/// A supplied date with its original precision. No account-ID estimation is performed.
public struct WhitegramPeerMetadataDate: Equatable {
    public let year: Int
    public let month: Int
    public let day: Int
    public let exact: Bool

    public init?(year: Int, month: Int, day: Int, exact: Bool) {
        guard (2013...9999).contains(year), (0...12).contains(month), (0...31).contains(day), month != 0 || day == 0 else { return nil }
        if day != 0 {
            var calendar = Calendar(identifier: .gregorian)
            calendar.timeZone = TimeZone(secondsFromGMT: 0)!
            guard let date = calendar.date(from: DateComponents(year: year, month: month, day: day)) else { return nil }
            let components = calendar.dateComponents([.year, .month, .day], from: date)
            guard components.year == year, components.month == month, components.day == day else { return nil }
        }
        self.year = year
        self.month = month
        self.day = day
        self.exact = exact
    }

    public static func telegramMonth(_ value: String?) -> Self? {
        guard let value else { return nil }
        let bytes = Array(value.utf8)
        guard bytes.count == 7, bytes[2] == 46,
              bytes.enumerated().allSatisfy({ $0.offset == 2 || (48...57).contains($0.element) }) else { return nil }
        let month = Int(bytes[0] - 48) * 10 + Int(bytes[1] - 48)
        let year = bytes[3...6].reduce(0) { $0 * 10 + Int($1 - 48) }
        guard month > 0 else { return nil }
        return Self(year: year, month: month, day: 0, exact: true)
    }

    /// monthText receives a one-based month and the full year, for Telegram's localized formatter.
    public func formatted(monthText: (Int, Int) -> String) -> String {
        if exact && day > 0 { return String(format: "%02d.%02d.%04d", day, month, year) }
        let text = month > 0 ? monthText(month, year) : String(year)
        return exact ? text : "~ " + text
    }
}
