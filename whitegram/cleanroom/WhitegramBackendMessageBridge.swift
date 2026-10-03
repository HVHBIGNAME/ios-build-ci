import Foundation
import Postbox
import SwiftSignalKit

enum WhitegramBackendMessageBridge {
    static func record(postbox: Postbox, accountId: PeerId, messageId: MessageId, direction: WhitegramBackendMessageEvent.Direction) {
        guard WhitegramPreferences.bool("whitegramStreakEnabled"),
              accountId.namespace == Namespaces.Peer.CloudUser,
              messageId.namespace == Namespaces.Message.Cloud,
              messageId.peerId.namespace == Namespaces.Peer.CloudUser,
              messageId.peerId != accountId else { return }

        // A separate transaction observes the confirmed message after the caller commits.
        let _ = (postbox.transaction { transaction -> WhitegramBackendMessageEvent? in
            guard WhitegramPreferences.bool("whitegramStreakEnabled"),
                  let message = transaction.getMessage(messageId),
                  let peer = transaction.getPeer(messageId.peerId) as? TelegramUser, peer.botInfo == nil,
                  !message.flags.contains(.Failed), !message.flags.contains(.Unsent),
                  !message.containsSecretMedia,
                  message.flags.contains(.Incoming) == (direction == .received) else { return nil }
            return WhitegramBackendMessageEvent(accountId: accountId.id._internalGetInt64Value(),
                peerId: messageId.peerId.id._internalGetInt64Value(), messageId: messageId.id,
                timestamp: message.timestamp, direction: direction)
        }).start(next: { event in
            guard let event else { return }
            DispatchQueue.main.async {
                guard WhitegramPreferences.bool("whitegramStreakEnabled") else { return }
                NotificationCenter.default.post(name: WhitegramBackendMessageEvent.notification, object: event)
            }
        })
    }
}
