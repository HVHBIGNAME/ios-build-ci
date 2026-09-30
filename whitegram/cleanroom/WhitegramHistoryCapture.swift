import Foundation
import Postbox

public extension WhitegramHistoryStore {
    static func forAccount(mediaBoxPath: String, accountPeerId: PeerId) -> WhitegramHistoryStore {
        return self.accountStore(
            directory: URL(fileURLWithPath: mediaBoxPath).deletingLastPathComponent(),
            accountId: accountPeerId.toInt64(),
            cloudNamespace: Namespaces.Message.Cloud
        )
    }

    static func capture(_ message: EngineRawMessage, event: WhitegramHistoryEvent, accountPeerId: PeerId, mediaBoxPath: String) {
        guard message.id.namespace == Namespaces.Message.Cloud, message.id.peerId.namespace != Namespaces.Peer.SecretChat else { return }
        let flags = WhitegramPreferences.values()
        let enabled: Bool
        switch event {
        case .received: enabled = flags["saveChatHistory"] as? Bool == true
        case .deleted: enabled = flags["showDeletedMessages"] as? Bool == true || flags["saveDeletedMessagesToBackup"] as? Bool == true || flags["saveChatHistory"] as? Bool == true
        case .edited: enabled = flags["showEditedOriginalText"] as? Bool == true || flags["saveChatHistory"] as? Bool == true
        }
        guard enabled else { return }
        let outgoing = !message.flags.contains(.Incoming)
        let bot = (message.author as? TelegramUser)?.botInfo != nil
        if event == .deleted && ((outgoing && flags["hideMyDeletedMessages"] as? Bool == true) || (bot && flags["hideBotDeletedMessages"] as? Bool == true)) { return }
        if event == .edited && ((outgoing && flags["hideMyEditedMessages"] as? Bool == true) || (bot && flags["hideBotEditedMessages"] as? Bool == true)) { return }
        let entry = WhitegramHistoryEntry(
            accountId: String(accountPeerId.toInt64()), peerId: String(message.id.peerId.toInt64()), namespace: message.id.namespace,
            messageId: message.id.id, revision: message.stableVersion, messageDate: message.timestamp,
            capturedAt: Date().timeIntervalSince1970, event: event,
            text: whitegramHistoryBoundedString(message.text, maximumBytes: self.maximumTextBytes),
            authorId: message.author.map { String($0.id.toInt64()) }, outgoing: outgoing, mediaCount: message.media.count,
            peerTitle: message.peers[message.id.peerId].map { whitegramHistoryBoundedString(EnginePeer($0).debugDisplayTitle, maximumBytes: self.maximumNameBytes) },
            authorName: message.author.map { whitegramHistoryBoundedString(EnginePeer($0).debugDisplayTitle, maximumBytes: self.maximumNameBytes) },
            editedAt: message.editedTime, textTruncated: message.text.utf8.count > self.maximumTextBytes,
            media: message.media.prefix(self.maximumMediaItems).map(whitegramHistoryMedia)
        )
        self.forAccount(mediaBoxPath: mediaBoxPath, accountPeerId: accountPeerId).append(entry)
    }

    static func hasMediaChanges(_ previous: [EngineRawMedia], _ updated: [EngineRawMedia]) -> Bool {
        guard previous.count == updated.count else { return true }
        // Compare attachment content, not expiring resource references, poll votes or cached previews.
        return zip(previous, updated).contains { whitegramHistoryMedia($0.0) != whitegramHistoryMedia($0.1) }
    }
}

private func whitegramHistoryMedia(_ media: EngineRawMedia) -> WhitegramHistoryMedia {
    let id = media.id.map { "\($0.namespace):\($0.id)" }
    if let file = media as? TelegramMediaFile {
        var width: Int32?
        var height: Int32?
        var duration: Double?
        for attribute in file.attributes {
            switch attribute {
            case let .ImageSize(size):
                width = size.width > 0 ? size.width : nil
                height = size.height > 0 ? size.height : nil
            case let .Video(seconds, size, _, _, _, _):
                width = size.width > 0 ? size.width : nil
                height = size.height > 0 ? size.height : nil
                duration = seconds.isFinite && seconds >= 0 ? seconds : nil
            case let .Audio(_, seconds, _, _, _):
                duration = seconds >= 0 ? Double(seconds) : nil
            default: break
            }
        }
        let kind: WhitegramHistoryMedia.Kind
        if file.isSticker || file.isAnimatedSticker || file.isVideoSticker { kind = .sticker }
        else if file.isInstantVideo { kind = .videoMessage }
        else if file.isVoice { kind = .voice }
        else if file.isMusic { kind = .audio }
        else if file.isVideo { kind = .video }
        else { kind = .file }
        return WhitegramHistoryMedia(
            kind: kind, mediaId: id,
            fileName: file.fileName.map { whitegramHistoryBoundedString($0, maximumBytes: WhitegramHistoryStore.maximumNameBytes) },
            mimeType: whitegramHistoryBoundedString(file.mimeType, maximumBytes: 256),
            size: file.size.flatMap { $0 >= 0 ? $0 : nil }, width: width, height: height, duration: duration
        )
    } else if let image = media as? TelegramMediaImage {
        let dimensions = image.representations.max {
            Int64($0.dimensions.width) * Int64($0.dimensions.height) < Int64($1.dimensions.width) * Int64($1.dimensions.height)
        }?.dimensions
        return WhitegramHistoryMedia(kind: .photo, mediaId: id, width: dimensions.flatMap { $0.width > 0 ? $0.width : nil }, height: dimensions.flatMap { $0.height > 0 ? $0.height : nil })
    } else if media is TelegramMediaWebpage {
        return WhitegramHistoryMedia(kind: .webpage, mediaId: id)
    } else if media is TelegramMediaPoll {
        return WhitegramHistoryMedia(kind: .poll, mediaId: id)
    } else {
        return WhitegramHistoryMedia(kind: .other, mediaId: id)
    }
}
