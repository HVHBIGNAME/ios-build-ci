"""Observed plugin events at Telegram's mutation/visibility boundaries.

No JavaScript runs on a Telegram transaction or UIKit queue. Hooks publish
snapshots through TelegramCore's account-scoped, post-commit event hub.
"""

from pathlib import Path

from source_patches import SourcePatches


PLUGIN_HOOK_RUNTIME_FILES = {
    "WhitegramPluginEventHub.swift": "submodules/TelegramCore/Sources/WhitegramPluginEventHub.swift",
    "WhitegramPluginHooks.swift": "submodules/TelegramCore/Sources/WhitegramPluginHooks.swift",
}


def _replace(patches: SourcePatches, feature: str, path: str, before: str, after: str, count: int = 1) -> None:
    value = patches.read(path)
    applied = value.count(after)
    if applied and (applied != count or before in value.replace(after, "")):
        raise ValueError(f"{feature}: {path}: ambiguous partially applied plugin hook")
    patches.replace(feature, path, before, after, count=count)


def plugin_hook_patches(patches: SourcePatches) -> None:
    state = "submodules/TelegramCore/Sources/State/AccountStateManagementUtils.swift"
    anchor = "                let _ = transaction.addMessages(messages, location: location)\n"
    _replace(patches, "pluginIncomingEvents", state, anchor, '''                let whitegramPluginIncomingIds = WhitegramPluginHooks.newIncomingIds(postbox: postbox, transaction: transaction, messages: messages, location: location)
''' + anchor)
    anchor = "                if case .UpperHistoryBlock = location {\n                    for message in messages {\n                        let chatPeerId = message.id.peerId\n"
    _replace(patches, "pluginIncomingEvents", state, anchor, '''                WhitegramPluginHooks.received(postbox: postbox, transaction: transaction, ids: whitegramPluginIncomingIds)
''' + anchor)
    anchor = "                transaction.deleteMessagesWithGlobalIds(ids, forEachMedia: { media in\n"
    _replace(patches, "pluginDeleteEvents", state, anchor, '''                WhitegramPluginHooks.deleted(postbox: postbox, transaction: transaction, ids: transaction.messageIdsForGlobalIds(ids), source: "accountState")
''' + anchor)
    anchor = "                _internal_deleteMessages(transaction: transaction, mediaBox: mediaBox, ids: ids, manualAddMessageThreadStatsDifference: { id, add, remove in\n"
    _replace(patches, "pluginDeleteEvents", state, anchor, anchor.replace("ids: ids,", 'ids: WhitegramPluginHooks.deletingIds(postbox: postbox, transaction: transaction, ids: ids),'))
    updated = "message.withUpdatedLocalTags(updatedLocalTags).withUpdatedFlags(updatedFlags).withUpdatedAttributes(updatedAttributes).withUpdatedMedia(updatedMedia)"
    anchor = "                    var updatedMedia = message.media\n"
    _replace(patches, "pluginEditEvents", state, anchor, anchor + f'''                    defer {{
                        WhitegramPluginHooks.edited(postbox: postbox, previous: previousMessage, updated: {updated}, source: "accountState")
                    }}
''')

    enqueue = "submodules/TelegramCore/Sources/PendingMessages/EnqueueMessage.swift"
    anchor = "        return messageIds\n    } else {\n        return []\n    }\n"
    _replace(patches, "pluginOutgoingEvents", enqueue, anchor, '''        WhitegramPluginHooks.enqueued(postbox: account.postbox, transaction: transaction, ids: messageIds)
''' + anchor)

    sent = "submodules/TelegramCore/Sources/State/ApplyUpdateMessage.swift"
    anchor = "        if let updatedMessage = updatedMessage, case let .Id(updatedId) = updatedMessage.id {\n"
    _replace(patches, "pluginSentEvents", sent, anchor, anchor + '''            WhitegramPluginHooks.sent(postbox: postbox, transaction: transaction, localId: message.id, id: updatedId)
''')
    anchor = "        pendingMessageEvents(mapping.compactMap { message, _, updatedMessage -> PeerPendingMessageDelivered? in\n"
    _replace(patches, "pluginSentEvents", sent, anchor, '''        for (message, _, updatedMessage) in mapping {
            if case let .Id(id) = updatedMessage.id {
                WhitegramPluginHooks.sent(postbox: postbox, transaction: transaction, localId: message.id, id: id)
            }
        }
''' + anchor)

    deletion = "submodules/TelegramCore/Sources/TelegramEngine/Messages/DeleteMessagesInteractively.swift"
    anchor = "    var uniqueIds: [Int64: PeerId] = [:]\n"
    _replace(patches, "pluginDeleteEvents", deletion, anchor, '''    WhitegramPluginHooks.deleted(postbox: postbox, transaction: transaction, ids: messageIds.map(\\.messageId), source: "interactiveDelete")
''' + anchor)
    editing = "submodules/TelegramCore/Sources/PendingMessages/RequestEditMessage.swift"
    updated = "message.withUpdatedLocalTags(updatedLocalTags).withUpdatedFlags(updatedFlags).withUpdatedMedia(updatedMedia)"
    anchor = "                                                var updatedMedia = message.media\n"
    _replace(patches, "pluginEditEvents", editing, anchor, anchor + f'''                                                defer {{
                                                    WhitegramPluginHooks.edited(postbox: postbox, previous: previousMessage, updated: {updated}, source: "editAcknowledgement")
                                                }}
''', count=4)

    chat = "submodules/TelegramUI/Sources/ChatController.swift"
    anchor = "    var returnInputViewFocus = false\n"
    _replace(patches, "pluginChatEvents", chat, anchor, '''    private let whitegramPluginChatToken = UUID().uuidString
''' + anchor)
    anchor = "    override public func viewDidAppear(_ animated: Bool) {\n        super.viewDidAppear(animated)\n"
    _replace(patches, "pluginChatEvents", chat, anchor, anchor + '''
        if case .standard(.default) = self.mode, let peerId = self.chatLocation.peerId {
            WhitegramPluginHooks.chatOpened(postbox: self.context.account.postbox, token: self.whitegramPluginChatToken,
                peerId: peerId, threadId: self.chatLocation.threadId, peer: self.presentationInterfaceState.renderedPeer?.peer)
        }
''')
    anchor = "    override public func viewWillDisappear(_ animated: Bool) {\n"
    _replace(patches, "pluginChatEvents", chat, anchor, '''    override public func viewDidDisappear(_ animated: Bool) {
        super.viewDidDisappear(animated)
        WhitegramPluginHooks.chatClosed(postbox: self.context.account.postbox, token: self.whitegramPluginChatToken)
    }

''' + anchor)
    anchor = "    deinit {\n"
    _replace(patches, "pluginChatEvents", chat, anchor, anchor + '''        WhitegramPluginHooks.chatClosed(postbox: self.context.account.postbox, token: self.whitegramPluginChatToken)
''')


def apply_plugin_hook_patches(root: Path) -> dict[str, list[str]]:
    patches = SourcePatches(root)
    plugin_hook_patches(patches)
    return patches.write()
