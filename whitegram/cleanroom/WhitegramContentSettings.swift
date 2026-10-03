import Foundation
import CoreFoundation

public struct WhitegramContentReadPolicy {
    public let suppressLocalHistoryRead: Bool
    public let suppressAutomaticReceipts: Bool
    public let suppressActionReceipts: Bool
}

/// Canonical preferences take precedence over the original client's primitive mirrors.
public enum WhitegramContentSettings {
    private static let perChatLock = NSRecursiveLock()
    // Original wgShouldBypassContentRestriction, image 46: 0x236e88.
    private static let preservedRestrictionReasons: Set<String> = ["child_abuse", "child_pornography", "csae", "csam"]
    private static let alwaysBypassedRestrictionReasons: Set<String> = ["pornography", "tos_violation", "apple", "age_restriction"]
    public static let originalDefaults: [String: Bool] = [
        "ghostModeEnabled": false, "alwaysOnline": false,
        "disableOnlineStatus": false, "disableTypingStatus": false,
        "disableRecordingStatus": false, "disableUploadingStatus": false,
        "disableReadReceipts": false, "disableStoryReadReceipts": false,
        "disableAds": false, "saveProtectedContent": false, "removeSpoilers": false,
        "bypassContentRestrictions": true, "keepBannedChats": false,
        "saveViewOnceMedia": false, "warnBeforeCall": false, "readOnAction": false,
        "ghostModeRecordOnce": false, "suggestGhostForStories": false,
        "fakeLocationEnabled": false
    ]

    public static func bool(_ key: String) -> Bool {
        return bool(key, values: WhitegramPreferences.values())
    }

    private static func bool(_ key: String, values: [String: Any]) -> Bool {
        let fallback = originalDefaults[key] ?? false
        let value = values[key] ?? UserDefaults.standard.object(forKey: "wg_" + key)
        guard let number = value as? NSNumber, CFGetTypeID(number) == CFBooleanGetTypeID() else {
            return fallback
        }
        return number.boolValue
    }

    public static func string(_ key: String) -> String {
        let values = WhitegramPreferences.values()
        return ((values[key] ?? UserDefaults.standard.object(forKey: "wg_" + key)) as? String) ?? ""
    }

    public static var saveProtectedContent: Bool { return bool("saveProtectedContent") }
    public static var removeSpoilers: Bool { return bool("removeSpoilers") }
    public static var bypassContentRestrictions: Bool { return bool("bypassContentRestrictions") }
    public static var keepBannedChats: Bool { return bool("keepBannedChats") }
    public static var saveViewOnceMedia: Bool { return bool("saveViewOnceMedia") }
    public static var warnBeforeCall: Bool { return bool("warnBeforeCall") }
    public static var readOnAction: Bool { return bool("readOnAction") }
    public static var shouldSuggestStoryGhost: Bool {
        return bool("suggestGhostForStories") && !bool("disableStoryReadReceipts")
    }

    public static func shouldBypassRestriction(reason: String) -> Bool {
        let reason = reason.lowercased()
        guard !preservedRestrictionReasons.contains(reason) else { return false }
        return bypassContentRestrictions || alwaysBypassedRestrictionReasons.contains(reason)
    }

    public static func parsePerChatGhostIds(_ value: String) -> Set<Int64> {
        return Set(value.split(separator: ",").compactMap { Int64($0.trimmingCharacters(in: .whitespaces)) })
    }

    public static var perChatGhostIds: Set<Int64> { return parsePerChatGhostIds(string("perChatGhost")) }

    @discardableResult
    public static func togglePerChatGhost(id: Int64) -> Bool {
        perChatLock.lock()
        defer { perChatLock.unlock() }
        var ids = perChatGhostIds
        if !ids.insert(id).inserted { ids.remove(id) }
        return WhitegramPreferences.set(ids.sorted().map(String.init).joined(separator: ","), for: "perChatGhost")
    }

    public static func readPolicy(peerId: Int64) -> WhitegramContentReadPolicy {
        let values = WhitegramPreferences.values()
        let perChat = ((values["perChatGhost"] ?? UserDefaults.standard.object(forKey: "wg_perChatGhost")) as? String) ?? ""
        let ghost = bool("ghostModeEnabled", values: values) || parsePerChatGhostIds(perChat).contains(peerId)
        let suppressReceipts = ghost || bool("disableReadReceipts", values: values)
        let onAction = bool("readOnAction", values: values)
        return WhitegramContentReadPolicy(suppressLocalHistoryRead: ghost, suppressAutomaticReceipts: suppressReceipts || onAction, suppressActionReceipts: suppressReceipts || !onAction)
    }

    /// Only explicit UI writes migrate a primitive; merely reading settings never rewrites a store.
    @discardableResult
    public static func set(_ value: Bool, for key: String) -> Bool {
        guard originalDefaults[key] != nil else { return false }
        return WhitegramPreferences.set(value, for: key)
    }
}

/// Resolving an alert twice (or confirming after cancellation) cannot start a second call.
public final class WhitegramContentConfirmation {
    private let lock = NSLock()
    private var action: (() -> Void)?

    public init(action: @escaping () -> Void) { self.action = action }

    public func resolve(confirmed: Bool) {
        _ = resolve(confirmed: confirmed, prepare: { true })
    }

    /// Preparation runs only for the first confirmation, before the protected action.
    @discardableResult
    public func resolve(confirmed: Bool, prepare: () -> Bool) -> Bool {
        lock.lock()
        let action = self.action
        self.action = nil
        lock.unlock()
        guard confirmed, let action else { return true }
        guard prepare() else { return false }
        action()
        return true
    }
}
