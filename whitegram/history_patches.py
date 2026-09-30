"""History capture and native message-menu integration, staged before any source writes."""

from pathlib import Path

from source_patches import SourcePatches


STATE = "submodules/TelegramCore/Sources/State/AccountStateManagementUtils.swift"
DELETION = "submodules/TelegramCore/Sources/TelegramEngine/Messages/DeleteMessagesInteractively.swift"
EDITING = "submodules/TelegramCore/Sources/PendingMessages/RequestEditMessage.swift"
MENU = "submodules/TelegramUI/Sources/ChatInterfaceStateContextMenus.swift"


def _edit_capture(patches: SourcePatches, path: str, indent: str, media_box: str, return_line: str, count: int = 1):
    feature = "showEditedOriginalText"
    capture = f"{indent}    WhitegramHistoryStore.capture(previousMessage, event: .edited, accountPeerId: accountPeerId, mediaBoxPath: {media_box})\n"

    def block(condition):
        return f"{indent}if {condition} {{\n{capture}{indent}}}\n"

    # Move the previous overlay's early capture past Telegram's paid-media preservation rule.
    for condition in (
        "previousMessage.text != message.text",
        "previousMessage.text != message.text || WhitegramHistoryStore.hasMediaChanges(previousMessage.media, message.media)",
    ):
        legacy = block(condition)
        if legacy in patches.read(path):
            patches.replace(feature, path, legacy, "", count=count)

    before = indent + return_line + "\n"
    after = block("previousMessage.text != message.text || WhitegramHistoryStore.hasMediaChanges(previousMessage.media, updatedMedia)") + before
    value = patches.read(path)
    expected_captures = count if value.count(after) == count else 0
    if value.count("WhitegramHistoryStore.capture(previousMessage, event: .edited") != expected_captures:
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
    anchor = "    _internal_deleteMessages(transaction: transaction, mediaBox: postbox.mediaBox, ids: messageIds.map(\\.messageId))"
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
    # A drifted, partly installed hook must not be mistaken for an unpatched prefix anchor.
    for path, count in ((STATE, 4), (DELETION, 1), (EDITING, 4)):
        if patches.read(path).count("WhitegramHistoryStore.capture(") != count:
            raise ValueError(f"history capture inventory: {path}: expected {count} capture sites")
    if patches.read(MENU).count("whitegramMessageHistoryController(") != 1:
        raise ValueError(f"messageHistoryContextMenu: {MENU}: expected one history action")
    return patches.write()
