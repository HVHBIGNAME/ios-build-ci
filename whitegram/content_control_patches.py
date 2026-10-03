"""Privacy parity hooks for the release-12.9.2 assembled source.

Apply after runtime_patches, interface_patches and message_actions_patches. All
edits are staged in one SourcePatches transaction and validated before writing.
The assembled reference must only be used with content_control_patches(patches).
"""

from pathlib import Path

from source_patches import SourcePatches

CORE = "submodules/TelegramCore/Sources/"
UI = "submodules/TelegramUI/Sources/"
COMPONENTS = "submodules/TelegramUI/Components/"
GALLERY = "submodules/GalleryUI/Sources/"

PRIVACY_RUNTIME_FILES = {
    "WhitegramGhost.swift": CORE + "WhitegramGhost.swift",
    "WhitegramContentSettings.swift": CORE + "WhitegramContentSettings.swift",
    "WhitegramContentPolicy.swift": CORE + "WhitegramContentPolicy.swift",
    "WhitegramReadActionState.swift": CORE + "WhitegramReadActionState.swift",
    "WhitegramReadAction.swift": CORE + "WhitegramReadAction.swift",
    "WhitegramContentMediaStore.swift": CORE + "WhitegramContentMediaStore.swift",
    "WhitegramContentMedia.swift": CORE + "WhitegramContentMedia.swift",
    "WhitegramReadActionUI.swift": UI + "WhitegramReadActionUI.swift",
    "WhitegramPrivacySettings.swift": "submodules/TelegramUIPreferences/Sources/WhitegramPrivacySettings.swift",
    "WhitegramPrivacySettingsController.swift": "submodules/SettingsUI/Sources/WhitegramPrivacySettingsController.swift",
    "WhitegramContentMediaController.swift": "submodules/SettingsUI/Sources/WhitegramContentMediaController.swift",
    "WhitegramContentPhotoExporter.swift": "submodules/SettingsUI/Sources/WhitegramContentPhotoExporter.swift",
    "WhitegramContentStoryPrompt.swift": "submodules/ChatListUI/Sources/WhitegramContentStoryPrompt.swift",
    "WhitegramContentLocation.swift": CORE + "WhitegramContentLocation.swift",
    "WhitegramContentLocationController.swift": "submodules/SettingsUI/Sources/WhitegramContentLocationController.swift",
}
CONTENT_CONTROL_RUNTIME_FILES = PRIVACY_RUNTIME_FILES
PRIVACY_REQUIRED_DEPENDENCIES = {
    "SettingsUI": ["//submodules/LocationUI:LocationUI"],
}


def replace(patches: SourcePatches, feature: str, path: str, before: str, after: str, count: int = 1) -> None:
    """Also reject mixed/duplicate installations that contain both old and new anchors."""
    value = patches.read(path)
    installed = value.count(after)
    if installed:
        if installed != count or before in value.replace(after, ""):
            raise ValueError(f"{feature}: {path}: ambiguous or partial installation")
    patches.replace(feature, path, before, after, count=count)


def receipt_patches(patches: SourcePatches) -> None:
    replace(patches, "perChatGhost", CORE + "State/ManagedLocalInputActivities.swift",
        "WhitegramGhost.suppressActivity(activity)", "WhitegramGhost.suppressActivity(activity, peerId: peerId)")
    replace(patches, "readOnAction", CORE + "State/SynchronizePeerReadState.swift",
        "if WhitegramGhost.suppressReadReceipts {\n", "if WhitegramGhost.suppressAutomaticHistoryReads(for: peerId) {\n")
    anchor = "        |> mapToSignal { inputPeer -> Signal<PeerReadState, PeerReadStateValidationError> in\n"
    replace(patches, "queued-history-read-privacy", CORE + "State/SynchronizePeerReadState.swift", anchor,
        anchor + "            if WhitegramGhost.suppressAutomaticHistoryReads(for: peerId) { return .single(readState) }\n", count=2)
    replace(patches, "perChatGhost", CORE + "State/ManagedSynchronizeConsumeMessageContentsOperations.swift",
        "if WhitegramGhost.suppressReadReceipts {", "if WhitegramGhost.suppressReadReceipts(for: peerId) {")
    personal = CORE + "State/ManagedConsumePersonalMessagesActions.swift"
    replace(patches, "perChatGhost", personal,
        "WhitegramGhost.messageContentsRequest(network: network, ids: [id.id])",
        "WhitegramGhost.messageContentsRequest(network: network, ids: [id.id], peerId: id.peerId)", count=2)
    replace(patches, "perChatGhost", personal,
        "WhitegramGhost.channelContentsRequest(network: network, channel: inputChannel, ids: [id.id])",
        "WhitegramGhost.channelContentsRequest(network: network, channel: inputChannel, ids: [id.id], peerId: id.peerId)", count=2)
    for indent in (12, 16):
        before = "|> `catch` { _ -> Signal<Api.Bool, NoError> in\n" + " " * (indent + 4) + "return .single(.boolFalse)"
        after = "|> `catch` { _ -> Signal<Api.Bool?, NoError> in\n" + " " * (indent + 4) + "return .single(nil)"
        replace(patches, "receipt-local-completion", personal, before, after)

    replace(patches, "readOnAction", CORE + "TelegramEngine/Messages/ApplyMaxReadIndexInteractively.swift",
        "if !WhitegramGhost.suppressReadReceipts {", "if !WhitegramGhost.suppressAutomaticHistoryReads(for: peerId) {", count=6)
    replace(patches, "readOnAction", CORE + "TelegramEngine/Messages/ReplyThreadHistory.swift",
        "if WhitegramGhost.suppressReadReceipts {", "if WhitegramGhost.suppressAutomaticHistoryReads(for: strongSelf.peerId) {")
    mark_all = CORE + "TelegramEngine/Messages/MarkAllChatsAsRead.swift"
    replace(patches, "readOnAction", mark_all,
        "if WhitegramGhost.suppressReadReceipts { continue }", "if WhitegramGhost.suppressReadReceipts || WhitegramContentSettings.readOnAction { continue }")
    replace(patches, "perChatGhost", mark_all,
        "                        let peerId = peer.peerId\n", "                        let peerId = peer.peerId\n                        if WhitegramGhost.isEnabled(for: peerId) { continue }\n")
    replace(patches, "perChatGhost", CORE + "State/ManagedSynchronizeMarkAllUnseenPersonalMessagesOperations.swift",
        "if WhitegramGhost.suppressReadReceipts {", "if WhitegramGhost.suppressReadReceipts(for: peerId) {", count=4)
    tracker = CORE + "State/AccountViewTracker.swift"
    anchor = "    public func updateSeenLiveLocationForMessageIds(messageIds: Set<MessageId>) {\n        self.queue.async {\n"
    replace(patches, "perChatGhost", tracker, anchor,
        anchor + "            let messageIds = Set(messageIds.filter { !WhitegramGhost.suppressReadReceipts(for: $0.peerId) })\n")
    consumed = CORE + "TelegramEngine/Messages/MarkMessageContentAsConsumedInteractively.swift"
    replace(patches, "perChatGhost", consumed,
        "!WhitegramGhost.suppressReadReceipts {", "!WhitegramGhost.suppressReadReceipts(for: message.id.peerId) {", count=3)
    secret = CORE + "State/ManagedSecretChatOutgoingOperations.swift"
    replace(patches, "perChatGhost", secret,
        "private func boxedDecryptedSecretMessageAction(action: SecretMessageAction) -> BoxedDecryptedMessage {",
        "private func boxedDecryptedSecretMessageAction(action: SecretMessageAction, peerId: PeerId) -> BoxedDecryptedMessage {")
    replace(patches, "perChatGhost", secret,
        "boxedDecryptedSecretMessageAction(action: action)",
        "boxedDecryptedSecretMessageAction(action: action, peerId: peerId)")
    replace(patches, "perChatGhost", secret,
        "WhitegramGhost.suppressReadReceipts ?", "WhitegramGhost.suppressReadReceipts(for: peerId) ?", count=5)


def read_action_patches(patches: SourcePatches) -> None:
    apply_read = CORE + "TelegramEngine/Messages/ApplyMaxReadIndexInteractively.swift"
    before = "func _internal_applyMaxReadIndexInteractively(transaction: Transaction, stateManager: AccountStateManager, index: MessageIndex) {\n"
    after = "func _internal_applyMaxReadIndexInteractively(transaction: Transaction, stateManager: AccountStateManager, index: MessageIndex, whitegramReadAction: Bool = false) {\n    if !whitegramReadAction && WhitegramGhost.suppressLocalHistoryRead(for: index.id.peerId) { return }\n"
    replace(patches, "ghost-local-history", apply_read, before, after)
    replace(patches, "ghost-local-history", apply_read,
        "        stateManager.notifyAppliedIncomingReadMessages([index.id])",
        "        if !WhitegramGhost.suppressReadReceipts(for: index.id.peerId) { stateManager.notifyAppliedIncomingReadMessages([index.id]) }")
    thread = CORE + "TelegramEngine/Messages/ReplyThreadHistory.swift"
    replace(patches, "ghost-local-history", thread,
        "    func applyMaxReadIndex(messageIndex: MessageIndex) {\n",
        "    func applyMaxReadIndex(messageIndex: MessageIndex, whitegramReadAction: Bool = false, whitegramReadActionThreadId: Int64? = nil) {\n        if whitegramReadAction && (messageIndex.id.peerId != self.peerId || whitegramReadActionThreadId != self.threadId) { return }\n        if !whitegramReadAction && WhitegramGhost.suppressLocalHistoryRead(for: self.peerId) { return }\n")
    replace(patches, "ghost-local-history", thread,
        "    public func applyMaxReadIndex(messageIndex: MessageIndex) {\n        self.impl.with { impl in\n            impl.applyMaxReadIndex(messageIndex: messageIndex)",
        "    public func applyMaxReadIndex(messageIndex: MessageIndex, whitegramReadAction: Bool = false, whitegramReadActionThreadId: Int64? = nil) {\n        self.impl.with { impl in\n            impl.applyMaxReadIndex(messageIndex: messageIndex, whitegramReadAction: whitegramReadAction, whitegramReadActionThreadId: whitegramReadActionThreadId)")
    replace(patches, "ghost-local-history", thread,
        "_internal_applyMaxReadIndexInteractively(transaction: transaction, stateManager: account.stateManager, index: messageIndex)",
        "_internal_applyMaxReadIndexInteractively(transaction: transaction, stateManager: account.stateManager, index: messageIndex, whitegramReadAction: whitegramReadAction)")
    context = UI + "AccountContext.swift"
    anchor = "    public func applyMaxReadIndex(for location: ChatLocation, contextHolder: Atomic<ChatLocationContextHolder?>, messageIndex: MessageIndex) {\n"
    helper = '''    func whitegramLocalReadAction(for location: ChatLocation, contextHolder: Atomic<ChatLocationContextHolder?>, messageIndex: MessageIndex) -> () -> Void {
        switch location {
        case .peer:
            let account = self.account
            return { let _ = WhitegramReadAction.applyLocalRead(account: account, index: messageIndex).startStandalone() }
        case let .replyThread(data):
            let context = chatLocationContext(holder: contextHolder, account: self.account, data: data)
            return { context.applyMaxReadIndex(messageIndex: messageIndex, whitegramReadAction: true, whitegramReadActionThreadId: data.threadId) }
        case .customChatContents:
            return {}
        }
    }

'''
    replace(patches, "readOnAction", context, anchor, helper + anchor)
    history = UI + "ChatHistoryListNode.swift"
    anchor = "    private let maxVisibleIncomingMessageIndex = ValuePromise<MessageIndex>(ignoreRepeated: true)\n"
    replace(patches, "readOnAction", history, anchor,
        "    private var whitegramVisibleReadIndex: MessageIndex?\n" + anchor)
    anchor = "    private func updateMaxVisibleReadIncomingMessageIndex(_ index: MessageIndex) {\n"
    replace(patches, "readOnAction", history, anchor,
        anchor + "        self.whitegramVisibleReadIndex = index\n")
    anchor = "    private func beginReadHistoryManagement() {\n"
    method = '''    func whitegramReadOnActionSignal() -> Signal<Never, NoError> {
        guard self.canReadHistoryValue,
            !self.context.sharedContext.immediateExperimentalUISettings.skipReadHistory,
            self.subject != .scheduledMessages,
            let index = self.whitegramVisibleReadIndex,
            self.chatLocation.peerId == index.id.peerId else { return .complete() }
        switch self.chatLocation {
        case .peer, .replyThread:
            guard let context = self.context as? AccountContextImpl else { return .complete() }
            let location = self.chatLocation
            let applyLocalRead = context.whitegramLocalReadAction(for: location, contextHolder: self.chatLocationContextHolder, messageIndex: index)
            return WhitegramReadAction.read(account: context.account, index: index, threadId: location.threadId, applyLocalRead: applyLocalRead)
        case .customChatContents:
            return .complete()
        }
    }

'''
    replace(patches, "readOnAction", history, anchor, method + anchor)
    # In-place chat-location changes must not keep an index from another thread.
    location = "    public func updateChatLocation(chatLocation: ChatLocation) {\n        if self.chatLocation == chatLocation {\n            return\n        }\n        self.chatLocation = chatLocation\n"
    replace(patches, "readOnAction", history, location, location + "        self.whitegramVisibleReadIndex = nil\n")

    for path, owner, message in (
        (UI + "ChatController.swift", "self", "self.transformEnqueueMessages(messages, postpone: postpone)"),
        (UI + "Chat/ChatControllerMediaRecording.swift", "self", "transformedMessages"),
        (UI + "Chat/ChatControllerLoadDisplayNode.swift", "strongSelf", "messagesGroup"),
        (UI + "Chat/ChatControllerLoadDisplayNode.swift", "strongSelf", "transformedMessages"),
    ):
        before = f"enqueueMessages(account: {owner}.context.account, peerId: peerId, messages: {message})"
        after = f"whitegramEnqueueMessages(account: {owner}.context.account, peerId: peerId, messages: {message}, readAction: {owner}.chatDisplayNode.historyNode.whitegramReadOnActionSignal())"
        replace(patches, "readOnAction", path, before, after)
    for path, owner, arguments in (
        (UI + "ChatController.swift", "strongSelf", "isLarge: false, storeAsRecentlyUsed: false"),
        (UI + "Chat/ChatControllerOpenMessageContextMenu.swift", "self", "isLarge: isLarge, storeAsRecentlyUsed: true"),
    ):
        anchor = f"let _ = updateMessageReactionsInteractively(account: {owner}.context.account, messageIds: [message.id], reactions: mappedUpdatedReactions, {arguments}).startStandalone()"
        indent = " " * (24 if owner == "strongSelf" else 24)
        replace(patches, "readOnAction", path, anchor,
            f"let _ = {owner}.chatDisplayNode.historyNode.whitegramReadOnActionSignal().startStandalone()\n" + indent + anchor)


def restriction_patches(patches: SourcePatches) -> None:
    peer = CORE + "Utils/PeerUtils.swift"
    anchor = '                if rule.reason == "sensitive" {\n'
    replace(patches, "bypassContentRestrictions", peer, anchor,
        '                if rule.reason == "sensitive" || WhitegramContentSettings.shouldBypassRestriction(reason: rule.reason) {\n')
    platform = "submodules/PlatformRestrictionMatching/Sources/PlatformRestrictionMatching.swift"
    anchor = '            if rule.reason == "sensitive" {\n'
    replace(patches, "bypassContentRestrictions", platform, anchor,
        '            if rule.reason == "sensitive" || WhitegramContentSettings.shouldBypassRestriction(reason: rule.reason) {\n')
    for path, count in ((UI + "ChatInterfaceStateContextMenus.swift", 3), ("submodules/ShareController/Sources/ShareController.swift", 1)):
        # A nil restriction must use the message's real text, not an empty substitute.
        suffix = "context.currentContentSettings.with { $0 }" if path.startswith(UI) else "strongSelf.currentContext.contentSettings"
        before = f'attribute.platformText(platform: "ios", contentSettings: {suffix}) ?? ""'
        replace(patches, "bypassContentRestrictions", path, before, before.removesuffix(' ?? ""'), count=count)

    merge = CORE + "ApiUtils/ApiGroupOrChannel.swift"
    before = "        case .chat, .chatEmpty, .chatForbidden, .channelForbidden, .communityForbidden:\n            return parseTelegramGroupOrChannel(chat: rhs)\n"
    after = '''        case .channelForbidden:
            if let previous = lhs as? TelegramChannel, let updated = parseTelegramGroupOrChannel(chat: rhs) as? TelegramChannel {
                return WhitegramContentPolicy.preservingForbiddenChannelMetadata(previous: previous, updated: updated)
            }
            return parseTelegramGroupOrChannel(chat: rhs)
        case .chat, .chatEmpty, .chatForbidden, .communityForbidden:
            return parseTelegramGroupOrChannel(chat: rhs)
'''
    replace(patches, "keepBannedChats", merge, before, after)
    anchor = "func mergeChannel(lhs: TelegramChannel?, rhs: TelegramChannel) -> TelegramChannel {\n    guard let lhs = lhs else {\n        return rhs\n    }\n"
    replace(patches, "keepBannedChats", merge, anchor,
        anchor + "    if WhitegramContentSettings.keepBannedChats, rhs.participationStatus == .kicked, rhs.creationDate == 0 {\n        return WhitegramContentPolicy.preservingForbiddenChannelMetadata(previous: lhs, updated: rhs)\n    }\n")
    peers = CORE + "UpdatePeers.swift"
    before = "                        case .kicked where channel.creationDate == 0:\n                            transaction.updatePeerChatListInclusion(peerId, inclusion: .notIncluded)\n"
    after = '''                        case .kicked where WhitegramContentSettings.keepBannedChats:
                            // Keep existing local inclusion; never claim membership or create a new dialog.
                            break
                        case .kicked where channel.creationDate == 0:
                            transaction.updatePeerChatListInclusion(peerId, inclusion: .notIncluded)
'''
    replace(patches, "keepBannedChats", peers, before, after)
    replace(patches, "keepBannedChats", UI + "ChatControllerContentData.swift",
        "updatedChannel.participationStatus == .kicked {\n                        shouldDismiss = true\n",
        "updatedChannel.participationStatus == .kicked {\n                        shouldDismiss = !WhitegramContentSettings.keepBannedChats\n")
    panels = UI + "ChatInterfaceStateInputPanels.swift"
    before = "            case .kicked:\n                if let currentPanel = (currentPanel as? DeleteChatInputPanelNode)"
    after = "            case .kicked:\n                if WhitegramContentSettings.keepBannedChats { return (nil, nil) }\n                if let currentPanel = (currentPanel as? DeleteChatInputPanelNode)"
    replace(patches, "keepBannedChats", panels, before, after)


def spoiler_patches(patches: SourcePatches) -> None:
    formatter = "submodules/TextFormat/Sources/StringWithAppliedEntities.swift"
    anchor = "            case .Spoiler:\n                if external {\n"
    replace(patches, "removeSpoilers", formatter, anchor,
        "            case .Spoiler:\n                if WhitegramContentSettings.removeSpoilers { break }\n                if external {\n")
    for path, expression, count in (
        (COMPONENTS + "Chat/ChatMessageInteractiveMediaNode/Sources/ChatMessageInteractiveMediaNode.swift", "message.attributes.contains(where: { $0 is MediaSpoilerMessageAttribute })", 3),
        (COMPONENTS + "Chat/ChatMessageReplyInfoNode/Sources/ChatMessageReplyInfoNode.swift", "message.attributes.contains(where: { $0 is MediaSpoilerMessageAttribute })", 1),
        (COMPONENTS + "PeerInfo/PeerInfoVisualMediaPaneNode/Sources/PeerInfoVisualMediaPaneNode.swift", "message.attributes.contains(where: { $0 is MediaSpoilerMessageAttribute })", 1),
        (UI + "ChatPinnedMessageTitlePanelNode.swift", "message.attributes.contains(where: { $0 is MediaSpoilerMessageAttribute })", 1),
        ("submodules/ChatListUI/Sources/Node/ChatListItem.swift", "self.message.attributes.contains(where: { $0 is MediaSpoilerMessageAttribute })", 1),
    ):
        replace(patches, "removeSpoilers", path, expression, "(!WhitegramContentSettings.removeSpoilers && " + expression + ")", count=count)
    text = COMPONENTS + "Chat/ChatMessageTextBubbleContentNode/Sources/ChatMessageTextBubbleContentNode.swift"
    replace(patches, "removeSpoilers", text,
        "        let displayContentsUnderSpoilers = self.displayContentsUnderSpoilers\n",
        "        let displayContentsUnderSpoilers = (value: self.displayContentsUnderSpoilers.value || WhitegramContentSettings.removeSpoilers, location: self.displayContentsUnderSpoilers.location)\n")
    preview = "submodules/ChatListUI/Sources/Node/ChatListItemStrings.swift"
    replace(patches, "removeSpoilers", preview,
        "    return (peer, hideAuthor, messageText, messageEntities, spoilers, customEmojiRanges, richTextPreview)",
        "    return (peer, hideAuthor, messageText, messageEntities, WhitegramContentSettings.removeSpoilers ? nil : spoilers, customEmojiRanges, richTextPreview)")


def local_export_patches(patches: SourcePatches) -> None:
    menu = UI + "ChatInterfaceStateContextMenus.swift"
    anchor = "        let isCopyProtected = chatPresentationInterfaceState.copyProtectionEnabled || message.isCopyProtected()\n"
    replace(patches, "saveProtectedContent", menu, anchor, anchor +
        "        let isLocalCopyProtected = WhitegramContentPolicy.isLocalCopyProtected(message, peerIsCopyProtected: chatPresentationInterfaceState.copyProtectionEnabled)\n")
    for before, after, count in (
        ("if !isCopyProtected && isWhiteGramMessageContextOptionEnabled(fromPrivate: .privateCopy, channel: .channelCopy)", "if !isLocalCopyProtected && isWhiteGramMessageContextOptionEnabled(fromPrivate: .privateCopy, channel: .channelCopy)", 1),
        ("controllerInteraction.performTextSelectionAction(message, !isCopyProtected,", "controllerInteraction.performTextSelectionAction(message, !isLocalCopyProtected,", 2),
        ("if resourceAvailable, !message.containsSecretMedia && !isCopyProtected {", "if resourceAvailable, !message.containsSecretMedia && !isLocalCopyProtected {", 1),
        ("        if !isCopyProtected {\n            for media in message.effectiveMedia {", "        if !isLocalCopyProtected {\n            for media in message.effectiveMedia {", 1),
    ):
        replace(patches, "saveProtectedContent", menu, before, after, count=count)
    replace(patches, "saveProtectedContent", menu,
        "            if chatPresentationInterfaceState.copyProtectionEnabled {\n",
        "            if chatPresentationInterfaceState.copyProtectionEnabled && !WhitegramContentSettings.saveProtectedContent {\n")
    replace(patches, "saveProtectedContent", menu,
        "                    if file.isMusic {\n                        actions.append(.action(ContextMenuActionItem(text: chatPresentationInterfaceState.strings.Conversation_SaveToFiles,",
        "                    if file.isMusic || (WhitegramContentSettings.saveProtectedContent && isCopyProtected) {\n                        actions.append(.action(ContextMenuActionItem(text: chatPresentationInterfaceState.strings.Conversation_SaveToFiles,")
    for path, before, after, count in (
        (GALLERY + "Items/ChatImageGalleryItem.swift", "guard let message = self.message, !message.isCopyProtected() && message.paidContent == nil else {", "guard let message = self.message, !WhitegramContentPolicy.isLocalCopyProtected(message, peerIsCopyProtected: self.peerIsCopyProtected) && message.paidContent == nil else {", 1),
        (GALLERY + "Items/ChatImageGalleryItem.swift", "if !message.isCopyProtected() && !self.peerIsCopyProtected && message.paidContent == nil, let media =", "if !WhitegramContentPolicy.isLocalCopyProtected(message, peerIsCopyProtected: self.peerIsCopyProtected) && message.paidContent == nil, let media =", 1),
        (GALLERY + "Items/UniversalVideoGalleryItem.swift", "!message.isCopyProtected() && !item.peerIsCopyProtected && message.paidContent == nil", "!WhitegramContentPolicy.isLocalCopyProtected(message, peerIsCopyProtected: item.peerIsCopyProtected) && message.paidContent == nil", 2),
    ):
        replace(patches, "saveProtectedContent", path, before, after, count=count)
    for expression, count in (
        ("message.isCopyProtected() || message.containsSecretMedia || message.minAutoremoveOrClearTimeout == viewOnceTimeout || message.paidContent != nil || peerIsCopyProtected", 2),
        ("message.isCopyProtected() || message.containsSecretMedia || peerIsCopyProtected", 2),
    ):
        replace(patches, "saveProtectedContent", GALLERY + "GalleryController.swift", expression,
            "(!WhitegramContentSettings.saveProtectedContent && (" + expression + "))", count=count)
    expression = "message.id.peerId.namespace == Namespaces.Peer.SecretChat || message.isCopyProtected() || peerIsCopyProtected || isSecret || message.paidContent != nil"
    replace(patches, "saveProtectedContent", GALLERY + "Items/ChatImageGalleryItem.swift", expression,
        "(!WhitegramContentSettings.saveProtectedContent && (" + expression + "))")
    expression = "associatedData.isCopyProtectionEnabled || message.isCopyProtected() || isExtendedMedia"
    replace(patches, "saveProtectedContent", COMPONENTS + "Chat/ChatMessageInteractiveMediaNode/Sources/ChatMessageInteractiveMediaNode.swift", expression,
        "(!WhitegramContentSettings.saveProtectedContent && (" + expression + "))", count=2)
    replace(patches, "saveProtectedContent", COMPONENTS + "Chat/ChatMessageTextBubbleContentNode/Sources/ChatMessageTextBubbleContentNode.swift",
        "(!item.associatedData.isCopyProtectionEnabled && !item.message.isCopyProtected()) || item.message.id.peerId.isVerificationCodes",
        "!WhitegramContentPolicy.isLocalCopyProtected(item.message, peerIsCopyProtected: item.associatedData.isCopyProtectionEnabled) || item.message.id.peerId.isVerificationCodes")
    replace(patches, "saveProtectedContent", UI + "ChatController.swift",
        "copyProtected: self.presentationInterfaceState.copyProtectionEnabled || self.presentationInterfaceState.myCopyProtectionEnabled,",
        "copyProtected: !WhitegramContentSettings.saveProtectedContent && (self.presentationInterfaceState.copyProtectionEnabled || self.presentationInterfaceState.myCopyProtectionEnabled),")

    # The native message menu also provides the recovered per-chat ghost action.
    anchor = "        let isLocalCopyProtected = WhitegramContentPolicy.isLocalCopyProtected(message, peerIsCopyProtected: chatPresentationInterfaceState.copyProtectionEnabled)\n"
    action = '''        if !isEmbeddedMode && message.id.peerId != context.account.peerId {
            let enabled = WhitegramGhost.isEnabled(for: message.id.peerId)
            let language = chatPresentationInterfaceState.strings.baseLanguageCode
            let title = WhitegramLocalization.string(enabled ? "m.ghostOff" : "m.ghostOn", baseLanguage: language)
            actions.append(.action(ContextMenuActionItem(text: title, icon: { theme in
                generateTintedImage(image: UIImage(systemName: "eye.slash"), color: theme.actionSheet.primaryTextColor)
            }, action: { _, finish in
                if !WhitegramGhost.toggle(for: message.id.peerId) {
                    let error = WhitegramLocalization.string("privacy.saveFailed", baseLanguage: language, fallback: "Could not save privacy settings.")
                    controllerInteraction.presentController(textAlertController(context: context, title: nil, text: error, actions: [TextAlertAction(type: .defaultAction, title: chatPresentationInterfaceState.strings.Common_OK, action: {})]), nil)
                }
                finish(.default)
            })))
        }
'''
    replace(patches, "perChatGhost", menu, anchor, anchor + action)


def call_patches(patches: SourcePatches) -> None:
    path = UI + "AccountContext.swift"
    anchor = "    public func requestCall(peerId: PeerId, isVideo: Bool, completion: @escaping () -> Void) {\n"
    after = anchor + '''        guard WhitegramContentSettings.warnBeforeCall else {
            self.whitegramRequestConfirmedCall(peerId: peerId, isVideo: isVideo, completion: completion)
            return
        }
        let confirmation = WhitegramContentConfirmation { [weak self] in
            self?.whitegramRequestConfirmedCall(peerId: peerId, isVideo: isVideo, completion: completion)
        }
        let presentationData = self.sharedContext.currentPresentationData.with { $0 }
        let language = presentationData.strings.baseLanguageCode
        let text = WhitegramLocalization.string(isVideo ? "m.callConfirmVideo" : "m.callConfirmVoice", baseLanguage: language)
        self.sharedContext.mainWindow?.present(textAlertController(context: self, title: nil, text: text, actions: [
            TextAlertAction(type: .genericAction, title: presentationData.strings.Common_Cancel, action: { confirmation.resolve(confirmed: false) }),
            TextAlertAction(type: .defaultAction, title: WhitegramLocalization.string("m.callAction", baseLanguage: language), action: { confirmation.resolve(confirmed: true) })
        ]), on: .root)
    }

    private func whitegramRequestConfirmedCall(peerId: PeerId, isVideo: Bool, completion: @escaping () -> Void) {
'''
    replace(patches, "warnBeforeCall", path, anchor, after)


def story_prompt_patches(patches: SourcePatches) -> None:
    path = "submodules/ChatListUI/Sources/ChatListController.swift"
    before = '''            switch subject {
            case .archive:
                StoryContainerScreen.openArchivedStories(context: self.context, parentController: self, avatarNode: itemNode.avatarNode, sharedProgressDisposable: self.sharedOpenStoryProgressDisposable)
            case let .peer(peerId):
                StoryContainerScreen.openPeerStories(context: self.context, peerId: peerId, parentController: self, avatarNode: itemNode.avatarNode, sharedProgressDisposable: self.sharedOpenStoryProgressDisposable)
            }
'''
    after = '''            whitegramOpenStoriesWithGhostPrompt(context: self.context, present: { [weak self] controller in
                self?.present(controller, in: .window(.root))
            }, open: { [weak self, weak itemNode] in
                guard let self, let itemNode else { return }
''' + "".join("    " + line if line.strip() else line for line in before.splitlines(keepends=True)) + '''            })
'''
    replace(patches, "suggestGhostForStories", path, before, after)


def location_patches(patches: SourcePatches) -> None:
    path = "submodules/LocationUI/Sources/LocationMapNode.swift"
    replace(patches, "fakeLocation", path, "import MapKit\n", "import MapKit\nimport TelegramCore\n")
    before = "    public var currentUserLocation: CLLocation? {\n        return self.mapView?.userLocation.location\n    }\n"
    after = '''    private var whitegramLocationOverride: CLLocation? {
        guard let coordinate = WhitegramContentLocation.effective else { return nil }
        return CLLocation(latitude: coordinate.latitude, longitude: coordinate.longitude)
    }

    public var currentUserLocation: CLLocation? {
        return self.whitegramLocationOverride ?? self.mapView?.userLocation.location
    }
'''
    replace(patches, "fakeLocation", path, before, after)
    replace(patches, "fakeLocation", path,
        "        self.locationPromise.set(.single(location))\n",
        "        self.locationPromise.set(.single(self.whitegramLocationOverride ?? location))\n")
    replace(patches, "fakeLocation", path,
        "        self.locationPromise.set(.single(nil))\n",
        "        self.locationPromise.set(.single(self.whitegramLocationOverride))\n")
    anchor = "    private let locationPromise = Promise<CLLocation?>(nil)\n"
    replace(patches, "fakeLocation", path, anchor, anchor + "    private var whitegramLocationObserver: NSObjectProtocol?\n")
    anchor = "        self.view.addSubview(self.pickerAnnotationContainerView)\n        self.updateHeadingTransforms()\n"
    replace(patches, "fakeLocation", path, anchor, anchor + '''        if let location = self.whitegramLocationOverride {
            self.locationPromise.set(.single(Optional(location)))
        }
        self.whitegramLocationObserver = NotificationCenter.default.addObserver(forName: WhitegramPreferences.updatedNotification, object: nil, queue: .main) { [weak self] _ in
            guard let self else { return }
            self.locationPromise.set(.single(self.currentUserLocation))
        }
''')
    anchor = "    override public func didLoad() {\n"
    replace(patches, "fakeLocation", path, anchor, "    deinit {\n        if let observer = self.whitegramLocationObserver { NotificationCenter.default.removeObserver(observer) }\n    }\n\n" + anchor)


def retained_media_patches(patches: SourcePatches) -> None:
    path = CORE + "TelegramEngine/Messages/MarkMessageContentAsConsumedInteractively.swift"
    before = "func _internal_markMessageContentAsConsumedInteractively(postbox: Postbox, messageId: MessageId) -> Signal<Void, NoError> {\n    return postbox.transaction { transaction -> Void in\n"
    after = "func _internal_markMessageContentAsConsumedInteractively(postbox: Postbox, messageId: MessageId) -> Signal<Void, NoError> {\n    return WhitegramContentMedia.captureBeforeConsumption(postbox: postbox, messageId: messageId)\n    |> then(postbox.transaction { transaction -> Void in\n"
    replace(patches, "retained-media-lifecycle", path, before, after)
    before = "        }\n    }\n}\n\nfunc _internal_markReactionsOrPollVotesAsSeenInteractively"
    after = "        }\n    })\n}\n\nfunc _internal_markReactionsOrPollVotesAsSeenInteractively"
    replace(patches, "retained-media-lifecycle", path, before, after)
    preview = GALLERY + "SecretMediaPreviewController.swift"
    anchor = "    private let markMessageAsConsumedDisposable = MetaDisposable()\n"
    replace(patches, "retained-media-download", preview, anchor, anchor + "    private let whitegramRetainedMediaDisposable = MetaDisposable()\n")
    anchor = "        self.markMessageAsConsumedDisposable.dispose()\n"
    replace(patches, "retained-media-download", preview, anchor, anchor + "        self.whitegramRetainedMediaDisposable.dispose()\n")
    anchor = "                self.currentNodeMessageId = message.id\n"
    replace(patches, "retained-media-download", preview, anchor, anchor + "                self.whitegramRetainedMediaDisposable.set(WhitegramContentMedia.observeViewedMedia(message: message, mediaBox: self.context.account.postbox.mediaBox).start())\n")
    playlist = COMPONENTS + "MediaManager/PeerMessagesMediaPlaylist/Sources/PeerMessagesMediaPlaylist.swift"
    anchor = "    private let currentlyObservedMessageDisposable = MetaDisposable()\n"
    replace(patches, "retained-media-download", playlist, anchor, anchor + "    private let whitegramRetainedMediaDisposable = MetaDisposable()\n")
    anchor = "        self.currentlyObservedMessageDisposable.dispose()\n"
    replace(patches, "retained-media-download", playlist, anchor, anchor + "        self.whitegramRetainedMediaDisposable.dispose()\n")
    anchor = "            let _ = self.context.engine.messages.markMessageContentAsConsumedInteractively(messageId: item.message.id).startStandalone()\n"
    replace(patches, "retained-media-download", playlist, anchor, "            self.whitegramRetainedMediaDisposable.set(WhitegramContentMedia.observeViewedMedia(message: item.message, mediaBox: self.context.account.postbox.mediaBox).start())\n" + anchor)
    startup = UI + "AppDelegate.swift"
    anchor = "        testIsLaunched = true\n"
    replace(patches, "saveViewOnceMedia", startup, anchor, anchor + "        WhitegramContentPhotoExporter.install()\n")

    recording = UI + "Chat/ChatControllerMediaRecording.swift"
    before = "            case let .send(viewOnce):\n                self.chatDisplayNode.updateRecordedMediaDeleted(false)"
    after = "            case let .send(viewOnce):\n                let viewOnce = WhitegramContentPolicy.recordAsViewOnce(requested: viewOnce, eligible: self.whitegramCanSendViewOnceRecording(scheduleTime: nil))\n                self.chatDisplayNode.updateRecordedMediaDeleted(false)"
    replace(patches, "ghostModeRecordOnce", recording, before, after)
    # Voice postprocessing adds an optional argument and a processed-draft callback.
    # The draft guard is stable in both signatures and precedes that callback.
    before = "        guard let recordedMediaPreview = self.presentationInterfaceState.interfaceState.mediaDraftState else {\n            return\n        }\n"
    after = before + "        let viewOnce = WhitegramContentPolicy.recordAsViewOnce(requested: viewOnce, eligible: self.whitegramCanSendViewOnceRecording(scheduleTime: scheduleTime))\n"
    replace(patches, "ghostModeRecordOnce", recording, before, after)
    anchor = "    func sendMediaRecording(\n"
    helper = '''    private func whitegramCanSendViewOnceRecording(scheduleTime: Int32?) -> Bool {
        guard scheduleTime == nil, self.subject != .scheduledMessages,
            self.presentationInterfaceState.sendPaidMessageStars == nil,
            let peer = self.presentationInterfaceState.renderedPeer?.peer as? TelegramUser else { return false }
        return peer.id.namespace == Namespaces.Peer.CloudUser && peer.id != self.context.account.peerId && peer.botInfo == nil
    }

'''
    replace(patches, "ghostModeRecordOnce", recording, anchor, helper + anchor)
    video = COMPONENTS + "VideoMessageCameraScreen/Sources/VideoMessageCameraScreen.swift"
    replace(patches, "ghostModeRecordOnce", video,
        "                if self.cameraState.isViewOnceEnabled {\n                    attributes.append(AutoremoveTimeoutMessageAttribute(timeout: viewOnceTimeout, countdownBeginTime: nil))",
        "                if WhitegramContentPolicy.recordAsViewOnce(requested: self.cameraState.isViewOnceEnabled, eligible: self.viewOnceAvailable && scheduleTime == nil) {\n                    attributes.append(AutoremoveTimeoutMessageAttribute(timeout: viewOnceTimeout, countdownBeginTime: nil))")


def live_privacy_patches(patches: SourcePatches) -> None:
    presence = CORE + "State/ManagedAccountPresence.swift"
    anchor = "    private var wasOnline: Bool = false\n"
    replace(patches, "presence-requested-state", presence, anchor, "    private var whitegramRequestedOnline: Bool = false\n" + anchor)
    replace(patches, "presence-requested-state", presence, "self.updatePresence(self.wasOnline)", "self.updatePresence(self.whitegramRequestedOnline)")
    anchor = "    private func updatePresence(_ isOnline: Bool) {\n"
    replace(patches, "presence-requested-state", presence, anchor, anchor + "        self.whitegramRequestedOnline = isOnline\n")
    history = UI + "ChatHistoryListNode.swift"
    anchor = "    private var canReadHistoryValue: Bool = false\n"
    replace(patches, "privacy-live-rendering", history, anchor,
        anchor + "    private var whitegramContentObserver: NSObjectProtocol?\n")
    anchor = "    private func beginReadHistoryManagement() {\n"
    replace(patches, "privacy-live-rendering", history, anchor, anchor + '''        if self.whitegramContentObserver == nil {
            self.whitegramContentObserver = NotificationCenter.default.addObserver(forName: WhitegramPreferences.updatedNotification, object: nil, queue: .main) { [weak self] _ in
                guard let self else { return }
                self.refreshWhitegramAppearance()
                self.beginReadHistoryManagement()
            }
        }
''')
    replace(patches, "privacy-live-rendering", history, "    deinit {\n",
        "    deinit {\n        if let observer = self.whitegramContentObserver { NotificationCenter.default.removeObserver(observer) }\n")

    ads = CORE + "TelegramEngine/Messages/AdMessages.swift"
    for suffix in ("self.state.set", "self.disposable.set"):
        before = 'if WhitegramPreferences.bool("disableAds") || WhitegramPreferences.bool("hideChannelAds") {\n            ' + suffix
        replace(patches, "disableAds", ads, before, before.replace('WhitegramPreferences.bool("disableAds")', 'WhitegramContentSettings.bool("disableAds")'))
    replace(patches, "disableAds", CORE + "TelegramEngine/Peers/AdPeers.swift",
        'WhitegramPreferences.bool("disableAds")', 'WhitegramContentSettings.bool("disableAds")')
    replace(patches, "disableAds", ads, "    private var isActivated: Bool = false\n",
        "    private var whitegramPrivacyObserver: NSObjectProtocol?\n    private var whitegramActivationRequested = false\n    private var isActivated: Bool = false\n")
    anchor = "        self.account = account\n        self.peerId = peerId\n        self.messageId = messageId\n"
    replace(patches, "disableAds", ads, anchor, anchor + '''        self.whitegramActivationRequested = !activateManually
        self.whitegramPrivacyObserver = NotificationCenter.default.addObserver(forName: WhitegramPreferences.updatedNotification, object: nil, queue: nil) { [weak self] _ in
            self?.queue.async { [weak self] in
                guard let self else { return }
                if WhitegramContentSettings.bool("disableAds") || WhitegramPreferences.bool("hideChannelAds") {
                    self.isActivated = false
                    self.disposable.set(nil)
                    self.stateValue = State(interPostInterval: nil, messages: [])
                    self.state.set(.single(State(interPostInterval: nil, messages: [])))
                } else if self.whitegramActivationRequested {
                    self.activate()
                }
            }
        }
''')
    replace(patches, "disableAds", ads, "    func activate() {\n",
        "    func activate() {\n        self.whitegramActivationRequested = true\n")
    replace(patches, "disableAds", ads, "    deinit {\n        self.disposable.dispose()",
        "    deinit {\n        if let observer = self.whitegramPrivacyObserver { NotificationCenter.default.removeObserver(observer) }\n        self.disposable.dispose()")
    for signature in (
        "    func markAsSeen(opaqueId: Data) {\n",
        "    func markAction(opaqueId: Data, media: Bool, fullscreen: Bool) {\n",
        "func _internal_markAdAction(account: Account, opaqueId: Data, media: Bool, fullscreen: Bool) {\n",
        "func _internal_markAdAsSeen(account: Account, opaqueId: Data) {\n",
    ):
        replace(patches, "disableAds", ads, signature,
            signature + '        if WhitegramContentSettings.bool("disableAds") || WhitegramPreferences.bool("hideChannelAds") { return }\n')


def content_control_patches(patches: SourcePatches) -> None:
    receipt_patches(patches)
    read_action_patches(patches)
    restriction_patches(patches)
    spoiler_patches(patches)
    local_export_patches(patches)
    call_patches(patches)
    story_prompt_patches(patches)
    location_patches(patches)
    retained_media_patches(patches)
    live_privacy_patches(patches)


def apply_privacy_patches(root: Path) -> dict[str, list[str]]:
    patches = SourcePatches(root)
    content_control_patches(patches)
    return patches.write()


def apply_content_control_patches(root: Path) -> dict[str, list[str]]:
    return apply_privacy_patches(root)
