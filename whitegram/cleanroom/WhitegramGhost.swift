import Foundation

/// Reads the Whitegram settings written by the settings UI.
///
/// This lives in TelegramCore because the network paths that must honour the ghost
/// switches are compiled into that module, and TelegramCore cannot depend on
/// TelegramUIPreferences. Storage is read-only here; writes go through the settings
/// screen in TelegramUIPreferences.
public enum WhitegramGhost {
    private static let storageKey = "WhitegramSettingsState.v1"

    private struct State: Decodable {
        let ghostModeEnabled: Bool?
        let disableOnlineStatus: Bool?
        let disableTypingStatus: Bool?
        let disableReadReceipts: Bool?
    }

    private static let flags: State? = {
        guard let data = UserDefaults.standard.data(forKey: storageKey) else {
            return nil
        }
        return try? JSONDecoder().decode(State.self, from: data)
    }()

    private static func enabled(_ keyPath: KeyPath<State, Bool?>) -> Bool {
        guard let flags else {
            return false
        }
        let specific = flags[keyPath: keyPath] ?? false
        let ghost = flags.ghostModeEnabled ?? false
        return specific || ghost
    }

    /// Ghost mode is the master switch for the three activity indicators.
    public static var suppressOnlineStatus: Bool {
        return enabled(\.disableOnlineStatus)
    }

    public static var suppressTypingStatus: Bool {
        return enabled(\.disableTypingStatus)
    }

    public static var suppressReadReceipts: Bool {
        return enabled(\.disableReadReceipts)
    }
}
