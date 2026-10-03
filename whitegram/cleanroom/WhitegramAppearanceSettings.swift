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
    public let policy: WhitegramAppearancePolicy
    public let localStars: WhitegramLocalStars

    public init(values: [String: Any], legacyDefaults: UserDefaults? = nil) {
        self.policy = WhitegramAppearancePolicy(values: values, legacyDefaults: legacyDefaults)
        self.localStars = WhitegramLocalStars(values: values, legacyDefaults: legacyDefaults)
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
        return WhitegramAppearancePolicy.bubbleFillOpacity(transparent: self.isEnabled(.transparentMessages), semiTransparent: self.isEnabled(.semiTransparentBubbles))
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
                changes["liquidGlassBubbles"] = false
                changes["glassMessageBubbles"] = false
            case .semiTransparentBubbles:
                changes[WhitegramAppearanceToggle.transparentMessages.rawValue] = false
                changes["liquidGlassBubbles"] = false
                changes["glassMessageBubbles"] = false
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
        return WhitegramAppearancePolicy.messageStatus(enabled: self.isEnabled(.showCharCountMessages), dateText: dateText, text: text, russian: russian)
    }

    public func inputCounter(text: String, limit: Int32?) -> (text: String, isOverLimit: Bool) {
        return WhitegramAppearancePolicy.inputCounter(enabled: self.isEnabled(.showCharCountTyping), text: text, limit: limit)
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
