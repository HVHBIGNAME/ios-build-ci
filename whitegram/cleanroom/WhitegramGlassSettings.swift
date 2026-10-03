import Foundation
import CoreFoundation

public struct WhitegramGlassSettings: Equatable {
    public enum Toggle: String, CaseIterable {
        case liquidGlassBubbles
        case glassMessageBubbles
        case liquidGlassSettings
        case liquidGlassProfile
        case liquidGlassGifts
        case liquidGlassInlineButtons
        case glassTinting
        case fakeLiquidGlass
        case colorInsteadOfGlass
        case lightChatUI
    }

    public enum Area { case bubbles, settings, profile, gifts, inlineButtons }
    public enum Material { case blur, glass }
    public enum Replacement { case system, telegram, color, blur }

    public static let updatedNotification = Notification.Name("WhitegramSettingsStateUpdated")
    public let classicInterface: Bool
    private let selected: Set<Toggle>

    public init(values: [String: Any], defaults: UserDefaults? = nil) {
        func flag(_ key: String) -> Bool {
            guard let number = (values[key] ?? defaults?.object(forKey: "wg_" + key)) as? NSNumber,
                  CFGetTypeID(number) == CFBooleanGetTypeID() else { return false }
            return number.boolValue
        }
        self.classicInterface = flag("classicInterface")
        self.selected = Set(Toggle.allCases.filter { flag($0.rawValue) })
    }

    public func isSelected(_ toggle: Toggle) -> Bool {
        return self.selected.contains(toggle)
    }

    public func isEnabled(_ toggle: Toggle) -> Bool {
        switch toggle {
        case .glassTinting, .fakeLiquidGlass, .colorInsteadOfGlass, .lightChatUI:
            return self.isSelected(toggle)
        default:
            return !self.classicInterface && self.isSelected(toggle)
        }
    }

    public func material(for area: Area) -> Material? {
        switch area {
        case .bubbles:
            if self.isEnabled(.glassMessageBubbles) { return .glass }
            return self.isEnabled(.liquidGlassBubbles) ? .blur : nil
        case .settings: return self.isEnabled(.liquidGlassSettings) ? .glass : nil
        case .profile: return self.isEnabled(.liquidGlassProfile) ? .glass : nil
        case .gifts: return self.isEnabled(.liquidGlassGifts) ? .glass : nil
        case .inlineButtons: return self.isEnabled(.liquidGlassInlineButtons) ? .glass : nil
        }
    }

    public var hasBubbleSurface: Bool {
        return self.material(for: .bubbles) != nil
    }

    public var replacement: Replacement {
        // Deterministic precedence for imports containing conflicting replacement flags.
        if self.isSelected(.colorInsteadOfGlass) { return .color }
        if self.isSelected(.lightChatUI) { return .blur }
        if self.isSelected(.fakeLiquidGlass) { return .telegram }
        return .system
    }

    public static func changes(for toggle: Toggle, enabled: Bool) -> [String: Any] {
        var changes: [String: Any] = [toggle.rawValue: enabled]
        guard enabled else { return changes }
        switch toggle {
        case .liquidGlassBubbles, .glassMessageBubbles:
            for key in ["liquidGlassBubbles", "glassMessageBubbles", "transparentMessages", "semiTransparentBubbles"] where key != toggle.rawValue {
                changes[key] = false
            }
        case .fakeLiquidGlass, .colorInsteadOfGlass, .lightChatUI:
            for other in [Toggle.fakeLiquidGlass, .colorInsteadOfGlass, .lightChatUI] where other != toggle {
                changes[other.rawValue] = false
            }
        default:
            break
        }
        return changes
    }

    public static var resetValues: [String: Any] {
        return Dictionary(uniqueKeysWithValues: Toggle.allCases.map { ($0.rawValue, false as Any) })
    }

    private static let lock = NSLock()
    private static var cachedData: Data?
    private static var cachedLegacyData: Data?
    private static var cachedValues: [String: Any] = [:]

    private static func dictionary(_ data: Data?) -> [String: Any] {
        guard let data else { return [:] }
        do { return (try JSONSerialization.jsonObject(with: data) as? [String: Any]) ?? [:] }
        catch {
            NSLog("Whitegram: invalid glass settings snapshot (%@)", String(describing: type(of: error)))
            return [:]
        }
    }

    /// Display cannot depend on TelegramCore. Read the same snapshot, then original primitives.
    public static var current: WhitegramGlassSettings {
        lock.lock()
        defer { lock.unlock() }
        let defaults = UserDefaults.standard
        let data = defaults.data(forKey: "WhitegramSettingsState.v1")
        let legacyData = defaults.data(forKey: "WhitegramPrivacySettings.v1")
        if data != cachedData || legacyData != cachedLegacyData {
            cachedData = data
            cachedLegacyData = legacyData
            cachedValues = dictionary(data)
            for (key, value) in dictionary(legacyData) where cachedValues[key] == nil {
                cachedValues[key] = value
            }
        }
        return WhitegramGlassSettings(values: cachedValues, defaults: defaults)
    }
}
