"""Reviewed 12.6.2 -> 12.9.2 API adaptations for the public WhiteGram fork."""

import re
from pathlib import PurePosixPath


def replace_once(value: str, old: str, new: str) -> str:
    if value.count(old) != 1:
        raise ValueError(f"Expected one adaptation anchor: {old!r}")
    return value.replace(old, new, 1)


def resolve_block(name: str, index: int, ours: str, base: str, theirs: str) -> str:
    if name == "AttachmentController.swift":
        return theirs if index == 1 else replace_once(ours, "caption.string", "captionText")
    if name == "BUILD":
        return ours + theirs
    if name == "ChatContextMenus.swift":
        if index == 1:
            return replace_once(ours, "if !isCommunity {", "if !isCommunity && whiteGramContextMenuSettings.isEnabled(.chatListMark) {")
        if index == 2:
            return replace_once(ours, "if !isSavedMessages {", "if !isSavedMessages && whiteGramContextMenuSettings.isEnabled(.chatListMute) {")
        return replace_once(ours, "if case .chatList = source, peerGroup != nil {", "if case .chatList = source, peerGroup != nil, whiteGramContextMenuSettings.isEnabled(.chatListDelete) {")
    if name == "ChatListController.swift":
        return ours + ("                        releasePeerSelection()\n" if index == 1 else theirs)
    if name == "ChatListControllerNode.swift":
        return replace_once(ours, "if let tabContainerData", "if !shouldHideTopFolderTabs, let tabContainerData")
    if name == "ChatListItem.swift":
        return resolve_chat_list_item(index, ours, theirs)
    if name == "MediaPickerScreen.swift":
        return ours + "                }\n"
    if name in ("QrCodeScreen.swift", "ChatInputMessageAccessoryPanel.swift", "ChatScheduleTimeScreen.swift"):
        # WhiteGram only removes a trailing comma here. Keep the newer parameters.
        return ours
    if name == "ProxyListSettingsController.swift":
        if index == 1:
            return replace_once(ours, "        let status: ProxyServerStatus = statuses[server] ?? .checking\n", theirs)
        return theirs + "        var presentationData = presentationData\n        let updatedTheme = presentationData.theme.withModalBlocksBackground()\n        presentationData = presentationData.withUpdated(theme: updatedTheme)\n"
    if name == "WebBrowserItem.swift":
        return replace_once(ours, '?.imageName ?? "BlueIcon"', '?.imageName ?? icons.first(where: { $0.isDefault })?.imageName ?? "BlueIcon"')
    if name in ("ChatMessageAnimatedStickerItemNode.swift", "ChatMessageStickerItemNode.swift"):
        if index == 1:
            return replace_once(ours, "let dateText = ", "let dateText = WhiteGramChatSettings.current.showStickerTime ? ").rstrip() + ' : ""\n'
        return replace_once(theirs, "shouldDisplayInlineDateReactions(message: item.message,", "shouldDisplayInlineDateReactions(message: EngineMessage(item.message),")
    if name == "ChatMessageInstantVideoItemNode.swift":
        return replace_once(theirs, "shouldDisplayInlineDateReactions(message: item.message,", "shouldDisplayInlineDateReactions(message: EngineMessage(item.message),")
    if name == "StringForMessageTimestampStatus.swift":
        result = ours.replace("timestamp: timestamp, dateTimeFormat: dateTimeFormat)", "timestamp: timestamp, dateTimeFormat: dateTimeFormat, withSeconds: whiteGramSettings.showSecondsInMessageTimestamp)")
        return "        if !whiteGramSettings.hideMessageTimestamp {\n" + result + "        }\n"
    if name in ("ChatMessageInteractiveFileNode.swift", "ChatMessageInteractiveInstantVideoNode.swift"):
        return replace_once(ours, "if transcriptionText == nil", "if !whiteGramAppleTranscription && !whiteGramTelegramTranscription && transcriptionText == nil")
    if name == "ChatMessageShareButton.swift":
        return replace_once(ours, "isSummarize: Bool = false)", "isSummarize: Bool = false, isTranslate: Bool = false)")
    if name == "ChatTextInputPanelNode.swift":
        return ours + ("    private var whiteGramChatSettingsObserver: NSObjectProtocol?\n" if index == 1 else theirs)
    if name == "ChatControllerInteraction.swift":
        return ours + theirs.splitlines(keepends=True)[1]
    if name == "StoryContainerScreen.swift":
        return "import TelegramUIPreferences\n"
    if name == "ChatControllerForwardMessages.swift":
        return replace_once(theirs, "func forwardMessages(messageIds: [MessageId]", "func forwardMessages(messageIds: [EngineMessage.Id]")
    if name == "ChatInterfaceStateContextMenus.swift":
        if index == 1:
            return ours + theirs
        if index == 2:
            return replace_once(ours, "showTranslate: translationSettings.showTranslate,", "showTranslate: translationSettings.showTranslate && whiteGramOtherSettings.translationButton,")
        if index == 3:
            return replace_once(ours, "if canPin {", "if canPin, isWhiteGramMessageContextOptionEnabled(fromPrivate: .privatePin, channel: .channelPin) {")
        return replace_once(ours, "if !isPinnedMessages, !isReplyThreadHead, data.canSelect {", "if !isPinnedMessages, !isReplyThreadHead, data.canSelect, isWhiteGramMessageContextOptionEnabled(fromPrivate: .privateSelect, channel: .channelSelect) {")
    if name == "TranslateScreen.swift":
        # Upstream removed its custom sheet; restore WhiteGram's working provider
        # selection and sheet together with TranslateButtonComponent.
        return theirs
    raise ValueError(f"Unreviewed conflict: {name} #{index}")


def resolve_chat_list_item(index: int, ours: str, theirs: str) -> str:
    if index == 1:
        return replace_once(ours, "CGSize(width: 60.0, height: 60.0)", "CGSize(width: avatarDiameter, height: avatarDiameter)")
    if index == 2:
        result = replace_once(theirs, "nextIsPinned in", "nextIsPinned, nextHasActiveRevealControls in")
        return replace_once(result, "let titleFont = Font.medium", "let titleFont = Font.semibold")
    if index in (3, 5, 6):
        return ours + theirs
    if index == 4:
        return replace_once(theirs, "12.0 : 18.0", "12.0 : 24.0")
    if index == 7:
        prefix = "".join(theirs.splitlines(keepends=True)[:3])
        return prefix + replace_once(ours, "maximumNumberOfLines: (authorAttributedString == nil && itemTags.isEmpty && forumThread == nil && topForumTopicItems.isEmpty) ? 2 : 1,", "maximumNumberOfLines: textMaxLines,")
    if index == 8:
        result = replace_once(theirs, "height - (compactBadgeLayout ? 0.0 : 2.0)", "height + (compactBadgeLayout ? 0.0 : rightAccessoryVerticalOffset)")
        return ours + result
    if index in (9, 10, 11):
        return theirs
    if index == 12:
        return replace_once(theirs, "separatorInset =", "leftSeparatorInset =") + "                        rightSeparatorInset = 16.0\n"
    raise ValueError(f"Unreviewed ChatListItem conflict #{index}")


EXPECTED_CONFLICTS = {
    "AttachmentController.swift": 2,
    "BUILD": 1,
    "ChatContextMenus.swift": 3,
    "ChatListController.swift": 3,
    "ChatListControllerNode.swift": 1,
    "ChatListItem.swift": 12,
    "MediaPickerScreen.swift": 1,
    "QrCodeScreen.swift": 1,
    "ProxyListSettingsController.swift": 2,
    "WebBrowserItem.swift": 1,
    "ChatInputMessageAccessoryPanel.swift": 1,
    "ChatMessageAnimatedStickerItemNode.swift": 2,
    "StringForMessageTimestampStatus.swift": 1,
    "ChatMessageInstantVideoItemNode.swift": 1,
    "ChatMessageInteractiveFileNode.swift": 1,
    "ChatMessageInteractiveInstantVideoNode.swift": 1,
    "ChatMessageShareButton.swift": 1,
    "ChatMessageStickerItemNode.swift": 2,
    "ChatTextInputPanelNode.swift": 2,
    "ChatControllerInteraction.swift": 2,
    "ChatScheduleTimeScreen.swift": 1,
    "StoryContainerScreen.swift": 1,
    "ChatControllerForwardMessages.swift": 1,
    "ChatInterfaceStateContextMenus.swift": 4,
    "TranslateScreen.swift": 2,
}


def resolve(relative: str, merged: str) -> str:
    name = PurePosixPath(relative).name
    if name == "BUILD" and relative != "submodules/AuthorizationUI/BUILD":
        raise ValueError(f"Unreviewed BUILD conflict: {relative}")
    pattern = re.compile(r"^<<<<<<< upstream\n(.*?)^\|\|\|\|\|\|\| base\n(.*?)^=======\n(.*?)^>>>>>>> whitegram\n", re.MULTILINE | re.DOTALL)
    blocks = list(pattern.finditer(merged))
    if name not in EXPECTED_CONFLICTS or len(blocks) != EXPECTED_CONFLICTS[name]:
        raise ValueError(f"Conflict layout changed in {relative}: {len(blocks)}")
    result = merged
    for index, block in reversed(list(enumerate(blocks, 1))):
        result = result[:block.start()] + resolve_block(name, index, *block.groups()) + result[block.end():]
    return result
