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
                     id: WhitegramLocalNotificationId, preview: WhitegramNotificationPreview, playSound: Bool) -> UNMutableNotificationContent? {
        guard let first = messages.first else { return nil }
        let data = context.sharedContext.currentPresentationData.with { $0 }
        let content = UNMutableNotificationContent()
        content.title = "Whitegram"
        content.body = data.strings.PUSH_LOCKED_MESSAGE("").string
        if preview != .hidden {
            content.title = self.title(message: first, threadData: threadData, data: data)
        }
        if preview == .full {
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
                if isText, let entities = first.textEntitiesAttribute?.entities {
                    let text = NSMutableString(string: content.body)
                    for entity in entities.sorted(by: { $0.range.lowerBound > $1.range.lowerBound }) {
                        if case .Spoiler = entity.type {
                            let range = NSRange(location: entity.range.lowerBound, length: entity.range.count)
                            if range.location >= 0, NSMaxRange(range) <= text.length {
                                text.replaceCharacters(in: range, with: "•••")
                            }
                        }
                    }
                    content.body = text as String
                }
            }
        }
        guard !content.title.isEmpty || !content.body.isEmpty else { return nil }
        content.categoryIdentifier = "c"
        content.sound = playSound ? .default : nil
        let threadId = threadData == nil ? nil : first.threadId
        content.userInfo = id.userInfo(threadId: threadId)
        content.threadIdentifier = id.threadIdentifier(threadId: threadId)
        return content
    }

    private static func title(message: Message, threadData: MessageHistoryThreadData?, data: PresentationData) -> String {
        let peerTitle = messageMainPeer(EngineMessage(message))?.displayTitle(strings: data.strings, displayOrder: data.nameDisplayOrder) ?? "Whitegram"
        guard let author = message.author, author.id != message.id.peerId else { return peerTitle }
        let name = EnginePeer(author).displayTitle(strings: data.strings, displayOrder: data.nameDisplayOrder)
        if let threadData { return "\(name) → \(threadData.info.title)" }
        return name + "@" + peerTitle
    }
}
