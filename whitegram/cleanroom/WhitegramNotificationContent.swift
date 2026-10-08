import Foundation
import LocalizedPeerData
import Postbox
import TelegramCore
import TelegramPresentationData
import TelegramStringFormatting
import TelegramUIPreferences
import UserNotifications

enum WhitegramNotificationContent {
    static func make(context: AccountContextImpl, messages: [Message], threadData: MessageHistoryThreadData?,
                     id: WhitegramLocalNotificationId, preview: WhitegramNotificationPreview, playSound: Bool) -> WhitegramPreparedNotification? {
        guard let first = messages.first else { return nil }
        let data = context.sharedContext.currentPresentationData.with { $0 }
        let content = UNMutableNotificationContent()
        content.title = "Whitegram"
        content.body = data.strings.PUSH_LOCKED_MESSAGE("").string
        if preview != .hidden {
            content.title = self.title(message: first, threadData: threadData, data: data)
        }
        if preview == .full {
            content.subtitle = self.subtitle(context: context, message: first, baseLanguage: data.strings.baseLanguageCode) ?? ""
            if first.id.peerId.namespace == Namespaces.Peer.SecretChat {
                content.body = data.strings.PUSH_ENCRYPTED_MESSAGE("").string
            } else if messages.count > 1 {
                content.body = data.strings.PUSH_MESSAGES_TEXT(Int32(clamping: messages.count))
            } else {
                let (description, _, isText) = descriptionStringForMessage(
                    contentSettings: context.currentContentSettings.with { $0 }, message: EngineMessage(first),
                    strings: data.strings, nameDisplayOrder: data.nameDisplayOrder,
                    dateTimeFormat: data.dateTimeFormat, accountPeerId: context.account.peerId)
                content.body = isText && !first.text.isEmpty ? first.text : description.string
                if let entities = first.textEntitiesAttribute?.entities {
                    if isText {
                        let ranges = entities.compactMap { entity -> Range<Int>? in
                            if case .Spoiler = entity.type { return entity.range }
                            return nil
                        }
                        content.body = WhitegramNotificationText.redactingSpoilers(content.body, ranges: ranges)
                    }
                    let hasCustomEmoji = entities.contains { if case .CustomEmoji = $0.type { return true }; return false }
                    content.body = WhitegramNotificationText.emojiPresentation(content.body, hasCustomEmoji: hasCustomEmoji)
                }
            }
        }
        guard !content.title.isEmpty || !content.body.isEmpty else { return nil }
        content.categoryIdentifier = "c"
        content.sound = playSound ? .default : nil
        let threadId = threadData == nil ? nil : first.threadId
        content.userInfo = id.userInfo(threadId: threadId)
        content.threadIdentifier = id.threadIdentifier(threadId: threadId)
        return WhitegramNotificationEnrichment.prepare(content: content, context: context, message: first,
            threadData: threadData, id: id, preview: preview)
    }

    private static func title(message: Message, threadData: MessageHistoryThreadData?, data: PresentationData) -> String {
        let peerTitle = messageMainPeer(EngineMessage(message))?.displayTitle(strings: data.strings, displayOrder: data.nameDisplayOrder) ?? "Whitegram"
        guard let author = message.author, author.id != message.id.peerId else { return peerTitle }
        let name = EnginePeer(author).displayTitle(strings: data.strings, displayOrder: data.nameDisplayOrder)
        if let threadData { return "\(name) → \(threadData.info.title)" }
        return name + "@" + peerTitle
    }

    private static func subtitle(context: AccountContextImpl, message: Message, baseLanguage: String) -> String? {
        guard let peer = message.peers[message.id.peerId], peer is TelegramGroup || peer is TelegramChannel else { return nil }
        let replyToMe = message.attributes.contains { attribute in
            guard let reply = attribute as? ReplyMessageAttribute,
                  let replied = message.associatedMessages[reply.messageId] else { return false }
            if let author = replied.author { return author.id == context.account.peerId }
            return !replied.flags.contains(.Incoming)
        }
        return WhitegramNotificationText.subtitle(baseLanguage: baseLanguage, replyToMe: replyToMe,
            mentioned: message.flags.contains(.Incoming) && message.tags.contains(.unseenPersonalMessage))
    }
}
