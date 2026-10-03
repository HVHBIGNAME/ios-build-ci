"""Observed plugin events at Telegram's mutation/visibility boundaries.

No JavaScript runs on a Telegram transaction or UIKit queue. Hooks publish
snapshots through TelegramCore's account-scoped, post-commit event hub.
"""

from pathlib import Path

from source_patches import SourcePatches


PLUGIN_HOOK_RUNTIME_FILES = {
    "WhitegramPluginEventHub.swift": "submodules/TelegramCore/Sources/WhitegramPluginEventHub.swift",
    "WhitegramPluginHooks.swift": "submodules/TelegramCore/Sources/WhitegramPluginHooks.swift",
    "WhitegramPluginInterception.swift": "submodules/TelegramCore/Sources/WhitegramPluginInterception.swift",
    "WhitegramPluginNativeInterception.swift": "submodules/TelegramCore/Sources/WhitegramPluginNativeInterception.swift",
    "WhitegramPluginArchive.swift": "submodules/SettingsUI/Sources/Whitegram/WhitegramPluginArchive.swift",
    "WhitegramPluginContributions.swift": "submodules/TelegramCore/Sources/WhitegramPluginContributions.swift",
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
    anchor = "public func enqueueMessages(account: Account, peerId: PeerId, messages: [EnqueueMessage]) -> Signal<[MessageId?], NoError> {\n"
    _replace(patches, "pluginSendInterception", enqueue, anchor, anchor + '''    return WhitegramPluginNativeInterception.outgoing(account: account, peerId: peerId, messages: messages)
    |> mapToSignal { accepted -> Signal<[MessageId?], NoError> in
        guard let accepted = accepted else { return .single(Array(repeating: nil, count: messages.count)) }
        return whitegramPluginEnqueueAcceptedMessages(account: account, peerId: peerId, messages: accepted)
    }
}

private func whitegramPluginEnqueueAcceptedMessages(account: Account, peerId: PeerId, messages: [EnqueueMessage]) -> Signal<[MessageId?], NoError> {
''')
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

    network = "submodules/TelegramCore/Sources/Network/Network.swift"
    for signature, result in [
        ("requestWithAdditionalInfo<T>(_ data: (FunctionDescription, Buffer, DeserializeFunctionResponse<T>), info: NetworkRequestAdditionalInfo", "NetworkRequestResult<T>"),
        ("request<T>(_ data: (FunctionDescription, Buffer, DeserializeFunctionResponse<T>)", "T"),
    ]:
        anchor = f"    public func {signature}, tag: NetworkRequestDependencyTag? = nil, automaticFloodWait: Bool = true, onFloodWaitError: ((String) -> Void)? = nil) -> Signal<{result}, MTRpcError> {{\n        let requestService = self.requestService\n"
        _replace(patches, "pluginRequestInterception", network, anchor, anchor + f'''        return WhitegramPluginNativeInterception.request(network: self, description: data.0)
        |> mapToSignal {{ _ -> Signal<{result}, MTRpcError> in
''')
    anchor = "                requestService?.removeRequest(byInternalId: internalId)\n            }\n        }\n    }\n"
    _replace(patches, "pluginRequestInterception", network, anchor, anchor.replace("\n        }\n    }\n", "\n        }\n        }\n    }\n"), count=2)
    anchor = "            request.completed = { (boxedResponse, timestamp, error) -> () in\n"
    _replace(patches, "pluginRequestEvents", network, anchor, anchor + '''                WhitegramPluginNativeInterception.response(network: self, description: data.0, error: error)
''', count=2)

    root_controller = "submodules/TelegramUI/Sources/TelegramRootController.swift"
    anchor = "    required public init(coder aDecoder: NSCoder) {\n"
    _replace(patches, "pluginAutostart", root_controller, anchor, '''    override public func viewDidAppear(_ animated: Bool) {
        super.viewDidAppear(animated)
        whitegramBootstrapPlugins(context: self.context, navigation: self)
    }

''' + anchor)

    menu = "submodules/TelegramUI/Sources/ChatInterfaceStateContextMenus.swift"
    anchor = "        return ContextController.Items(content: .list(actions), tip: nil)\n"
    _replace(patches, "pluginMessageMenu", menu, anchor, '''        if message.id.namespace == Namespaces.Message.Cloud,
           [Namespaces.Peer.CloudUser, Namespaces.Peer.CloudGroup, Namespaces.Peer.CloudChannel].contains(message.id.peerId.namespace) {
            let pluginItems = WhitegramPluginContributions.shared.messageMenu(scope: context.account.postbox)
            if !pluginItems.isEmpty { actions.append(.separator) }
            for item in pluginItems {
                actions.append(.action(ContextMenuActionItem(text: item.title, icon: { theme in
                    return UIImage(systemName: item.icon)?.withTintColor(theme.contextMenu.primaryColor, renderingMode: .alwaysOriginal)
                }, action: { _, f in
                    f(.dismissWithoutContent)
                    WhitegramPluginContributions.shared.activate(scope: context.account.postbox, token: item.token, payload: [
                        "id": item.id, "peerId": String(message.id.peerId.toInt64()), "messageId": message.id.id,
                        "text": String(decoding: message.text.utf8.prefix(16384), as: UTF8.self),
                        "namespace": message.id.namespace, "scope": "messageMenu"
                    ])
                })))
            }
        }
''' + anchor)


def apply_plugin_hook_patches(root: Path) -> dict[str, list[str]]:
    patches = SourcePatches(root)
    plugin_hook_patches(patches)
    return patches.write()
