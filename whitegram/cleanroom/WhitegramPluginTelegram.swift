import Foundation
import Postbox
import SwiftSignalKit
import TelegramCore
import AccountContext

enum WhitegramPluginTelegram {
    static func peerId(_ text: String, context: AccountContext) throws -> EnginePeer.Id {
        if text == "me" || text == "self" { return context.account.peerId }
        let parts = text.split(separator: ":", omittingEmptySubsequences: false)
        if parts.count == 2 {
            let namespace: EnginePeer.Id.Namespace
            switch parts[0] {
            case "user": namespace = Namespaces.Peer.CloudUser
            case "group": namespace = Namespaces.Peer.CloudGroup
            case "channel": namespace = Namespaces.Peer.CloudChannel
            default: throw WhitegramPluginError("INVALID_PEER", "Use user:, group: or channel: with a raw Telegram id")
            }
            guard let id = Int64(parts[1]), id > 0, id <= 0x00ffffffffffffff else { throw WhitegramPluginError("INVALID_PEER", "Peer id is outside the supported range") }
            return EnginePeer.Id(namespace: namespace, id: ._internalFromInt64Value(id))
        }
        // Decimal IDs emitted by this bridge are Postbox's packed Int64 IDs,
        // not Bot API -100... IDs. Validate before calling PeerId's asserting init.
        guard let encoded = Int64(text), encoded > 0, encoded <= 0x07ffffffffffffff,
              ((encoded >> 32) & 7) <= 2 else { throw WhitegramPluginError("INVALID_PEER", "Use a peer id returned by getPeer/getChatList, or user:/group:/channel:") }
        let id = EnginePeer.Id(encoded)
        guard id.id._internalGetInt64Value() > 0 else { throw WhitegramPluginError("INVALID_PEER", "Peer id must be nonzero") }
        return id
    }

    static func peerJSON(_ peer: EnginePeer) -> [String: Any] {
        let type: String
        switch peer {
        case .user: type = "user"
        case .legacyGroup: type = "group"
        case .channel: type = "channel"
        case .community: type = "community"
        case .secretChat: type = "secret"
        }
        var result: [String: Any] = [
            "id": String(peer.id.toInt64()), "rawId": String(peer.id.id._internalGetInt64Value()),
            "namespace": peer.id.namespace._internalGetInt32Value(), "type": type,
            "title": peer.debugDisplayTitle, "username": peer.addressName as Any? ?? NSNull(),
            "isVerified": peer.isVerified, "isPremium": peer.isPremium, "isDeleted": peer.isDeleted
        ]
        if case let .user(user) = peer {
            result["firstName"] = user.firstName ?? ""
            result["lastName"] = user.lastName ?? ""
            result["isBot"] = user.botInfo != nil
        }
        return result
    }

    static func messageIdJSON(_ id: EngineMessage.Id) -> [String: Any] {
        return ["peerId": String(id.peerId.toInt64()), "id": id.id, "namespace": id.namespace]
    }

    static func messageJSON(_ message: EngineMessage) -> [String: Any] {
        var result = self.messageIdJSON(message.id)
        result["text"] = message.text
        result["date"] = message.timestamp
        result["outgoing"] = !message.flags.contains(.Incoming)
        result["pending"] = message.flags.contains(.Unsent)
        result["author"] = message.author.map(self.peerJSON) as Any? ?? NSNull()
        result["threadId"] = message.threadId.map(String.init) as Any? ?? NSNull()
        result["media"] = message.media.map { media -> [String: Any] in
            if let file = media as? TelegramMediaFile {
                return ["type": "file", "mimeType": file.mimeType, "name": file.fileName as Any? ?? NSNull(), "size": file.size as Any? ?? NSNull()]
            } else if let contact = media as? TelegramMediaContact {
                return ["type": "contact", "firstName": contact.firstName, "lastName": contact.lastName, "phone": contact.phoneNumber]
            } else if let location = media as? TelegramMediaMap {
                return ["type": "location", "latitude": location.latitude, "longitude": location.longitude]
            } else if let dice = media as? TelegramMediaDice {
                return ["type": "dice", "emoji": dice.emoji, "value": dice.value as Any? ?? NSNull()]
            } else if media is TelegramMediaImage {
                return ["type": "image"]
            } else {
                return ["type": "unsupported", "nativeType": String(describing: Swift.type(of: media))]
            }
        }
        return result
    }

    private static func limit(_ arguments: [Any], _ index: Int, default fallback: Int = 50) throws -> Int {
        let value = try whitegramPluginNumber(arguments, index, default: Double(fallback))
        guard value.rounded() == value, value >= 1, value <= 100 else { throw WhitegramPluginError("INVALID_ARGUMENT", "limit must be an integer from 1 to 100") }
        return Int(value)
    }

    private static func messageId(_ arguments: [Any], _ index: Int, peerId: EnginePeer.Id) throws -> EngineMessage.Id {
        let value = try whitegramPluginNumber(arguments, index)
        guard value.rounded() == value, let id = Int32(exactly: value), id > 0 else { throw WhitegramPluginError("INVALID_ARGUMENT", "Expected a positive cloud message id") }
        return EngineMessage.Id(peerId: peerId, namespace: Namespaces.Message.Cloud, id: id)
    }

    private static func text(_ arguments: [Any], _ index: Int, allowEmpty: Bool = false) throws -> String {
        let text = try whitegramPluginString(arguments, index)
        guard (allowEmpty || !text.isEmpty), text.utf16.count <= 4096 else { throw WhitegramPluginError("INVALID_ARGUMENT", "Message text must contain 1–4096 UTF-16 units") }
        return text
    }

    private static func convert<T, E>(_ signal: Signal<T, E>, _ transform: @escaping (T) throws -> Any) -> Signal<Any, WhitegramPluginError> {
        return Signal { subscriber in
            return signal.start(next: { value in
                do { subscriber.putNext(try transform(value)) }
                catch { subscriber.putError(WhitegramPluginError.wrap(error)) }
            }, error: { error in
                subscriber.putError(WhitegramPluginError("TELEGRAM_ERROR", String(describing: error)))
            }, completed: { subscriber.putCompletion() })
        }
    }

    private static func requirePeer(_ context: AccountContext, _ id: EnginePeer.Id, _ f: @escaping () throws -> Signal<Any, WhitegramPluginError>) -> Signal<Any, WhitegramPluginError> {
        return context.engine.data.get(TelegramEngine.EngineData.Item.Peer.Peer(id: id))
        |> castError(WhitegramPluginError.self)
        |> deliverOnMainQueue
        |> mapToSignal { peer -> Signal<Any, WhitegramPluginError> in
            guard let peer = peer, !peer.isDeleted else { return .fail(WhitegramPluginError("PEER_NOT_FOUND", "Peer is not available in this account; resolve its username first")) }
            do { return try f() }
            catch { return .fail(WhitegramPluginError.wrap(error)) }
        }
    }

    private static func enqueue(_ context: AccountContext, peerId: EnginePeer.Id, message: EnqueueMessage) -> Signal<Any, WhitegramPluginError> {
        return self.convert(enqueueMessages(account: context.account, peerId: peerId, messages: [message])) { ids in
            let actual = ids.compactMap { $0 }
            guard !actual.isEmpty else { throw WhitegramPluginError("ENQUEUE_FAILED", "Telegram did not enqueue the message") }
            return ["queued": true, "messageIds": actual.map(self.messageIdJSON)] as [String: Any]
        }
    }

    private static func outgoing(text: String = "", media: EngineRawMedia? = nil, reply: EngineMessage.Id? = nil) -> EnqueueMessage {
        return .message(text: text, attributes: [], inlineStickers: [:], mediaReference: media.map { .standalone(media: $0) }, threadId: nil,
                        replyToMessageId: reply.map { EngineMessageReplySubject(messageId: $0, quote: nil, innerSubject: nil) },
                        replyToStoryId: nil, localGroupingKey: nil, correlationId: nil, bubbleUpEmojiOrStickersets: [])
    }

    // Called on main; Postbox transactions and URL/file work execute elsewhere.
    static func signal(context: AccountContext, path: String, arguments: [Any], fileData: Data? = nil, isActive: @escaping () -> Bool) throws -> Signal<Any, WhitegramPluginError> {
        dispatchPrecondition(condition: .onQueue(.main))
        guard isActive() else { throw WhitegramPluginError("PLUGIN_STOPPED", "Request was cancelled before it began") }
        if path == "tg.getMe" {
            return self.convert(context.engine.data.get(TelegramEngine.EngineData.Item.Peer.Peer(id: context.account.peerId))) { peer in
                guard let peer = peer else { throw WhitegramPluginError("PEER_NOT_FOUND", "Account profile is unavailable") }
                return self.peerJSON(peer)
            }
        }
        if path == "tg.getChatList" {
            let count = try self.limit(arguments, 0)
            return self.convert(context.engine.messages.chatList(group: .root, count: count) |> take(1)) { list in
                return list.items.compactMap { item -> [String: Any]? in
                    guard let peer = item.renderedPeer.peer else { return nil }
                    var result = self.peerJSON(peer)
                    result["unreadCount"] = item.readCounters?.count ?? 0
                    result["isMuted"] = item.isMuted
                    result["lastMessage"] = item.messages.last.map(self.messageJSON) as Any? ?? NSNull()
                    return result
                }
            }
        }
        let idText = try whitegramPluginString(arguments, 0)
        if path == "tg.getPeer" && idText.hasPrefix("@") {
            return self.convert(context.engine.peers.resolvePeerByName(name: String(idText.dropFirst()), referrer: nil)
                |> filter { if case .result = $0 { return true }; return false }
                |> take(1)) { result in
                guard case let .result(peer) = result, let peer = peer else { throw WhitegramPluginError("PEER_NOT_FOUND", "Username was not found") }
                return self.peerJSON(peer)
            }
        }
        let peerId = try self.peerId(idText, context: context)
        if path == "tg.getPeer" {
            return self.convert(context.engine.data.get(TelegramEngine.EngineData.Item.Peer.Peer(id: peerId))) { peer in
                guard let peer = peer else { throw WhitegramPluginError("PEER_NOT_FOUND", "Peer is not in this account's cache") }
                return self.peerJSON(peer)
            }
        }
        return self.requirePeer(context, peerId) {
            guard isActive() else { return .fail(WhitegramPluginError("PLUGIN_STOPPED", "Plugin stopped before the operation began")) }
            switch path {
            case "tg.getMessages":
                let count = try self.limit(arguments, 1)
                let offset = try whitegramPluginNumber(arguments, 2, default: 0)
                guard offset >= 0, offset.rounded() == offset, let offsetId = Int32(exactly: offset) else { throw WhitegramPluginError("INVALID_ARGUMENT", "offsetId must be a nonnegative cloud message id") }
                return self.convert(context.account.postbox.transaction { transaction -> [EngineRawMessage] in
                    let anchor: EngineHistoryViewInputAnchor = offsetId == 0 ? .upperBound : .message(EngineMessage.Id(peerId: peerId, namespace: Namespaces.Message.Cloud, id: offsetId))
                    let view = transaction.getMessagesHistoryViewState(input: .single(peerId: peerId, threadId: nil), ignoreMessagesInTimestampRange: nil,
                        ignoreMessageIds: Set(), count: count * 2 + 2, clipHoles: false, anchor: anchor, namespaces: .just([Namespaces.Message.Cloud]))
                    return Array(view.entries.map { $0.message }.filter { offsetId == 0 || $0.id.id < offsetId }.sorted { $0.index > $1.index }.prefix(count))
                }) { messages in messages.map { self.messageJSON(EngineMessage($0)) } }
            case "tg.getMessage":
                let id = try self.messageId(arguments, 1, peerId: peerId)
                return self.convert(context.engine.messages.downloadMessage(messageId: id)) { message in
                    guard let message = message else { throw WhitegramPluginError("MESSAGE_NOT_FOUND", "Message is unavailable") }
                    return self.messageJSON(message)
                }
            case "tg.sendTextMessage":
                return self.enqueue(context, peerId: peerId, message: self.outgoing(text: try self.text(arguments, 1)))
            case "tg.reply":
                let id = try self.messageId(arguments, 1, peerId: peerId)
                return self.enqueue(context, peerId: peerId, message: self.outgoing(text: try self.text(arguments, 2), reply: id))
            case "tg.sendDiceMessage":
                let emoji = arguments.count > 1 ? try whitegramPluginString(arguments, 1) : "🎲"
                guard ["🎲", "🎯", "🏀", "⚽", "🎳", "🎰"].contains(emoji) else { throw WhitegramPluginError("INVALID_ARGUMENT", "Unsupported dice emoji") }
                return self.enqueue(context, peerId: peerId, message: self.outgoing(media: TelegramMediaDice(emoji: emoji)))
            case "tg.sendLocationMessage":
                let latitude = try whitegramPluginNumber(arguments, 1)
                let longitude = try whitegramPluginNumber(arguments, 2)
                guard (-90 ... 90).contains(latitude), (-180 ... 180).contains(longitude) else { throw WhitegramPluginError("INVALID_ARGUMENT", "Coordinates are out of range") }
                return self.enqueue(context, peerId: peerId, message: self.outgoing(media: TelegramMediaMap(latitude: latitude, longitude: longitude, heading: nil, accuracyRadius: nil, venue: nil)))
            case "tg.sendContactMessage":
                let first = try whitegramPluginString(arguments, 1)
                let last = try whitegramPluginString(arguments, 2)
                let phone = try whitegramPluginString(arguments, 3)
                guard first.count <= 256, last.count <= 256, !phone.isEmpty, phone.count <= 64 else { throw WhitegramPluginError("INVALID_ARGUMENT", "Invalid contact fields") }
                let contact = TelegramMediaContact(firstName: first, lastName: last, phoneNumber: phone, peerId: nil, vCardData: nil)
                return self.enqueue(context, peerId: peerId, message: self.outgoing(media: contact))
            case "tg.sendFileMessage":
                guard let data = fileData else { throw WhitegramPluginError("FILE_NOT_FOUND", "Plugin file is unavailable") }
                let path = try whitegramPluginString(arguments, 1)
                let name = ((path.hasPrefix("package:") ? String(path.dropFirst(8)) : path) as NSString).lastPathComponent
                let caption = arguments.count > 2 ? try self.text(arguments, 2, allowEmpty: true) : ""
                let mimeType = arguments.count > 3 ? try whitegramPluginString(arguments, 3) : ""
                guard data.count <= WhitegramPluginStorage.maximumFileBytes, mimeType.utf8.count <= 255,
                      !mimeType.unicodeScalars.contains(where: { $0.value < 32 || $0.value == 127 }) else { throw WhitegramPluginError("INVALID_ARGUMENT", "Invalid file size or MIME type") }
                let resource = LocalFileMediaResource(fileId: Int64.random(in: 1 ... Int64.max), size: Int64(data.count))
                context.account.postbox.mediaBox.storeResourceData(resource.id, data: data)
                let file = TelegramMediaFile(fileId: MediaId(namespace: Namespaces.Media.LocalFile, id: resource.fileId), partialReference: nil,
                    resource: resource, previewRepresentations: [], videoThumbnails: [], immediateThumbnailData: nil,
                    mimeType: mimeType.isEmpty ? "application/octet-stream" : mimeType, size: Int64(data.count), attributes: [.FileName(fileName: name)], alternativeRepresentations: [])
                return self.enqueue(context, peerId: peerId, message: self.outgoing(text: caption, media: file))
            case "tg.forwardMessage":
                let id = try self.messageId(arguments, 1, peerId: peerId)
                let destination = try self.peerId(whitegramPluginString(arguments, 2), context: context)
                return self.requirePeer(context, destination) {
                    guard isActive() else { return .fail(WhitegramPluginError("PLUGIN_STOPPED", "Plugin stopped")) }
                    return self.enqueue(context, peerId: destination, message: .forward(source: id, threadId: nil, grouping: .none, attributes: [], correlationId: nil))
                }
            case "tg.editMessage":
                let id = try self.messageId(arguments, 1, peerId: peerId)
                return self.convert(context.engine.messages.requestEditMessage(messageId: id, text: try self.text(arguments, 2), media: .keep,
                    entities: nil, richText: nil, inlineStickers: [:]) |> filter { if case .done = $0 { return true }; return false } |> take(1)) { result in
                    guard case let .done(ok) = result, ok else { throw WhitegramPluginError("EDIT_FAILED", "Telegram did not edit the message") }
                    return ["updated": true]
                }
            case "tg.deleteMessage":
                let id = try self.messageId(arguments, 1, peerId: peerId)
                let everyone = try whitegramPluginBool(arguments, 2, default: false)
                return self.convert(context.engine.messages.deleteMessagesInteractively(messageIds: [id], type: everyone ? .forEveryone : .forLocalPeer)) { _ in ["queued": true] }
            case "tg.pinMessage":
                let id = try self.messageId(arguments, 1, peerId: peerId)
                let pinned = try whitegramPluginBool(arguments, 2)
                return self.convert(context.engine.messages.requestUpdatePinnedMessage(peerId: peerId,
                    update: pinned ? .pin(id: id, silent: true, forThisPeerOnlyIfPossible: false) : .clear(id: id))) { _ in ["updated": true] }
            case "tg.reactToMessage":
                let id = try self.messageId(arguments, 1, peerId: peerId)
                let emoji = try whitegramPluginString(arguments, 2)
                guard emoji.count <= 16 else { throw WhitegramPluginError("INVALID_ARGUMENT", "Reaction is too long") }
                return context.account.postbox.transaction { transaction in transaction.getMessage(id) != nil }
                |> castError(WhitegramPluginError.self)
                |> deliverOnMainQueue
                |> mapToSignal { exists -> Signal<Any, WhitegramPluginError> in
                    guard exists else { return .fail(WhitegramPluginError("MESSAGE_NOT_FOUND", "Load the message before reacting to it")) }
                    guard isActive() else { return .fail(WhitegramPluginError("PLUGIN_STOPPED", "Plugin stopped")) }
                    let signal = updateMessageReactionsInteractively(account: context.account, messageIds: [id], reactions: emoji.isEmpty ? [] : [.builtin(emoji)],
                        isLarge: false, storeAsRecentlyUsed: false) |> map { _ -> Any in } |> then(Signal<Any, NoError>.single(["queued": true]))
                    return self.convert(signal) { $0 }
                }
            case "tg.markChatAsRead":
                let signal = context.account.postbox.transaction { transaction -> EngineMessage.Index? in
                    let view = transaction.getMessagesHistoryViewState(input: .single(peerId: peerId, threadId: nil), ignoreMessagesInTimestampRange: nil,
                        ignoreMessageIds: Set(), count: 1, clipHoles: false, anchor: .upperBound, namespaces: .just([Namespaces.Message.Cloud]))
                    return view.entries.last?.message.index
                } |> deliverOnMainQueue |> mapToSignal { index -> Signal<Void, NoError> in
                    guard isActive(), let index = index else { return .complete() }
                    return context.engine.messages.applyMaxReadIndexInteractively(index: index)
                }
                return self.convert(signal) { _ in ["queued": true] }
            case "tg.openChat":
                context.sharedContext.navigateToChat(accountId: context.account.id, peerId: peerId, messageId: nil)
                return .single(["requested": true])
            default: return .fail(WhitegramPluginError("UNSUPPORTED_API", path))
            }
        }
    }

    static func watch(context: AccountContext, peer: String, count: Int) throws -> Signal<Any, WhitegramPluginError> {
        let id = try self.peerId(peer, context: context)
        guard count >= 1, count <= 100 else { throw WhitegramPluginError("INVALID_ARGUMENT", "Watch limit must be 1–100") }
        return self.requirePeer(context, id) {
            return self.convert(context.account.postbox.aroundMessageHistoryViewForLocation(.peer(peerId: id, threadId: nil), anchor: .upperBound, ignoreMessagesInTimestampRange: nil,
                ignoreMessageIds: Set(), count: count, trackHoles: false, clipHoles: false, ignoreRelatedChats: true,
                fixedCombinedReadStates: nil, topTaggedMessageIdNamespaces: [], tag: nil, appendMessagesFromTheSameGroup: false,
                namespaces: .just([Namespaces.Message.Cloud]), orderStatistics: [])) { view in
                return ["peerId": String(id.toInt64()), "messages": view.0.entries.reversed().map { self.messageJSON(EngineMessage($0.message)) }, "scope": "local"] as [String: Any]
            }
        }
    }
}
