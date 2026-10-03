"""History capture and native message-menu integration, staged before any source writes."""

from pathlib import Path

from source_patches import SourcePatches


STATE = "submodules/TelegramCore/Sources/State/AccountStateManagementUtils.swift"
DELETION = "submodules/TelegramCore/Sources/TelegramEngine/Messages/DeleteMessagesInteractively.swift"
EDITING = "submodules/TelegramCore/Sources/PendingMessages/RequestEditMessage.swift"
MENU = "submodules/TelegramUI/Sources/ChatInterfaceStateContextMenus.swift"
DELETE_CORE = "submodules/TelegramCore/Sources/TelegramEngine/Messages/DeleteMessages.swift"
POSTBOX = "submodules/Postbox/Sources/Postbox.swift"
ACCOUNT = "submodules/TelegramCore/Sources/Account/AccountManager.swift"
ENTRIES = "submodules/TelegramUI/Sources/ChatHistoryEntriesForView.swift"
LIST = "submodules/TelegramUI/Sources/ChatHistoryListNode.swift"
ITEM = "submodules/TelegramUI/Components/Chat/ChatMessageItemView/Sources/ChatMessageItemView.swift"
STATUS = "submodules/TelegramUI/Components/Chat/ChatMessageDateAndStatusNode/Sources/StringForMessageTimestampStatus.swift"
TEXT = "submodules/TelegramUI/Components/Chat/ChatMessageTextBubbleContentNode/Sources/ChatMessageTextBubbleContentNode.swift"

HISTORY_RUNTIME_FILES = {
    **{name + ".swift": "submodules/TelegramCore/Sources/" + name + ".swift" for name in (
        "WhitegramHistoryModels", "WhitegramHistoryStore", "WhitegramHistoryCapture",
        "WhitegramHistoryPolicy", "WhitegramHistoryMessageAttribute", "WhitegramHistoryRuntime",
        "WhitegramHistoryOperations", "WhitegramHistoryLegacyBackup",
    )},
    **{name + ".swift": "submodules/SettingsUI/Sources/" + name + ".swift" for name in (
        "WhitegramHistoryController", "WhitegramHistoryPresentation", "WhitegramHistoryNativeController",
    )},
    "WhitegramHistoryPostbox.swift": "submodules/Postbox/Sources/WhitegramHistoryPostbox.swift",
}


def _edit_capture(patches: SourcePatches, path: str, indent: str, media_box: str, return_line: str, count: int = 1):
    feature = "showEditedOriginalText"
    capture = f"{indent}    WhitegramHistoryStore.capture(previousMessage, event: .edited, accountPeerId: accountPeerId, mediaBoxPath: {media_box})\n"

    def block(condition):
        return f"{indent}if {condition} {{\n{capture}{indent}}}\n"

    before = indent + return_line + "\n"
    updated = return_line.removeprefix("return .update(").removesuffix(")")
    condition = "previousMessage.text != message.text || WhitegramHistoryStore.hasMediaChanges(previousMessage.media, updatedMedia) || WhitegramHistoryRuntime.hasEntityChanges(previousMessage, message.attributes)"
    after = block(condition) + f"{indent}return .update(WhitegramHistoryRuntime.recordEdit(previous: previousMessage, updated: {updated}, accountPeerId: accountPeerId, mediaBoxPath: {media_box}))\n"
    if patches.read(path).count(after) == count:
        patches.replace(feature, path, before, after, count=count)
        return
    if "WhitegramHistoryRuntime.recordEdit(" in patches.read(path):
        raise ValueError(f"{feature}: {path}: unrecognized or partial native edit hooks")

    # Move the previous overlay's early capture past Telegram's paid-media preservation rule.
    for condition in (
        "previousMessage.text != message.text",
        "previousMessage.text != message.text || WhitegramHistoryStore.hasMediaChanges(previousMessage.media, message.media)",
        "previousMessage.text != message.text || WhitegramHistoryStore.hasMediaChanges(previousMessage.media, updatedMedia)",
    ):
        legacy = block(condition)
        if legacy in patches.read(path):
            patches.replace(feature, path, legacy, "", count=count)

    value = patches.read(path)
    if value.count("WhitegramHistoryStore.capture(previousMessage, event: .edited") != 0:
        raise ValueError(f"{feature}: {path}: unrecognized or partial edit capture hooks")
    patches.replace(feature, path, before, after, count=count)


def _capture_patches(patches: SourcePatches):
    path = STATE
    anchor = "                let _ = transaction.addMessages(messages, location: location)\n"
    patches.replace("saveChatHistory", path, anchor, anchor + '''                if WhitegramPreferences.bool("saveChatHistory") {
                    for storedMessage in messages {
                        if case let .Id(id) = storedMessage.id, let message = transaction.getMessage(id) {
                            WhitegramHistoryStore.capture(message, event: .received, accountPeerId: accountPeerId, mediaBoxPath: mediaBox.basePath)
                        }
                    }
                }
''')
    anchor = "            case let .DeleteMessages(ids):\n                _internal_deleteMessages"
    patches.replace("showDeletedMessages", path, anchor, '''            case let .DeleteMessages(ids):
                for id in ids {
                    if let message = transaction.getMessage(id) {
                        WhitegramHistoryStore.capture(message, event: .deleted, accountPeerId: accountPeerId, mediaBoxPath: mediaBox.basePath)
                    }
                }
                _internal_deleteMessages''')
    anchor = "            case let .DeleteMessagesWithGlobalIds(ids):\n                var resourceIds: [MediaResourceId] = []"
    patches.replace("showDeletedMessages", path, anchor, '''            case let .DeleteMessagesWithGlobalIds(ids):
                for id in transaction.messageIdsForGlobalIds(ids) {
                    if let message = transaction.getMessage(id) {
                        WhitegramHistoryStore.capture(message, event: .deleted, accountPeerId: accountPeerId, mediaBoxPath: mediaBox.basePath)
                    }
                }
                var resourceIds: [MediaResourceId] = []''')
    _edit_capture(patches, path, " " * 20, "mediaBox.basePath",
                  "return .update(message.withUpdatedLocalTags(updatedLocalTags).withUpdatedFlags(updatedFlags).withUpdatedAttributes(updatedAttributes).withUpdatedMedia(updatedMedia))")
    deletion = DELETION
    anchor = "    _internal_deleteMessages(transaction: transaction, mediaBox: postbox.mediaBox, ids: messageIds.map(\\.messageId)"
    patches.replace("showDeletedMessages", deletion, anchor, '''    if let accountPeerId = stateManager?.accountPeerId {
        for item in messageIds {
            if let message = transaction.getMessage(item.messageId) {
                WhitegramHistoryStore.capture(message, event: .deleted, accountPeerId: accountPeerId, mediaBoxPath: postbox.mediaBox.basePath)
            }
        }
    }
''' + anchor)
    editing = EDITING
    _edit_capture(patches, editing, " " * 48, "postbox.mediaBox.basePath",
                  "return .update(message.withUpdatedLocalTags(updatedLocalTags).withUpdatedFlags(updatedFlags).withUpdatedMedia(updatedMedia))", count=4)


def _native_retention_patches(patches: SourcePatches):
    anchor = "    declareEncodable(EditedMessageAttribute.self, f: { EditedMessageAttribute(decoder: $0) })\n"
    patches.replace("historyNativeCoding", ACCOUNT, anchor, anchor + "    declareEncodable(WhitegramHistoryMessageAttribute.self, f: { WhitegramHistoryMessageAttribute(decoder: $0) })\n    declareEncodable(WhitegramHistoryEdit.self, f: { WhitegramHistoryEdit(decoder: $0) })\n")

    anchor = "            return postbox.addMessages(transaction: self, messages: messages, location: location)"
    patches.replace("historyRefreshPreservation", POSTBOX, anchor, "            return postbox.addMessages(transaction: self, messages: whitegramHistoryPreservingMessages(transaction: self, messages: messages), location: location)")
    anchor = "        self.postbox?.updateMessage(transaction: self, id: id, update: update)"
    patches.replace("historyRefreshPreservation", POSTBOX, anchor, '''        self.postbox?.updateMessage(transaction: self, id: id, update: { previous in
            switch update(previous) {
            case let .update(updated):
                return .update(whitegramHistoryPreservingAttributes(previous: previous, updated: updated))
            case .skip:
                return .skip
            }
        })''')
    anchor = "            let messageIds = postbox.messageIdsForGlobalIds(ids)\n            postbox.deleteMessages(messageIds, forEachMedia: forEachMedia)"
    patches.replace("historyGlobalRetention", POSTBOX, anchor, '''            let messageIds = postbox.messageIdsForGlobalIds(ids)
            let removable = whitegramHistoryDeletableGlobalMessageIds(transaction: self, ids: messageIds)
            postbox.deleteMessages(removable, forEachMedia: forEachMedia)''')

    anchor = "public func _internal_deleteMessages(transaction: Transaction, mediaBox: MediaBox, ids: [MessageId], deleteMedia: Bool = true, manualAddMessageThreadStatsDifference: ((MessageThreadKey, Int, Int) -> Void)? = nil) {\n"
    after = anchor.replace("deleteMedia: Bool = true,", "deleteMedia: Bool = true, serverInitiated: Bool = true,")
    after += "    let ids = WhitegramHistoryRuntime.deletableIds(transaction: transaction, mediaBox: mediaBox, ids: ids, serverInitiated: serverInitiated)\n"
    patches.replace("historyNativeRetention", DELETE_CORE, anchor, after)
    anchor = "    _internal_deleteMessages(transaction: transaction, mediaBox: postbox.mediaBox, ids: messageIds.map(\\.messageId))"
    patches.replace("historyExplicitLocalPurge", DELETION, anchor, anchor[:-1] + ", serverInitiated: false)")

    # Keep plugin_hook_patches' raw-id event anchors intact in both assembly orders.
    anchor = '''            case let .DeleteMessagesWithGlobalIds(ids):
                for id in transaction.messageIdsForGlobalIds(ids) {
                    if let message = transaction.getMessage(id) {
                        WhitegramHistoryStore.capture(message, event: .deleted, accountPeerId: accountPeerId, mediaBoxPath: mediaBox.basePath)
                    }
                }
                var resourceIds: [MediaResourceId] = []
'''
    patches.replace("historyGlobalRetention", STATE, anchor, anchor + "                WhitegramHistoryRuntime.prepareGlobalDeletion(transaction: transaction, mediaBox: mediaBox, ids: ids)\n")

    anchor = '''                transaction.deleteMessagesInRange(peerId: id.peerId, namespace: id.namespace, minId: 1, maxId: id.id, forEachMedia: { media in
                    addMessageMediaResourceIdsToRemove(media: media, resourceIds: &resourceIds)
                })'''
    patches.replace("historyMinimumAvailableRetention", STATE, anchor, '''                if !WhitegramHistoryRuntime.preserveMinimumAvailable(transaction: transaction, mediaBox: mediaBox, id: id) {
    ''' + anchor + '''
                }''')

    for name, argument in (("Author", "authorId"), ("ForwardAuthor", "forwardAuthorId")):
        anchor = f"    transaction.removeAllMessagesWith{name}(peerId, {argument}: {argument}, namespace: namespace, forEachMedia: {{ media in\n"
        predicate = "message.author?.id == authorId" if name == "Author" else "message.forwardInfo?.author?.id == forwardAuthorId"
        replacement = f'''    var whitegramHistoryIds: [MessageId] = []
    transaction.withAllMessages(peerId: peerId, namespace: namespace) {{ message in
        if {predicate} {{ whitegramHistoryIds.append(message.id) }}
        return true
    }}
    let whitegramHistoryRemovableIds = WhitegramHistoryRuntime.deletableIds(transaction: transaction, mediaBox: mediaBox, ids: whitegramHistoryIds, serverInitiated: false)
    transaction.deleteMessages(whitegramHistoryRemovableIds, forEachMedia: {{ media in
'''
        patches.replace("historyAuthorRetention", DELETE_CORE, anchor, replacement)

    for timestamps in ("minTimestamp: nil, maxTimestamp: nil", "minTimestamp: minTimestamp, maxTimestamp: maxTimestamp"):
        anchor = f"    transaction.clearHistory(peerId, threadId: threadId, {timestamps}, namespaces: namespaces, forEachMedia: {{ _ in\n"
        invocation = f"    WhitegramHistoryRuntime.observeBeforeClear(transaction: transaction, mediaBox: mediaBox, peerId: peerId, threadId: threadId, namespaces: namespaces, {timestamps})\n"
        patches.replace("historyScopedClearCapture", DELETE_CORE, anchor, invocation + anchor)


def _chat_presentation_patches(patches: SourcePatches):
    anchor = "    loop: for entry in view.entries {\n        var message = entry.message\n"
    patches.replace("historyInlinePresentation", ENTRIES, anchor, '''    loop: for entry in view.entries {
        if WhitegramPreferences.bool("saveChatHistory") {
            WhitegramHistoryStore.capture(entry.message, event: .received, accountPeerId: context.account.peerId, mediaBoxPath: context.account.postbox.mediaBox.basePath)
        }
        if !WhitegramHistoryRuntime.shouldDisplay(entry.message, accountPeerId: context.account.peerId) { continue }
        var message = WhitegramHistoryRuntime.displayMessage(entry.message)
''')
    anchor = "        let promises = combineLatest(\n            self.historyAppearsClearedPromise.get(),\n"
    patches.replace("historyLivePreferences", LIST, anchor, '''        let whitegramHistoryReload = combineLatest(self.historyAppearsClearedPromise.get(), whitegramHistorySettingsSignal())
        |> map { value, _ in value }
        let promises = combineLatest(
            whitegramHistoryReload,
''')
    anchor = "    open var item: ChatMessageItem?\n"
    patches.replace("deletedMessagesOpacity", ITEM, anchor, '''    open var item: ChatMessageItem? {
        didSet {
            if let item = self.item {
                self.alpha = CGFloat(WhitegramHistoryRuntime.displayOpacity(item.message, accountPeerId: item.context.account.peerId))
            } else {
                self.alpha = 1.0
            }
        }
    }
''')
    anchor = "    return dateText\n"
    patches.replace("historyStatusLabel", STATUS, anchor, '''    return WhitegramHistoryRuntime.statusText(dateText, message: message._asMessage(), accountPeerId: context.account.peerId, russian: strings.baseLanguageCode.hasPrefix("ru"))
''')
    anchor = "                var customTruncationToken: ((UIFont, Bool) -> NSAttributedString?)?\n"
    patches.replace("showEditedOriginalText", TEXT, anchor, '''                var whitegramCanShowOriginal = !item.presentationData.isPreview && item.attributes.updatingMedia == nil && invoice == nil && story == nil && !isUnsupportedMedia
                if let subject = item.associatedData.subject, case .messageOptions = subject { whitegramCanShowOriginal = false }
                if whitegramCanShowOriginal, let original = WhitegramHistoryRuntime.originalForDisplay(item.message, accountPeerId: item.context.account.peerId) {
                    let originalFont = textFont.withSize(textFont.pointSize * 0.85)
                    let originalColor = messageTheme.primaryTextColor.withAlphaComponent(0.7)
                    let originalEntities = original.entities.filter { $0.range.lowerBound >= 0 && $0.range.upperBound <= original.text.utf16.count }
                    let originalText = NSMutableAttributedString(attributedString: stringWithAppliedEntities(original.text, entities: originalEntities, strings: item.presentationData.strings, dateTimeFormat: item.presentationData.dateTimeFormat, baseColor: originalColor, linkColor: messageTheme.linkTextColor.withAlphaComponent(0.7), baseFont: originalFont, linkFont: originalFont, boldFont: item.presentationData.messageBoldFont.withSize(originalFont.pointSize), italicFont: item.presentationData.messageItalicFont.withSize(originalFont.pointSize), boldItalicFont: item.presentationData.messageBoldItalicFont.withSize(originalFont.pointSize), fixedFont: item.presentationData.messageFixedFont.withSize(originalFont.pointSize), blockQuoteFont: item.presentationData.messageBlockQuoteFont.withSize(originalFont.pointSize), message: item.message))
                    for entity in originalEntities {
                        if case let .CustomEmoji(_, fileId) = entity.type, let range = validatedEntityRange(entity.range, in: originalText) {
                            originalText.addAttribute(ChatTextInputAttributes.customEmoji, value: ChatTextInputTextCustomEmojiAttribute(interactivelySelectedFromPackId: nil, fileId: fileId, file: item.message.associatedMedia[EngineMedia.Id(namespace: Namespaces.Media.CloudFile, id: fileId)] as? TelegramMediaFile), range: range)
                        }
                    }
                    let combined = NSMutableAttributedString(attributedString: attributedText)
                    let heading = item.presentationData.strings.baseLanguageCode.hasPrefix("ru") ? "Исходный текст:" : "Original text:"
                    combined.append(NSAttributedString(string: "\\n\\n" + heading + "\\n", font: originalFont, textColor: originalColor))
                    combined.append(originalText)
                    attributedText = combined
                }

''' + anchor)


def _message_menu_patch(patches: SourcePatches):
    path = MENU
    anchor = "        let isMigrated: Bool\n"
    patches.replace("messageHistoryContextMenu", path, anchor, '''        if message.id.namespace == Namespaces.Message.Cloud && message.id.peerId.namespace != Namespaces.Peer.SecretChat && !isAction && !isEmbeddedMode {
            let historyTitle = chatPresentationInterfaceState.strings.baseLanguageCode.hasPrefix("ru") ? "История сообщения" : "Message history"
            actions.append(.action(ContextMenuActionItem(text: historyTitle, icon: { theme in
                return generateTintedImage(image: UIImage(bundleImageName: "Chat/Context Menu/Calendar"), color: theme.actionSheet.primaryTextColor)
            }, action: { c, _ in
                c?.dismiss(completion: {
                    controllerInteraction.navigationController()?.pushViewController(whitegramMessageHistoryController(context: context, messageId: message.id))
                })
            })))
        }

''' + anchor)


def apply_history_patches(root: Path) -> dict[str, list[str]]:
    patches = SourcePatches(root)
    _capture_patches(patches)
    _message_menu_patch(patches)
    _native_retention_patches(patches)
    _chat_presentation_patches(patches)
    # A drifted, partly installed hook must not be mistaken for an unpatched prefix anchor.
    for path, count in ((STATE, 4), (DELETION, 1), (EDITING, 4)):
        if patches.read(path).count("WhitegramHistoryStore.capture(") != count:
            raise ValueError(f"history capture inventory: {path}: expected {count} capture sites")
    if patches.read(MENU).count("whitegramMessageHistoryController(") != 1:
        raise ValueError(f"messageHistoryContextMenu: {MENU}: expected one history action")
    inventory = {
        POSTBOX: ("whitegramHistoryPreservingMessages(", 1),
        DELETE_CORE: ("let ids = WhitegramHistoryRuntime.deletableIds(", 1),
        ENTRIES: ("WhitegramHistoryRuntime.shouldDisplay(", 1),
        ITEM: ("WhitegramHistoryRuntime.displayOpacity(", 1),
        STATUS: ("WhitegramHistoryRuntime.statusText(", 1),
        TEXT: ("WhitegramHistoryRuntime.originalForDisplay(", 1),
    }
    for path, (marker, count) in inventory.items():
        if patches.read(path).count(marker) != count:
            raise ValueError(f"history native inventory: {path}: expected {count} {marker}")
    return patches.write()
