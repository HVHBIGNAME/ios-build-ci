import Foundation
import Postbox
import SwiftSignalKit

public struct WhitegramHistoryChatSummary {
    public let peerId: String
    public let title: String
    public let deletedCount: Int
    public let editedCount: Int
    public let backupCount: Int
}

public struct WhitegramHistoryOperationResult {
    public var restoredMarkers = 0
    public var clearedEdits = 0
    public var createdTextCopies = 0
    public var skippedLive = 0
    public var skippedExisting = 0
    public var skippedUnavailable = 0
    public var copiesWithoutMedia = 0
    public var cancelled = false
}

private enum WhitegramHistoryNativeError: LocalizedError {
    case accountUnavailable
    case invalidScope
    case invalidBackup

    var errorDescription: String? {
        switch self {
        case .accountUnavailable: return "This Telegram account is no longer available."
        case .invalidScope: return "Invalid history scope."
        case .invalidBackup: return "The history records do not belong to this account or have invalid identities."
        }
    }
}

public enum WhitegramHistoryOperations {
    private static func verify(transaction: Transaction, accountPeerId: PeerId) throws {
        guard (transaction.getState() as? AuthorizedAccountState)?.peerId == accountPeerId else { throw WhitegramHistoryNativeError.accountUnavailable }
    }

    private static func peerIds(transaction: Transaction, scope: WhitegramHistoryScope, records: [WhitegramHistoryEntry]) throws -> [PeerId] {
        if let peerId = scope.peerId {
            guard whitegramHistoryValidPeer(peerId), let raw = Int64(peerId) else { throw WhitegramHistoryNativeError.invalidScope }
            if case let .message(id) = scope, id.namespace != Namespaces.Message.Cloud || id.id <= 0 { throw WhitegramHistoryNativeError.invalidScope }
            return [PeerId(raw)]
        }
        let archived = records.compactMap { entry -> PeerId? in
            guard whitegramHistoryValidPeer(entry.peerId), let raw = Int64(entry.peerId) else { return nil }
            return PeerId(raw)
        }
        return Array(Set(WhitegramHistoryRuntime.knownPeerIds(transaction: transaction)).union(archived)).sorted { $0.toInt64() < $1.toInt64() }
    }

    private static func matches(_ message: Message, scope: WhitegramHistoryScope) -> Bool {
        guard WhitegramHistoryRuntime.isCloudMessage(message) else { return false }
        switch scope {
        case .account: return true
        case let .peer(peerId): return String(message.id.peerId.toInt64()) == peerId
        case let .message(id): return message.id.namespace == id.namespace && message.id.id == id.id && String(message.id.peerId.toInt64()) == id.peerId
        }
    }

    public static func chats(postbox: Postbox, accountPeerId: PeerId, records: [WhitegramHistoryEntry]) -> Signal<Result<[WhitegramHistoryChatSummary], Error>, NoError> {
        return Signal { subscriber in
            let cancelled = Atomic<Bool>(value: false)
            let disposable = postbox.transaction { transaction -> Result<[WhitegramHistoryChatSummary], Error> in
                return Result {
                    try self.verify(transaction: transaction, accountPeerId: accountPeerId)
                    var summaries: [WhitegramHistoryChatSummary] = []
                    let restorable = Dictionary(grouping: whitegramHistoryRestorationEntries(records, scope: .account), by: { $0.peerId })
                    for peerId in try self.peerIds(transaction: transaction, scope: .account, records: records) {
                        if cancelled.with({ $0 }) { break }
                        var deleted = 0
                        var edited = 0
                        transaction.withAllMessages(peerId: peerId, namespace: Namespaces.Message.Cloud) { message in
                            if cancelled.with({ $0 }) { return false }
                            if let attribute = message.whitegramHistoryAttribute {
                                if attribute.isDeleted { deleted += 1 }
                                if !attribute.edits.isEmpty { edited += 1 }
                            }
                            return true
                        }
                        let rawId = String(peerId.toInt64())
                        let backup = restorable[rawId]?.count ?? 0
                        if deleted + edited + backup > 0 {
                            let title = transaction.getPeer(peerId).map { EnginePeer($0).debugDisplayTitle } ?? records.first(where: { $0.peerId == rawId })?.peerTitle ?? rawId
                            summaries.append(WhitegramHistoryChatSummary(peerId: rawId, title: title, deletedCount: deleted, editedCount: edited, backupCount: backup))
                        }
                    }
                    return summaries
                }
            }.start(next: { result in
                if !cancelled.with({ $0 }) { subscriber.putNext(result); subscriber.putCompletion() }
            })
            return ActionDisposable { let _ = cancelled.swap(true); disposable.dispose() }
        }
    }

    public static func message(postbox: Postbox, accountPeerId: PeerId, id: MessageId) -> Signal<Result<Message?, Error>, NoError> {
        return postbox.transaction { transaction in
            return Result {
                try self.verify(transaction: transaction, accountPeerId: accountPeerId)
                return transaction.getMessage(id)
            }
        }
    }

    public static func perform(postbox: Postbox, accountPeerId: PeerId, action: WhitegramHistoryAction, scope: WhitegramHistoryScope, records: [WhitegramHistoryEntry]) -> Signal<Result<WhitegramHistoryOperationResult, Error>, NoError> {
        return Signal { subscriber in
            let cancelled = Atomic<Bool>(value: false)
            let disposable = postbox.transaction { transaction -> Result<WhitegramHistoryOperationResult, Error> in
                return Result {
                    try self.verify(transaction: transaction, accountPeerId: accountPeerId)
                    guard records.allSatisfy({ $0.accountId == String(accountPeerId.toInt64()) && whitegramHistoryValidPeer($0.peerId) && $0.namespace == Namespaces.Message.Cloud && $0.messageId > 0 && ($0.authorId.map(whitegramHistoryValidPeer) ?? true) }) else { throw WhitegramHistoryNativeError.invalidBackup }
                    let peers = try self.peerIds(transaction: transaction, scope: scope, records: records)
                    let savedIds = Set(records.filter { $0.event == .received }.map(\.messageIdentity))
                    var result = WhitegramHistoryOperationResult()
                    var restoredIds = Set<MessageId>()
                    for peerId in peers {
                        if cancelled.with({ $0 }) { result.cancelled = true; break }
                        // Never mutate the table from its enumeration callback.
                        var messages: [Message] = []
                        transaction.withAllMessages(peerId: peerId, namespace: Namespaces.Message.Cloud) { message in
                            if cancelled.with({ $0 }) { return false }
                            if self.matches(message, scope: scope), message.whitegramHistoryAttribute != nil { messages.append(message) }
                            return true
                        }
                        for message in messages {
                            if cancelled.with({ $0 }) { result.cancelled = true; break }
                            guard let attribute = message.whitegramHistoryAttribute else { continue }
                            let replacement: WhitegramHistoryMessageAttribute
                            switch action {
                            case .clearDeletedCache, .restoreChatsView:
                                guard attribute.isDeleted else { continue }
                                replacement = attribute.withDeletion(false)
                                result.restoredMarkers += 1
                                restoredIds.insert(message.id)
                            case .clearEditedCache:
                                guard !attribute.edits.isEmpty else { continue }
                                replacement = attribute.withoutEdits()
                                result.clearedEdits += attribute.edits.count
                            case .clearSavedChatHistory:
                                let identity = WhitegramHistoryMessageId(peerId: String(peerId.toInt64()), namespace: message.id.namespace, id: message.id.id)
                                guard attribute.isDeleted && savedIds.contains(identity) else { continue }
                                replacement = attribute.withDeletion(false)
                                result.restoredMarkers += 1
                            case .exportDeletedBackup, .importDeletedBackup:
                                continue
                            }
                            transaction.updateMessage(message.id) { current in
                                return .update(WhitegramHistoryRuntime.replacingAttribute(current, replacement))
                            }
                        }
                    }
                    if action == .restoreChatsView && !result.cancelled {
                        for entry in whitegramHistoryRestorationEntries(records, scope: scope) {
                            if cancelled.with({ $0 }) { result.cancelled = true; break }
                            guard let rawPeer = Int64(entry.peerId) else { continue }
                            let peerId = PeerId(rawPeer)
                            let id = MessageId(peerId: peerId, namespace: entry.namespace, id: entry.messageId)
                            if restoredIds.contains(id) { continue }
                            if let current = transaction.getMessage(id) {
                                if current.whitegramHistoryAttribute?.isLocallyRestored == true { result.skippedExisting += 1 }
                                else { result.skippedLive += 1 }
                                continue
                            }
                            // Metadata is not an attachment, and a truncated legacy record
                            // cannot be represented as a complete restored message.
                            guard !entry.text.isEmpty, entry.textTruncated != true, transaction.getPeer(peerId) != nil else {
                                result.skippedUnavailable += 1
                                continue
                            }
                            let flags: StoreMessageFlags = entry.outgoing ? [] : [.Incoming]
                            let restored = StoreMessage(id: id, customStableId: nil, globallyUniqueId: nil, groupingKey: nil,
                                threadId: entry.threadId.flatMap(Int64.init), timestamp: entry.messageDate, flags: flags,
                                tags: [], globalTags: [], localTags: [], forwardInfo: nil, authorId: entry.authorId.flatMap(Int64.init).map(PeerId.init),
                                text: entry.text, attributes: [WhitegramHistoryMessageAttribute(isLocallyRestored: true)], media: [])
                            let _ = transaction.addMessages([restored], location: .Random)
                            WhitegramHistoryRuntime.rememberPeer(peerId, transaction: transaction)
                            result.createdTextCopies += 1
                            if entry.mediaCount > 0 { result.copiesWithoutMedia += 1 }
                        }
                    }
                    return result
                }
            }.start(next: { result in
                if !cancelled.with({ $0 }) { subscriber.putNext(result); subscriber.putCompletion() }
            })
            return ActionDisposable { let _ = cancelled.swap(true); disposable.dispose() }
        }
    }
}
