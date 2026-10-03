import Foundation

/// Opt-in local attributes survive a server refresh which cannot encode them.
/// Explicit mutations supply their replacement (including an empty replacement).
public protocol WhitegramHistoryPersistentAttribute: MessageAttribute {
    var whitegramPreserveGlobalDeletion: Bool { get }
}

public func whitegramHistoryDeletableGlobalMessageIds(transaction: Transaction, ids: [MessageId]) -> [MessageId] {
    return ids.filter { id in
        guard let message = transaction.getMessage(id) else { return true }
        return !message.attributes.contains { ($0 as? WhitegramHistoryPersistentAttribute)?.whitegramPreserveGlobalDeletion == true }
    }
}

public func whitegramHistoryPreservingAttributes(previous: Message, updated: StoreMessage) -> StoreMessage {
    guard case let .Id(id) = updated.id, id == previous.id else { return updated }
    guard !updated.attributes.contains(where: { $0 is WhitegramHistoryPersistentAttribute }) else { return updated }
    let local = previous.attributes.filter { $0 is WhitegramHistoryPersistentAttribute }
    guard !local.isEmpty else { return updated }
    return updated.withUpdatedAttributes(updated.attributes + local)
}

public func whitegramHistoryPreservingMessages(transaction: Transaction, messages: [StoreMessage]) -> [StoreMessage] {
    return messages.map { updated in
        guard case let .Id(id) = updated.id, let previous = transaction.getMessage(id) else { return updated }
        return whitegramHistoryPreservingAttributes(previous: previous, updated: updated)
    }
}
