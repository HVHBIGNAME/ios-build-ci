"""Reviewed public-fork merge conflicts against Telegram f1dd7a2 (13.0)."""

import re
from pathlib import PurePosixPath
from public_resolutions import replace_once, resolve

REVISION = "f1dd7a2dbd02cbbf513e75d5695d8d36d1cf5838"
COUNTS = {
    "NotificationService.swift": 1, "ChatContextMenus.swift": 5,
    "ChatListControllerNode.swift": 2, "NativeWindowHostView.swift": 1,
    "ProxyListSettingsController.swift": 3, "PresentationCallManager.swift": 3,
    "Account.swift": 1, "ChatInputMessageAccessoryPanel.swift": 2,
    "ChatMessageBubbleItemNode.swift": 2, "ContextControllerActionsStackNode.swift": 1,
    "ContextControllerExtractedPresentationNode.swift": 1, "PeerInfoScreen.swift": 1,
    "PeerInfoSettingsItems.swift": 3, "VideoMessageCameraScreen.swift": 1,
    "AppDelegate.swift": 1, "ChatController.swift": 1, "ChatHistoryListNode.swift": 1,
    "ChatInterfaceStateContextMenus.swift": 6, "OngoingCallContext.swift": 3,
}


def block(name, index, ours, base, theirs):
    if name in ("NotificationService.swift", "ChatInputMessageAccessoryPanel.swift",
                "ChatMessageBubbleItemNode.swift", "ContextControllerExtractedPresentationNode.swift"):
        # Fork-only whitespace/trailing-comma changes carry no runtime behavior.
        if re.sub(r"[\s,]", "", base) != re.sub(r"[\s,]", "", theirs):
            raise ValueError(f"Unexpected non-formatting fork delta: {name}")
        return ours
    if name in ("NativeWindowHostView.swift", "ContextControllerActionsStackNode.swift", "AppDelegate.swift"):
        # Keep the current scene lifecycle and removal of the superseded lens implementation.
        return ours
    if name in ("Account.swift", "PeerInfoScreen.swift"):
        return theirs if name == "Account.swift" else ours + theirs
    if name == "PresentationCallManager.swift":
        return replace_once(ours, "preferredVideoCodec: nil", "forceTcpCalls: experimentalSettings.enableVoipTcp,\n                        preferredVideoCodec: nil")
    if name == "ChatContextMenus.swift":
        if index == 1:
            return replace_once(ours, "if canEditFolderMembership && !hasRemoveFromFolder && peerGroup != nil {", "if canEditFolderMembership && !hasRemoveFromFolder && peerGroup != nil && whiteGramContextMenuSettings.isEnabled(.chatListFolder) {")
        if index == 2:
            return replace_once(ours, "if !isCommunity {", "if !isCommunity && whiteGramContextMenuSettings.isEnabled(.chatListMark) {")
        if index == 3:
            return ours  # The whole pin action is gated below, outside this partial merge hunk.
        if index == 4:
            return replace_once(ours, "if !isSavedMessages {", "if !isSavedMessages && whiteGramContextMenuSettings.isEnabled(.chatListMute) {")
        return replace_once(ours, "if case .chatList = source, peerGroup != nil {", "if case .chatList = source, peerGroup != nil, whiteGramContextMenuSettings.isEnabled(.chatListDelete) {")
    if name == "ChatListControllerNode.swift":
        if index == 1:
            suffix = theirs.split("if case .compact = layout.metrics.widthClass,", 1)[1].split("{\n", 1)[1]
            return ours + suffix
        return replace_once(ours, "if let tabContainerData", "if !shouldHideTopFolderTabs, let tabContainerData")
    if name == "ProxyListSettingsController.swift":
        if index == 1:
            return replace_once(ours, "        let status: ProxyServerStatus = statuses[server] ?? .checking\n", theirs)
        if index == 2:
            return theirs
        return theirs + "        var presentationData = presentationData\n        let updatedTheme = presentationData.theme.withModalBlocksBackground()\n        presentationData = presentationData.withUpdated(theme: updatedTheme)\n"
    if name == "PeerInfoSettingsItems.swift":
        if index == 1:
            return ours + theirs
        if index == 2:
            return replace_once(ours, "        if !settings.proxySettings.servers.isEmpty {\n", "")
        return replace_once(ours, "if !isPremiumDisabled || context.isPremium {", "if whiteGramContextMenuSettings.isEnabled(.settingsBusiness) && (!isPremiumDisabled || context.isPremium) {")
    if name == "VideoMessageCameraScreen.swift":
        return replace_once(ours, 'let isFrontPosition = "".isEmpty', 'let isFrontPosition = controller.initialFrontCamera')
    if name == "ChatController.swift":
        return ours  # Register the fork observer at the relocated initializer tail below.
    if name == "ChatHistoryListNode.swift":
        return replace_once(ours, "if strongSelf.offerNextChannelToRead,", "if WhiteGramChatSettings.current.channelSwipeToNext && strongSelf.offerNextChannelToRead,")
    if name == "ChatInterfaceStateContextMenus.swift":
        if index == 1:
            return theirs + ours
        if index == 2:
            return ours  # The reply action moved; its current guard is patched below.
        if index == 3:
            return replace_once(ours, "showTranslate: translationSettings.showTranslate,", "showTranslate: translationSettings.showTranslate && whiteGramOtherSettings.translationButton,")
        if index == 4:
            return replace_once(ours, "if canPin {", "if canPin, isWhiteGramMessageContextOptionEnabled(fromPrivate: .privatePin, channel: .channelPin) {")
        if index == 5:
            return replace_once(ours, "if !isPinnedMessages, !isReplyThreadHead, data.canSelect {", "if !isPinnedMessages, !isReplyThreadHead, data.canSelect, isWhiteGramMessageContextOptionEnabled(fromPrivate: .privateSelect, channel: .channelSelect) {")
        return replace_once(ours, "if data.canEdit {", "if data.canEdit && isWhiteGramMessageContextOptionEnabled(fromPrivate: .privateEdit, channel: .channelEdit) {")
    if name == "OngoingCallContext.swift":
        return ours
    raise ValueError(f"Unreviewed 13.0 block: {name} #{index}")


def resolve_13(relative, merged):
    name = PurePosixPath(relative).name
    if relative == "Telegram/BUILD":
        pattern = r'^<<<<<<< upstream\n(load\("@rules_cc//cc:objc_library.bzl", "objc_library"\)\n\n)\|\|\|\|\|\|\| base\n=======\nload\("@rules_cc//cc:objc_library.bzl", "objc_library"\)\n>>>>>>> whitegram\n'
        result, count = re.subn(pattern, lambda match: match[1], merged, flags=re.MULTILINE)
        if count != 1:
            raise ValueError("Unexpected Telegram/BUILD 13.0 conflict")
        return result
    if name not in COUNTS:
        return resolve(relative, merged)
    pattern = re.compile(r"^<<<<<<< upstream\n(.*?)^\|\|\|\|\|\|\| base\n(.*?)^=======\n(.*?)^>>>>>>> whitegram\n", re.MULTILINE | re.DOTALL)
    blocks = list(pattern.finditer(merged))
    if len(blocks) != COUNTS[name]:
        raise ValueError(f"13.0 conflict layout changed: {relative}")
    result = merged
    for index, match in reversed(list(enumerate(blocks, 1))):
        result = result[:match.start()] + block(name, index, *match.groups()) + result[match.end():]
    if name == "Account.swift":
        # Telegram 13 owns proxy updates (including WEB and network-engine changes).
        # Keep that observer, not the older fork's MTContext-only subscription.
        start = result.index("        self.proxySettingsDisposable.set((accountManager.sharedData(keys: [SharedDataKeys.proxySettings])")
        end = result.index("        network.context.performBatchUpdates({", start)
        legacy = result[start:end]
        if "network.context.updateApiEnvironment" not in legacy or legacy.count("managedAutomaticProxyBootstrap(") != 1:
            raise ValueError("Unexpected legacy unauthorized proxy observer")
        result = replace_once(result, legacy, "")
        anchor = "            network?.updateProxySettings(activeServer)\n        }))\n"
        result = replace_once(result, anchor, anchor + "        self.automaticProxyBootstrapDisposable.set(managedAutomaticProxyBootstrap(accountManager: accountManager, network: network))\n")
        result = replace_once(result, "    deinit {\n        self.proxySettingsDisposable.dispose()\n    }\n\n", "")
    if name == "ChatController.swift":
        theirs = blocks[0][3]
        observer = theirs[theirs.index("        self.whiteGramChatSettingsObserver ="):theirs.index("        if case let .messageOptions")]
        anchor = "        if case let .messageOptions(_, messageIds, _) = self.subject, messageIds.count > 1 {\n"
        result = replace_once(result, anchor, observer + anchor)
    if name == "ChatInterfaceStateContextMenus.swift":
        result = replace_once(result, "if !isPinnedMessages, !isReplyThreadHead, data.canReply {", "if !isPinnedMessages, !isReplyThreadHead, data.canReply, isWhiteGramMessageContextOptionEnabled(fromPrivate: .privateReply, channel: .channelReply) {")
    if name == "ChatContextMenus.swift":
        anchor = "                            items.append(.action(ContextMenuActionItem(text: isPinned ? strings.ChatList_Context_Unpin : strings.ChatList_Context_Pin,"
        if result.count(anchor) != 1:
            raise ValueError("13.0 pin action moved")
        start = result.index(anchor)
        end = result.index("                            })))\n", start) + len("                            })))\n")
        result = result[:start] + "                            if whiteGramContextMenuSettings.isEnabled(.chatListPin) {\n" + result[start:end] + "                            }\n" + result[end:]
    if name == "OngoingCallContext.swift":
        before = "                            continue connectionsLoop\n                        }\n                    case .webRtcReflector:"
        after = "                            if !forceTcpCalls { continue connectionsLoop }\n                        }\n                    case .webRtcReflector:"
        result = replace_once(result, before, after)
    return result
