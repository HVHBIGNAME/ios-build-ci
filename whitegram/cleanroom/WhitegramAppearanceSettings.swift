import Foundation
import CoreFoundation
import SwiftSignalKit

public enum WhitegramAppearanceToggle: String, CaseIterable {
    case messageBorderEnabled
    case transparentMessages
    case semiTransparentBubbles
    case showCharCountTyping
    case showCharCountMessages
    case showActionTime
    case hideBusinessBotPanel
}

public struct WhitegramAppearanceSettings: Equatable {
    public static let borderColorKey = "messageBorderColorHex"

    private let enabled: Set<WhitegramAppearanceToggle>
    public let messageBorderColorHex: String

    public init(values: [String: Any], legacyDefaults: UserDefaults? = nil) {
        var enabled = Set<WhitegramAppearanceToggle>()
        for toggle in WhitegramAppearanceToggle.allCases {
            let value = values[toggle.rawValue] ?? legacyDefaults?.object(forKey: "wg_" + toggle.rawValue)
            if let number = value as? NSNumber, CFGetTypeID(number) == CFBooleanGetTypeID(), number.boolValue {
                enabled.insert(toggle)
            }
        }
        self.enabled = enabled
        let color = values[Self.borderColorKey] ?? legacyDefaults?.object(forKey: "wg_" + Self.borderColorKey)
        self.messageBorderColorHex = (color as? String) ?? ""
    }

    public static var current: WhitegramAppearanceSettings {
        return WhitegramAppearanceSettings(values: WhitegramPreferences.values(), legacyDefaults: .standard)
    }

    public func isEnabled(_ toggle: WhitegramAppearanceToggle) -> Bool {
        return self.enabled.contains(toggle)
    }

    public var bubbleFillOpacity: Double {
        if self.isEnabled(.transparentMessages) { return 0.0 }
        if self.isEnabled(.semiTransparentBubbles) { return 0.65 }
        return 1.0
    }

    public var borderRGB: UInt32? {
        guard let hex = Self.normalizedBorderColor(self.messageBorderColorHex), !hex.isEmpty else { return nil }
        return UInt32(hex.dropFirst(), radix: 16)
    }

    /// Empty selects the theme accent; custom colors use opaque, six-digit RGB.
    public static func normalizedBorderColor(_ value: String) -> String? {
        var hex = value.trimmingCharacters(in: .whitespacesAndNewlines)
        if hex.hasPrefix("#") { hex.removeFirst() }
        if hex.isEmpty { return value.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ? "" : nil }
        guard hex.utf8.count == 6, hex.utf8.allSatisfy({ (48...57).contains($0) || (65...70).contains($0) || (97...102).contains($0) }) else { return nil }
        return "#" + hex.uppercased()
    }

    public static func changes(for toggle: WhitegramAppearanceToggle, enabled: Bool) -> [String: Any] {
        var changes: [String: Any] = [toggle.rawValue: enabled]
        if enabled {
            switch toggle {
            case .transparentMessages:
                changes[WhitegramAppearanceToggle.semiTransparentBubbles.rawValue] = false
            case .semiTransparentBubbles:
                changes[WhitegramAppearanceToggle.transparentMessages.rawValue] = false
            default:
                break
            }
        }
        return changes
    }

    public static var resetValues: [String: Any] {
        var values: [String: Any] = [Self.borderColorKey: ""]
        for toggle in WhitegramAppearanceToggle.allCases { values[toggle.rawValue] = false }
        return values
    }

    public func messageStatus(dateText: String, text: String, russian: Bool) -> String {
        guard self.isEnabled(.showCharCountMessages), !text.isEmpty else { return dateText }
        let count = "\(text.count) " + (russian ? "симв." : "chars")
        return dateText.isEmpty ? count : count + " · " + dateText
    }

    public func inputCounter(text: String, limit: Int32?) -> (text: String, isOverLimit: Bool) {
        let count = text.count
        if let limit {
            let remaining = max(-999, Int(limit) - count)
            if remaining < 5 { return (String(remaining), count > Int(limit)) }
        }
        guard self.isEnabled(.showCharCountTyping), !text.isEmpty else { return ("", false) }
        if let limit { return ("\(count) / \(limit)", false) }
        return (String(count), false)
    }

    public static func signal() -> Signal<WhitegramAppearanceSettings, NoError> {
        return Signal { subscriber in
            let observer = NotificationCenter.default.addObserver(forName: WhitegramPreferences.updatedNotification, object: nil, queue: nil) { _ in
                subscriber.putNext(Self.current)
            }
            subscriber.putNext(Self.current)
            return ActionDisposable { NotificationCenter.default.removeObserver(observer) }
        } |> distinctUntilChanged
    }
}
