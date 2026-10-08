import Foundation
import Intents
import LocalizedPeerData
import Postbox
import TelegramCore
import TelegramPresentationData
import UIKit
import UserNotifications

struct WhitegramPreparedNotification {
    let content: UNNotificationContent
    let temporaryFiles: [TempBoxFile]

    func releaseTemporaryFiles() {
        for file in self.temporaryFiles { TempBox.shared.dispose(file) }
    }
}

enum WhitegramNotificationEnrichment {
    static func prepare(content: UNMutableNotificationContent, context: AccountContextImpl, message: Message,
                        threadData: MessageHistoryThreadData?, id: WhitegramLocalNotificationId,
                        preview: WhitegramNotificationPreview) -> WhitegramPreparedNotification {
        guard preview == .full, message.id.peerId.namespace != Namespaces.Peer.SecretChat,
              !message.containsSecretMedia else {
            return WhitegramPreparedNotification(content: content, temporaryFiles: [])
        }
        let mediaBox = context.account.postbox.mediaBox
        let sender = message.author ?? message.peers[message.id.peerId]
        var temporaryFiles: [TempBoxFile] = []
        if !message.attributes.contains(where: { $0 is MediaSpoilerMessageAttribute }),
           let data = self.mediaPreview(message: message, mediaBox: mediaBox),
           let (attachment, file) = self.attachment(data: data, identifier: id.rawValue + "_media") {
            content.attachments = [attachment]
            temporaryFiles.append(file)
        }
        if #available(iOS 15.0, *), let sender,
           let updated = self.communicationContent(content: content, context: context, message: message,
                                                    sender: sender, threadData: threadData) {
            return WhitegramPreparedNotification(content: updated, temporaryFiles: temporaryFiles)
        }
        if content.attachments.isEmpty, let data = self.avatar(peer: sender, mediaBox: mediaBox),
           let (attachment, file) = self.attachment(data: data, identifier: id.rawValue) {
            content.attachments = [attachment]
            temporaryFiles.append(file)
        }
        return WhitegramPreparedNotification(content: content, temporaryFiles: temporaryFiles)
    }

    private static func jpeg(resource: MediaResource, mediaBox: MediaBox) -> Data? {
        guard let path = mediaBox.completedResourcePath(resource),
              let image = UIImage(contentsOfFile: path) else { return nil }
        return image.jpegData(compressionQuality: 0.8)
    }

    private static func avatar(peer: Peer?, mediaBox: MediaBox) -> Data? {
        guard let image = peer?.smallProfileImage else { return nil }
        return self.jpeg(resource: image.resource, mediaBox: mediaBox)
    }

    private static func mediaPreview(message: Message, mediaBox: MediaBox) -> Data? {
        var representations: [TelegramMediaImageRepresentation] = []
        for media in message.media {
            if let image = media as? TelegramMediaImage { representations += image.representations }
            if let file = media as? TelegramMediaFile { representations += file.previewRepresentations }
        }
        representations.sort {
            Int64($0.dimensions.width) * Int64($0.dimensions.height) > Int64($1.dimensions.width) * Int64($1.dimensions.height)
        }
        for representation in representations {
            if let data = self.jpeg(resource: representation.resource, mediaBox: mediaBox) { return data }
        }
        return nil
    }

    private static func attachment(data: Data, identifier: String) -> (UNNotificationAttachment, TempBoxFile)? {
        let file = TempBox.shared.tempFile(fileName: identifier + ".jpg")
        do {
            let url = URL(fileURLWithPath: file.path)
            try data.write(to: url, options: .atomic)
            let attachment = try UNNotificationAttachment(identifier: identifier, url: url,
                options: [UNNotificationAttachmentOptionsTypeHintKey: "public.jpeg"])
            return (attachment, file)
        } catch {
            TempBox.shared.dispose(file)
            NSLog("Whitegram: notification attachment failed (%ld)", (error as NSError).code)
            return nil
        }
    }

    @available(iOS 15.0, *)
    private static func communicationContent(content: UNMutableNotificationContent, context: AccountContextImpl,
                                             message: Message, sender: Peer, threadData: MessageHistoryThreadData?) -> UNNotificationContent? {
        let data = context.sharedContext.currentPresentationData.with { $0 }
        let mediaBox = context.account.postbox.mediaBox
        let senderName = EnginePeer(sender).displayTitle(strings: data.strings, displayOrder: data.nameDisplayOrder)
        let senderImage = self.avatar(peer: sender, mediaBox: mediaBox).map { INImage(imageData: $0) }
        let senderPerson = self.person(identifier: String(sender.id.toInt64()), name: senderName, image: senderImage)
        let me = INPerson(personHandle: INPersonHandle(value: "0", type: .unknown), nameComponents: nil,
            displayName: nil, image: nil, contactIdentifier: nil, customIdentifier: nil, isMe: true, suggestionType: .none)
        var recipients = [me]
        var groupName: INSpeakableString?
        var groupImage: INImage?
        var conversationId = String(message.id.peerId.toInt64())
        if let peer = message.peers[message.id.peerId], sender.id != peer.id, self.isGroup(peer) {
            var title = EnginePeer(peer).displayTitle(strings: data.strings, displayOrder: data.nameDisplayOrder)
            if let threadData { title += " → " + threadData.info.title }
            recipients.append(self.person(identifier: "chat_\(peer.id.toInt64())", name: title, image: nil))
            groupName = INSpeakableString(spokenPhrase: title)
            groupImage = self.avatar(peer: peer, mediaBox: mediaBox).map { INImage(imageData: $0) }
            if let threadId = message.threadId { conversationId += "_\(threadId)" }
        } else if content.title != senderName {
            groupName = INSpeakableString(spokenPhrase: content.title)
        }
        let intent = INSendMessageIntent(recipients: recipients, outgoingMessageType: .outgoingMessageText,
            content: content.body, speakableGroupName: groupName, conversationIdentifier: conversationId,
            serviceName: nil, sender: senderPerson, attachments: nil)
        if let senderImage { intent.setImage(senderImage, forParameterNamed: \.sender) }
        if let groupImage { intent.setImage(groupImage, forParameterNamed: \.speakableGroupName) }
        let interaction = INInteraction(intent: intent, response: nil)
        interaction.direction = .incoming
        interaction.donate(completion: nil)
        do {
            return try content.updating(from: intent)
        } catch {
            NSLog("Whitegram: notification communication style failed (%ld)", (error as NSError).code)
            return nil
        }
    }

    private static func isGroup(_ peer: Peer) -> Bool {
        if peer is TelegramGroup { return true }
        if let channel = peer as? TelegramChannel, case .group = channel.info { return true }
        return false
    }

    @available(iOS 15.0, *)
    private static func person(identifier: String, name: String, image: INImage?) -> INPerson {
        return INPerson(personHandle: INPersonHandle(value: identifier, type: .unknown), nameComponents: nil,
            displayName: name, image: image, contactIdentifier: nil, customIdentifier: identifier, isMe: false, suggestionType: .none)
    }
}
