import Foundation
import Postbox
import SwiftSignalKit

private struct WhitegramHistoryPeerIndex: Codable {
    var peerIds: Set<Int64>
}

public enum WhitegramHistoryRuntime {
    private static let peerIndexKey = ValueBoxKey("Whitegram.History.PeerIndex.v1")

    public static var policy: WhitegramHistoryPolicy {
        var values = WhitegramPreferences.values()
        // These keys are present in original 3.1.1 but not in the old generated state.
        for key in ["perChatHideDeleted", "perChatHideEdited", "trackedPeerIds", "untrackedPeerIds"] where values[key] == nil {
            if let value = UserDefaults.standard.string(forKey: "wg_" + key) { values[key] = value }
        }
        return WhitegramHistoryPolicy(values: values)
    }

    static func rememberPeer(_ peerId: PeerId, transaction: Transaction) {
        var index = transaction.getPreferencesEntry(key: self.peerIndexKey)?.get(WhitegramHistoryPeerIndex.self) ?? WhitegramHistoryPeerIndex(peerIds: [])
        if index.peerIds.insert(peerId.toInt64()).inserted {
            transaction.setPreferencesEntry(key: self.peerIndexKey, value: PreferencesEntry(index))
        }
    }

    static func knownPeerIds(transaction: Transaction) -> [PeerId] {
        let index = transaction.getPreferencesEntry(key: self.peerIndexKey)?.get(WhitegramHistoryPeerIndex.self)
        return Array(Set(transaction.chatListGetAllPeerIds()).union((index?.peerIds ?? []).map(PeerId.init))).sorted { $0.toInt64() < $1.toInt64() }
    }

    public static func isCloudMessage(_ message: Message) -> Bool {
        return message.id.namespace == Namespaces.Message.Cloud && message.id.id > 0 &&
            [Namespaces.Peer.CloudUser, Namespaces.Peer.CloudGroup, Namespaces.Peer.CloudChannel].contains(message.id.peerId.namespace) &&
            !message.media.contains(where: { $0 is TelegramMediaAction })
    }

    static func own(_ message: Message, accountPeerId: PeerId) -> Bool {
        return message.author?.id == accountPeerId || !message.flags.contains(.Incoming) || message.id.peerId == accountPeerId
    }

    static func bot(_ message: Message) -> Bool {
        return (message.author as? TelegramUser)?.botInfo != nil
    }

    static func replacingAttribute(_ message: Message, _ attribute: WhitegramHistoryMessageAttribute) -> StoreMessage {
        return StoreMessage(id: message.id, customStableId: nil, globallyUniqueId: message.globallyUniqueId,
            groupingKey: message.groupingKey, threadId: message.threadId, timestamp: message.timestamp,
            flags: StoreMessageFlags(message.flags), tags: message.tags, globalTags: message.globalTags, localTags: message.localTags,
            forwardInfo: message.forwardInfo.map(StoreMessageForwardInfo.init), authorId: message.author?.id, text: message.text,
            attributes: message.attributes.filter { !($0 is WhitegramHistoryMessageAttribute) } + [attribute], media: message.media)
    }

    public static func deletableIds(transaction: Transaction, mediaBox: MediaBox, ids: [MessageId], serverInitiated: Bool) -> [MessageId] {
        guard let accountPeerId = (transaction.getState() as? AuthorizedAccountState)?.peerId else { return ids }
        let policy = self.policy
        var result: [MessageId] = []
        var seen = Set<MessageId>()
        for id in ids where seen.insert(id).inserted {
            guard let message = transaction.getMessage(id), self.isCloudMessage(message) else { result.append(id); continue }
            let attribute = message.whitegramHistoryAttribute ?? WhitegramHistoryMessageAttribute()
            if !attribute.isDeleted {
                WhitegramHistoryStore.capture(message, event: .deleted, accountPeerId: accountPeerId, mediaBoxPath: mediaBox.basePath)
            }
            if policy.retainsDeletion(peerId: id.peerId.toInt64(), own: self.own(message, accountPeerId: accountPeerId), bot: self.bot(message), alreadyDeleted: attribute.isDeleted, serverInitiated: serverInitiated) {
                if !attribute.isDeleted {
                    let now = Int32(clamping: Int64(Date().timeIntervalSince1970))
                    transaction.updateMessage(id) { current in
                        return .update(self.replacingAttribute(current, attribute.withDeletion(true, at: now)))
                    }
                    self.rememberPeer(id.peerId, transaction: transaction)
                }
            } else {
                result.append(id)
            }
        }
        return result
    }

    public static func prepareGlobalDeletion(transaction: Transaction, mediaBox: MediaBox, ids: [Int32]) {
        let knownIds = transaction.messageIdsForGlobalIds(ids)
        let _ = self.deletableIds(transaction: transaction, mediaBox: mediaBox, ids: knownIds, serverInitiated: true)
    }

    public static func observeBeforeClear(transaction: Transaction, mediaBox: MediaBox, peerId: PeerId, threadId: Int64?, namespaces: MessageIdNamespaces, minTimestamp: Int32? = nil, maxTimestamp: Int32? = nil) {
        guard let accountPeerId = (transaction.getState() as? AuthorizedAccountState)?.peerId,
              self.policy.saveHistory || self.policy.saveDeletedBackup else { return }
        transaction.withAllMessages(peerId: peerId) { message in
            guard self.isCloudMessage(message), namespaces.contains(message.id.namespace),
                  threadId == nil || threadId == message.threadId,
                  minTimestamp.map({ message.timestamp >= $0 }) ?? true,
                  maxTimestamp.map({ message.timestamp <= $0 }) ?? true else { return true }
            WhitegramHistoryStore.capture(message, event: .deleted, accountPeerId: accountPeerId, mediaBoxPath: mediaBox.basePath)
            return true
        }
    }

    public static func preserveMinimumAvailable(transaction: Transaction, mediaBox: MediaBox, id: MessageId) -> Bool {
        guard id.namespace == Namespaces.Message.Cloud, id.peerId.namespace == Namespaces.Peer.CloudChannel,
              self.policy.showDeleted || self.policy.saveHistory else { return false }
        var ids: [MessageId] = []
        transaction.withAllMessages(peerId: id.peerId, namespace: id.namespace) { message in
            if message.id.id <= id.id && self.isCloudMessage(message) { ids.append(message.id) }
            return true
        }
        // Unlike simply skipping the range, marker/filter behavior remains consistent
        // with individual server deletions. History-only mode still saves text first.
        let removable = self.deletableIds(transaction: transaction, mediaBox: mediaBox, ids: ids, serverInitiated: true)
        if !self.policy.saveHistory { transaction.deleteMessages(removable, forEachMedia: nil) }
        return true
    }

    public static func hasEntityChanges(_ previous: Message, _ updated: [MessageAttribute]) -> Bool {
        return (previous.textEntitiesAttribute?.entities ?? []) != ((updated.first(where: { $0 is TextEntitiesMessageAttribute }) as? TextEntitiesMessageAttribute)?.entities ?? [])
    }

    public static func recordEdit(previous: Message, updated: StoreMessage, accountPeerId: PeerId, mediaBoxPath: String) -> StoreMessage {
        guard self.isCloudMessage(previous), case let .Id(id) = updated.id, id == previous.id else { return updated }
        let previousEntities = previous.textEntitiesAttribute?.entities ?? []
        let updatedEntities = (updated.attributes.first(where: { $0 is TextEntitiesMessageAttribute }) as? TextEntitiesMessageAttribute)?.entities ?? []
        let changed = previous.text != updated.text || previousEntities != updatedEntities || WhitegramHistoryStore.hasMediaChanges(previous.media, updated.media)
        var attribute = previous.whitegramHistoryAttribute
        let policy = self.policy
        if changed && policy.captures(.edited, peerId: id.peerId.toInt64(), own: self.own(previous, accountPeerId: accountPeerId), bot: self.bot(previous)) {
            attribute = (attribute ?? WhitegramHistoryMessageAttribute()).appending(WhitegramHistoryEdit(text: previous.text, entities: previousEntities, date: previous.editedTime ?? previous.timestamp))
        }
        guard let attribute else { return updated }
        return updated.withUpdatedAttributes(updated.attributes.filter { !($0 is WhitegramHistoryMessageAttribute) } + [attribute])
    }

    public static func shouldDisplay(_ message: Message, accountPeerId: PeerId) -> Bool {
        guard message.whitegramHistoryAttribute?.isDeleted == true else { return true }
        let policy = self.policy
        return policy.showDeleted && policy.allows(.deleted, peerId: message.id.peerId.toInt64(), own: self.own(message, accountPeerId: accountPeerId), bot: self.bot(message))
    }

    public static func displayOpacity(_ message: Message, accountPeerId: PeerId) -> Double {
        guard message.whitegramHistoryAttribute?.isDeleted == true, self.shouldDisplay(message, accountPeerId: accountPeerId) else { return 1.0 }
        return self.policy.deletedOpacity
    }

    public static func originalForDisplay(_ message: Message, accountPeerId: PeerId) -> WhitegramHistoryEdit? {
        let policy = self.policy
        guard policy.showEdited, policy.allows(.edited, peerId: message.id.peerId.toInt64(), own: self.own(message, accountPeerId: accountPeerId), bot: self.bot(message)),
              let edit = message.whitegramHistoryAttribute?.edits.first, !edit.text.isEmpty,
              edit.text != message.text || edit.entities != (message.textEntitiesAttribute?.entities ?? []) else { return nil }
        return edit
    }

    public static func displayMessage(_ message: Message) -> Message {
        guard message.whitegramHistoryAttribute != nil else { return message }
        // Only the rendered revision changes. Server identity, timestamp, order and
        // persisted stableVersion are untouched. This invalidates list-item layouts
        // when the opacity/visibility/original-text preferences change.
        return message.withUpdatedStableVersion(stableVersion: message.stableVersion &+ UInt32(truncatingIfNeeded: self.policy.hashValue))
    }

    public static func statusText(_ text: String, message: Message, accountPeerId: PeerId, russian: Bool) -> String {
        guard let attribute = message.whitegramHistoryAttribute else { return text }
        let prefix: String
        if attribute.isDeleted && self.shouldDisplay(message, accountPeerId: accountPeerId) {
            prefix = russian ? "Удалено" : "Deleted"
        } else if attribute.isLocallyRestored {
            prefix = russian ? "Локальная копия" : "Local copy"
        } else if !attribute.edits.isEmpty && self.policy.showEdited && self.policy.allows(.edited, peerId: message.id.peerId.toInt64(), own: self.own(message, accountPeerId: accountPeerId), bot: self.bot(message)) {
            prefix = "↶"
        } else {
            return text
        }
        return text.isEmpty ? prefix : "\(prefix) · \(text)"
    }
}

public func whitegramHistorySettingsSignal() -> Signal<Bool, NoError> {
    return Signal { subscriber in
        let observer = NotificationCenter.default.addObserver(forName: WhitegramPreferences.updatedNotification, object: nil, queue: nil) { _ in
            subscriber.putNext(true)
        }
        subscriber.putNext(true)
        return ActionDisposable { NotificationCenter.default.removeObserver(observer) }
    }
}
