import Foundation

import Postbox
import SwiftSignalKit
import TelegramApi
import MtProtoKit

public enum WhitegramGhost {
    private static func enabled(_ key: String) -> Bool {
        return WhitegramContentSettings.bool("ghostModeEnabled") || WhitegramContentSettings.bool(key)
    }

    public static func isEnabled(for peerId: PeerId) -> Bool {
        return WhitegramContentSettings.perChatGhostIds.contains(peerId.toInt64())
    }

    @discardableResult
    public static func toggle(for peerId: PeerId) -> Bool {
        return WhitegramContentSettings.togglePerChatGhost(id: peerId.toInt64())
    }

    public static var suppressOnlineStatus: Bool {
        return enabled("disableOnlineStatus")
    }

    public static var suppressTypingStatus: Bool {
        return enabled("disableTypingStatus")
    }

    public static var suppressReadReceipts: Bool {
        return enabled("disableReadReceipts")
    }

    public static var suppressStoryReadReceipts: Bool {
        return enabled("disableStoryReadReceipts")
    }

    public static func suppressReadReceipts(for peerId: PeerId) -> Bool {
        return suppressReadReceipts || isEnabled(for: peerId)
    }

    public static func suppressAutomaticHistoryReads(for peerId: PeerId) -> Bool {
        return WhitegramContentSettings.readPolicy(peerId: peerId.toInt64()).suppressAutomaticReceipts
    }

    public static func suppressLocalHistoryRead(for peerId: PeerId) -> Bool {
        return WhitegramContentSettings.readPolicy(peerId: peerId.toInt64()).suppressLocalHistoryRead
    }

    public static func canReadOnAction(for peerId: PeerId) -> Bool {
        // Original SynchronizePeerReadState: explicit/global/per-chat ghost gates precede
        // the read-on-action exception (image 46, 0x4f5c98..0x4f5fac).
        return !WhitegramContentSettings.readPolicy(peerId: peerId.toInt64()).suppressActionReceipts
    }

    public static func effectiveOnlineStatus(requested: Bool) -> Bool {
        return !suppressOnlineStatus && (requested || WhitegramContentSettings.bool("alwaysOnline"))
    }

    static func suppressActivity(_ activity: PeerInputActivity?, peerId: PeerId? = nil) -> Bool {
        guard let activity else { return false }
        let perChat = peerId.map { isEnabled(for: $0) } ?? false
        switch activity {
        case .speakingInGroupCall:
            return false
        case .recordingVoice, .recordingInstantVideo:
            return perChat || enabled("disableRecordingStatus")
        case .uploadingFile, .uploadingPhoto, .uploadingVideo, .uploadingInstantVideo:
            return perChat || enabled("disableUploadingStatus")
        case .typingText, .choosingSticker, .playingGame, .interactingWithEmoji, .seeingEmojiInteraction:
            return perChat || enabled("disableTypingStatus")
        }
    }

    static func messageContentsRequest(network: Network, ids: [Int32], peerId: PeerId? = nil) -> Signal<Api.messages.AffectedMessages?, MTRpcError> {
        return deferred {
            if peerId.map({ suppressReadReceipts(for: $0) }) ?? suppressReadReceipts { return .single(nil) }
            return network.request(Api.functions.messages.readMessageContents(id: ids)) |> map(Optional.init)
        }
    }

    static func channelContentsRequest(network: Network, channel: Api.InputChannel, ids: [Int32], peerId: PeerId? = nil) -> Signal<Api.Bool?, MTRpcError> {
        return deferred {
            if peerId.map({ suppressReadReceipts(for: $0) }) ?? suppressReadReceipts { return .single(nil) }
            return network.request(Api.functions.channels.readMessageContents(channel: channel, id: ids)) |> map(Optional.init)
        }
    }
}
