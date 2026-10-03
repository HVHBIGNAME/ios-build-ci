import Foundation
import CoreFoundation

/// Value-only policy shared by the native consumers and the regression tests.
public struct WhitegramHistoryPolicy: Hashable {
    public let showDeleted: Bool
    public let showEdited: Bool
    public let saveHistory: Bool
    public let saveDeletedBackup: Bool
    public let deletedOpacity: Double
    public let hiddenDeletedPeers: Set<Int64>
    public let hiddenEditedPeers: Set<Int64>
    private let trackedPeers: Set<Int64>
    private let untrackedPeers: Set<Int64>
    private let hideOwnDeleted: Bool
    private let hideOwnEdited: Bool
    private let hideBotDeleted: Bool
    private let hideBotEdited: Bool

    public init(values: [String: Any]) {
        func flag(_ key: String) -> Bool {
            guard let value = values[key] as? NSNumber, CFGetTypeID(value) == CFBooleanGetTypeID() else { return false }
            return value.boolValue
        }
        func peers(_ key: String, alias: String? = nil) -> Set<Int64> {
            return Self.parsePeerIds((values[key] as? String) ?? alias.flatMap { values[$0] as? String } ?? "")
        }
        self.showDeleted = flag("showDeletedMessages")
        self.showEdited = flag("showEditedOriginalText")
        self.saveHistory = flag("saveChatHistory")
        self.saveDeletedBackup = flag("saveDeletedMessagesToBackup")
        self.hideOwnDeleted = flag("hideMyDeletedMessages")
        self.hideOwnEdited = flag("hideMyEditedMessages")
        self.hideBotDeleted = flag("hideBotDeletedMessages")
        self.hideBotEdited = flag("hideBotEditedMessages")
        self.hiddenDeletedPeers = peers("perChatHideDeleted", alias: "perChatHideDeletedString")
        self.hiddenEditedPeers = peers("perChatHideEdited", alias: "perChatHideEditedString")
        self.trackedPeers = peers("trackedPeerIds")
        self.untrackedPeers = peers("untrackedPeerIds")
        // 3.1.1 getter 0x204124: literals 0xd62188 = .01, 0xd62190 = .45.
        if let number = values["deletedMessagesOpacity"] as? NSNumber,
           CFGetTypeID(number) != CFBooleanGetTypeID(), number.doubleValue.isFinite {
            self.deletedOpacity = min(1.0, max(0.01, number.doubleValue))
        } else {
            self.deletedOpacity = 0.45
        }
    }

    public static func parsePeerIds(_ string: String) -> Set<Int64> {
        return Set(string.split(whereSeparator: { $0 == "," || $0 == ";" || $0.isWhitespace }).compactMap { Int64($0) })
    }

    public func allows(_ event: WhitegramHistoryEvent, peerId: Int64, own: Bool, bot: Bool) -> Bool {
        if event == .received { return true }
        if self.untrackedPeers.contains(peerId) || (!self.trackedPeers.isEmpty && !self.trackedPeers.contains(peerId)) { return false }
        if event == .deleted {
            return !self.hiddenDeletedPeers.contains(peerId) && !(own && self.hideOwnDeleted) && !(bot && self.hideBotDeleted)
        } else {
            return !self.hiddenEditedPeers.contains(peerId) && !(own && self.hideOwnEdited) && !(bot && self.hideBotEdited)
        }
    }

    public func captures(_ event: WhitegramHistoryEvent, peerId: Int64, own: Bool, bot: Bool) -> Bool {
        guard self.allows(event, peerId: peerId, own: own, bot: bot) else { return false }
        switch event {
        case .received: return self.saveHistory
        case .deleted: return self.showDeleted || self.saveDeletedBackup || self.saveHistory
        case .edited: return self.showEdited || self.saveHistory
        }
    }

    public func retainsDeletion(peerId: Int64, own: Bool, bot: Bool, alreadyDeleted: Bool, serverInitiated: Bool) -> Bool {
        // A repeated server update cannot erase a local tombstone. An explicit second
        // local delete is a purge, as in markMessagesAsDeleted(ids:serverInitiated:).
        if alreadyDeleted { return serverInitiated }
        return self.showDeleted && self.allows(.deleted, peerId: peerId, own: own, bot: bot)
    }
}

public enum WhitegramHistoryAction: String, CaseIterable {
    case clearDeletedCache
    case clearEditedCache
    case clearSavedChatHistory
    case restoreChatsView
    case exportDeletedBackup
    case importDeletedBackup
}
