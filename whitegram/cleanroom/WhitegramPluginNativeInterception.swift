import Foundation
import Postbox
import TelegramApi
import SwiftSignalKit
import MtProtoKit

public enum WhitegramPluginNativeInterception {
    public static let eventNames = ["tg.request", "postRequest", "tg.response", "tg.request.completed"]
    private static let events = WhitegramPluginEventHub()

    public static func subscribe(network: Network, queue: DispatchQueue, receive: @escaping ([WhitegramPluginEvent], Int) -> Void) -> WhitegramPluginEventSubscription {
        return self.events.subscribe(scope: network, queue: queue, afterTransaction: { $0() }, receive: receive)
    }

    private static func requestPayload(network: Network, description: FunctionDescription, kind: String) -> [String: Any] {
        var params: [String: String] = [:]
        // Match the original printable parameter envelope, not a live TL object
        // or an arbitrary invocation API. Authentication fields stay private.
        let privateNames: Set<String> = ["api_hash", "phone_code", "password", "code", "token", "access_hash", "bot_auth_token", "secret", "data"]
        for (key, value) in description.parameters.prefix(64) {
            if privateNames.contains(key) || description.name.hasPrefix("auth.") {
                params[key] = "<private>"
            } else {
                params[key] = String(decoding: String(describing: value.value ?? "nil").utf8.prefix(1024), as: UTF8.self)
            }
        }
        return ["kind": kind, "method": description.name, "shortName": description.name, "name": description.name,
                "params": params, "dcId": network.datacenterId, "datacenterId": network.datacenterId,
                "interceptable": kind == "request", "canModify": false, "supportsDeferred": false]
    }

    static func request(network: Network, description: FunctionDescription) -> Signal<Bool, MTRpcError> {
        return Signal { subscriber in
            let hub = WhitegramPluginInterceptionHub.shared
            let observing = self.events.hasListeners(scope: network, names: ["tg.request"])
            let intercepting = hub.hasHandlers(scope: network, name: "tg.request")
            if !observing && !intercepting { subscriber.putNext(true); subscriber.putCompletion(); return EmptyDisposable }
            let payload = self.requestPayload(network: network, description: description, kind: "request")
            var observation = payload
            observation["interceptable"] = false
            self.events.publish(scope: network, name: "tg.request", payload: observation)
            let token = hub.intercept(scope: network, name: "tg.request", payload: payload) { decision in
                if decision.cancelled {
                    // Original Network.request returns this actual RPC error,
                    // before adding MTRequest to its service (image 46, 0x1a500c).
                    subscriber.putError(MTRpcError(errorCode: 499, errorDescription: "WHITEGRAM_PLUGIN_CANCELLED"))
                } else { subscriber.putNext(true); subscriber.putCompletion() }
            }
            return ActionDisposable { token.dispose() }
        }
    }

    static func response(network: Network, description: FunctionDescription, error: MTRpcError?) {
        guard self.events.hasListeners(scope: network, names: self.eventNames) else { return }
        var payload = self.requestPayload(network: network, description: description, kind: "response")
        payload["ok"] = error == nil
        payload["error"] = error.map { ["code": $0.errorCode, "description": $0.errorDescription ?? ""] as [String: Any] } as Any? ?? NSNull()
        payload["interceptable"] = false
        for name in ["postRequest", "tg.response", "tg.request.completed"] { self.events.publish(scope: network, name: name, payload: payload) }
    }

    static func outgoing(account: Account, peerId: PeerId, messages: [EnqueueMessage]) -> Signal<[EnqueueMessage]?, NoError> {
        let hub = WhitegramPluginInterceptionHub.shared
        guard [Namespaces.Peer.CloudUser, Namespaces.Peer.CloudGroup, Namespaces.Peer.CloudChannel].contains(peerId.namespace),
              hub.hasHandlers(scope: account.postbox, name: "message.beforeSend") else { return .single(messages) }
        var signal: Signal<[EnqueueMessage]?, NoError> = .single([])
        for message in messages {
            signal = signal |> mapToSignal { current -> Signal<[EnqueueMessage]?, NoError> in
                guard let current = current else { return .single(nil) }
                guard case let .message(text, attributes, inlineStickers, media, threadId, reply, story, grouping, correlation, bubbleUp) = message,
                      !attributes.contains(where: { $0 is OutgoingScheduleInfoMessageAttribute || $0 is OutgoingQuickReplyMessageAttribute }) else {
                    return .single(current + [message])
                }
                return Signal { subscriber in
                    let payload: [String: Any] = ["peerId": String(peerId.toInt64()), "text": text,
                        "threadId": threadId.map(String.init) as Any? ?? NSNull(),
                        "replyToMessageId": reply.map { $0.messageId.id } as Any? ?? NSNull(),
                        "interceptable": true, "supportsDeferred": false]
                    let token = hub.intercept(scope: account.postbox, name: "message.beforeSend", payload: payload) { decision in
                        guard !decision.cancelled, let updatedText = decision.payload["text"] as? String,
                              !updatedText.isEmpty || media != nil else { subscriber.putNext(nil); subscriber.putCompletion(); return }
                        // Text-entity offsets no longer refer to the edited text.
                        let updatedAttributes = updatedText == text ? attributes : attributes.filter { !($0 is TextEntitiesMessageAttribute) }
                        let updated = EnqueueMessage.message(text: updatedText, attributes: updatedAttributes, inlineStickers: inlineStickers,
                            mediaReference: media, threadId: threadId, replyToMessageId: reply, replyToStoryId: story,
                            localGroupingKey: grouping, correlationId: correlation, bubbleUpEmojiOrStickersets: bubbleUp)
                        subscriber.putNext(current + [updated]); subscriber.putCompletion()
                    }
                    return ActionDisposable { token.dispose() }
                }
            }
        }
        return signal
    }
}
