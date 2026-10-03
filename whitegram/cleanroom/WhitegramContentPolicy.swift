import Foundation
import Postbox

public enum WhitegramContentPolicy {
    /// This is a local copy/export decision. Message.isCopyProtected() and server-side
    /// forwarding/editing eligibility retain the original protection flags.
    public static func isLocalCopyProtected(_ message: Message, peerIsCopyProtected: Bool = false) -> Bool {
        return !WhitegramContentSettings.saveProtectedContent && (message.isCopyProtected() || peerIsCopyProtected)
    }

    public static func hasMediaSpoiler(_ message: Message?) -> Bool {
        guard !WhitegramContentSettings.removeSpoilers, let message else { return false }
        return message.attributes.contains(where: { $0 is MediaSpoilerMessageAttribute })
    }

    public static func recordAsViewOnce(requested: Bool, eligible: Bool) -> Bool {
        return eligible && (requested || WhitegramContentSettings.bool("ghostModeRecordOnce"))
    }

    static func preservingForbiddenChannelMetadata(previous: TelegramChannel, updated: TelegramChannel) -> TelegramChannel {
        guard WhitegramContentSettings.keepBannedChats, previous.id == updated.id,
            updated.participationStatus == .kicked, updated.creationDate == 0 else { return updated }
        return TelegramChannel(
            id: updated.id, accessHash: updated.accessHash, title: previous.title,
            username: previous.username, photo: previous.photo, creationDate: previous.creationDate,
            version: updated.version, participationStatus: updated.participationStatus,
            info: updated.info, flags: updated.flags, restrictionInfo: updated.restrictionInfo,
            adminRights: updated.adminRights, bannedRights: updated.bannedRights,
            defaultBannedRights: updated.defaultBannedRights, usernames: previous.usernames,
            storiesHidden: previous.storiesHidden, nameColor: previous.nameColor,
            backgroundEmojiId: previous.backgroundEmojiId, profileColor: previous.profileColor,
            profileBackgroundEmojiId: previous.profileBackgroundEmojiId, emojiStatus: previous.emojiStatus,
            approximateBoostLevel: updated.approximateBoostLevel, subscriptionUntilDate: updated.subscriptionUntilDate,
            verificationIconFileId: updated.verificationIconFileId, sendPaidMessageStars: updated.sendPaidMessageStars,
            linkedMonoforumId: updated.linkedMonoforumId, linkedCommunityId: updated.linkedCommunityId
        )
    }
}
