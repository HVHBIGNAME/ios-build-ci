import Foundation
import Postbox
import SwiftSignalKit

// Installed in TelegramCore. This module knows neither SettingsUI nor JSC.
public enum WhitegramPluginHooks {
    public static let eventNames = ["onMessageReceive", "onOutgoingMessage", "onMessageSend", "onChatOpen", "onChatClose", "tg.update", "onUpdates"]
    private static let hub = WhitegramPluginEventHub()
    private static let barrierQueue = DispatchQueue(label: "WhitegramPlugin.CommitBarrier", qos: .utility)
    private static let chatLock = NSLock()
    private static var chats: [String: Chat] = [:]
    private static var chatSequence: UInt64 = 0

    private final class Chat {
        weak var postbox: Postbox?
        let sequence: UInt64
        let payload: [String: Any]

        init(postbox: Postbox, sequence: UInt64, payload: [String: Any]) {
            self.postbox = postbox
            self.sequence = sequence
            self.payload = payload
        }
    }

    public static func subscribe(postbox: Postbox, queue: DispatchQueue, receive: @escaping ([WhitegramPluginEvent], Int) -> Void) -> WhitegramPluginEventSubscription {
        return self.hub.subscribe(scope: postbox, queue: queue, afterTransaction: { [weak postbox] completed in
            // PostboxImpl.transaction publishes its result after internalTransaction
            // commits (Postbox.swift). Starting from this queue also rules out its
            // same-main-queue inline transaction path.
            self.barrierQueue.async {
                guard let postbox = postbox else { completed(); return }
                let _ = postbox.transaction { _ -> Void in }.start(completed: completed)
            }
        }, receive: receive)
    }

    private static func interested(_ postbox: Postbox, _ name: String? = nil) -> Bool {
        return self.hub.hasListeners(scope: postbox, names: [name, "tg.update", "onUpdates"].compactMap { $0 })
    }

    private static func cloudPeer(_ id: PeerId) -> Bool {
        return [Namespaces.Peer.CloudUser, Namespaces.Peer.CloudGroup, Namespaces.Peer.CloudChannel].contains(id.namespace)
    }

    private static func idJSON(_ id: MessageId) -> [String: Any] {
        return ["peerId": String(id.peerId.toInt64()), "id": id.id, "namespace": id.namespace]
    }

    private static func messageJSON(_ message: EngineRawMessage) -> [String: Any] {
        var result = self.idJSON(message.id)
        result["messageId"] = message.id.id
        result["text"] = String(decoding: message.text.utf8.prefix(16384), as: UTF8.self)
        result["textTruncated"] = message.text.utf8.count > 16384
        result["date"] = message.timestamp
        result["outgoing"] = !message.flags.contains(.Incoming)
        result["pending"] = message.flags.contains(.Unsent)
        result["authorId"] = message.author.map { String($0.id.toInt64()) } as Any? ?? NSNull()
        result["threadId"] = message.threadId.map(String.init) as Any? ?? NSNull()
        result["editDate"] = message.editedTime as Any? ?? NSNull()
        result["hasMedia"] = !message.media.isEmpty
        return result
    }

    private static func publish(_ postbox: Postbox, name: String?, type: String, payload: [String: Any], source: String) {
        var payload = payload
        payload["scope"] = "postbox"
        payload["source"] = source
        payload["interceptable"] = false
        if let name = name { self.hub.publish(scope: postbox, name: name, payload: payload) }
        var update = payload
        update["type"] = type
        self.hub.publish(scope: postbox, name: "tg.update", payload: update)
        self.hub.publish(scope: postbox, name: "onUpdates", payload: ["updates": [update], "scope": "postbox", "interceptable": false])
    }

    static func newIncomingIds(postbox: Postbox, transaction: Transaction, messages: [StoreMessage], location: AddMessagesLocation) -> [MessageId] {
        guard self.interested(postbox, "onMessageReceive"), case .UpperHistoryBlock = location else { return [] }
        var seen = Set<MessageId>()
        return messages.compactMap { message in
            guard case let .Id(id) = message.id, id.namespace == Namespaces.Message.Cloud, self.cloudPeer(id.peerId),
                  message.flags.contains(.Incoming), seen.insert(id).inserted, !transaction.messageExists(id: id) else { return nil }
            return id
        }
    }

    static func received(postbox: Postbox, transaction: Transaction, ids: [MessageId]) {
        for id in ids {
            if let message = transaction.getMessage(id) {
                self.publish(postbox, name: "onMessageReceive", type: "messageReceived", payload: self.messageJSON(message), source: "accountState")
            }
        }
    }

    static func enqueued(postbox: Postbox, transaction: Transaction, ids: [MessageId?]) {
        guard self.interested(postbox, "onOutgoingMessage") else { return }
        for id in ids.compactMap({ $0 }) where id.namespace == Namespaces.Message.Local && self.cloudPeer(id.peerId) {
            if let message = transaction.getMessage(id) {
                var payload = self.messageJSON(message)
                payload["queued"] = true
                self.publish(postbox, name: "onOutgoingMessage", type: "messageQueued", payload: payload, source: "enqueue")
            }
        }
    }

    static func sent(postbox: Postbox, transaction: Transaction, localId: MessageId, id: MessageId) {
        guard localId.namespace == Namespaces.Message.Local, id.namespace == Namespaces.Message.Cloud, self.cloudPeer(id.peerId),
              self.interested(postbox, "onMessageSend"), let message = transaction.getMessage(id) else { return }
        var payload = self.messageJSON(message)
        payload["localId"] = self.idJSON(localId)
        payload["sent"] = true
        self.publish(postbox, name: "onMessageSend", type: "messageSent", payload: payload, source: "sendAcknowledgement")
    }

    static func edited(postbox: Postbox, previous: EngineRawMessage, updated: StoreMessage, source: String) {
        guard previous.id.namespace == Namespaces.Message.Cloud, self.cloudPeer(previous.id.peerId), self.interested(postbox) else { return }
        let oldEntities = previous.textEntitiesAttribute?.entities ?? []
        let newEntities = (updated.attributes.first { $0 is TextEntitiesMessageAttribute } as? TextEntitiesMessageAttribute)?.entities ?? []
        let editAttribute = updated.attributes.first { $0 is EditedMessageAttribute } as? EditedMessageAttribute
        let editDate = editAttribute.flatMap { $0.isHidden ? nil : $0.date }
        guard previous.text != updated.text || oldEntities != newEntities || !areMediaArraysEqual(previous.media, updated.media) || previous.editedTime != editDate else { return }
        var payload = self.messageJSON(previous)
        payload["previous"] = self.messageJSON(previous)
        payload["text"] = String(decoding: updated.text.utf8.prefix(16384), as: UTF8.self)
        payload["textTruncated"] = updated.text.utf8.count > 16384
        payload["date"] = updated.timestamp
        payload["editDate"] = editDate as Any? ?? NSNull()
        payload["hasMedia"] = !updated.media.isEmpty
        self.publish(postbox, name: nil, type: "messageEdited", payload: payload, source: source)
    }

    static func deleted(postbox: Postbox, transaction: Transaction, ids: [MessageId], source: String) {
        guard self.interested(postbox) else { return }
        var seen = Set<MessageId>()
        for id in ids where id.namespace == Namespaces.Message.Cloud && self.cloudPeer(id.peerId) && seen.insert(id).inserted {
            // Loaded messages only: a repeated server echo after a local deletion
            // has no second preimage and must not look like a second deletion.
            guard let message = transaction.getMessage(id) else { continue }
            self.publish(postbox, name: nil, type: "messageDeleted", payload: self.messageJSON(message), source: source)
        }
    }

    static func deletingIds(postbox: Postbox, transaction: Transaction, ids: [MessageId]) -> [MessageId] {
        self.deleted(postbox: postbox, transaction: transaction, ids: ids, source: "accountState")
        return ids
    }

    public static func chatOpened(postbox: Postbox, token: String, peerId: PeerId, threadId: Int64?, peer: Peer?) {
        guard self.cloudPeer(peerId) else { return }
        let payload: [String: Any] = ["peerId": String(peerId.toInt64()), "id": String(peerId.toInt64()),
                                     "threadId": threadId.map(String.init) as Any? ?? NSNull(),
                                     "title": peer.map { EnginePeer($0).debugDisplayTitle } ?? "", "viewId": token]
        self.chatLock.lock()
        self.chats = self.chats.filter { $0.value.postbox != nil }
        let previous = self.chats[token]
        if previous == nil {
            self.chatSequence &+= 1
            self.chats[token] = Chat(postbox: postbox, sequence: self.chatSequence, payload: payload)
        }
        self.chatLock.unlock()
        if previous == nil { self.publish(postbox, name: "onChatOpen", type: "chatOpened", payload: payload, source: "visibleChat") }
    }

    public static func chatClosed(postbox: Postbox, token: String) {
        self.chatLock.lock()
        let chat = self.chats[token]?.postbox === postbox ? self.chats.removeValue(forKey: token) : nil
        self.chatLock.unlock()
        if let chat = chat { self.publish(postbox, name: "onChatClose", type: "chatClosed", payload: chat.payload, source: "visibleChat") }
    }

    public static func currentChat(postbox: Postbox) -> [String: Any]? {
        self.chatLock.lock()
        defer { self.chatLock.unlock() }
        return self.chats.values.filter { $0.postbox === postbox }.max { $0.sequence < $1.sequence }?.payload
    }
}
