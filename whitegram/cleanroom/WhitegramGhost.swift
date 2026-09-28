import Foundation

import Postbox
import SwiftSignalKit
import TelegramApi
import MtProtoKit

public enum WhitegramGhost {
    private static func enabled(_ key: String) -> Bool {
        let flags = WhitegramPreferences.values()
        return ((flags["ghostModeEnabled"] as? Bool) ?? false) || ((flags[key] as? Bool) ?? false)
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

    public static func effectiveOnlineStatus(requested: Bool) -> Bool {
        return !suppressOnlineStatus && (requested || WhitegramPreferences.bool("alwaysOnline"))
    }

    static func suppressActivity(_ activity: PeerInputActivity?) -> Bool {
        guard let activity else { return false }
        switch activity {
        case .speakingInGroupCall:
            return false
        case .recordingVoice, .recordingInstantVideo:
            return enabled("disableRecordingStatus")
        case .uploadingFile, .uploadingPhoto, .uploadingVideo, .uploadingInstantVideo:
            return enabled("disableUploadingStatus")
        case .typingText, .choosingSticker, .playingGame, .interactingWithEmoji, .seeingEmojiInteraction:
            return enabled("disableTypingStatus")
        }
    }

    static func messageContentsRequest(network: Network, ids: [Int32]) -> Signal<Api.messages.AffectedMessages?, MTRpcError> {
        return deferred {
            if suppressReadReceipts { return .single(nil) }
            return network.request(Api.functions.messages.readMessageContents(id: ids)) |> map(Optional.init)
        }
    }

    static func channelContentsRequest(network: Network, channel: Api.InputChannel, ids: [Int32]) -> Signal<Api.Bool, MTRpcError> {
        return deferred {
            if suppressReadReceipts { return .single(.boolFalse) }
            return network.request(Api.functions.channels.readMessageContents(channel: channel, id: ids))
        }
    }
}
