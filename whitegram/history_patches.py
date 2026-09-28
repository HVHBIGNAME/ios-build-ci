from pathlib import Path

from source_patches import SourcePatches


def apply_history_patches(root: Path) -> dict[str, list[str]]:
    patches = SourcePatches(root)
    path = "submodules/TelegramCore/Sources/State/AccountStateManagementUtils.swift"
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
    anchor = "                transaction.updateMessage(id, update: { previousMessage in\n                    var updatedFlags = message.flags"
    patches.replace("showEditedOriginalText", path, anchor, '''                transaction.updateMessage(id, update: { previousMessage in
                    if previousMessage.text != message.text {
                        WhitegramHistoryStore.capture(previousMessage, event: .edited, accountPeerId: accountPeerId, mediaBoxPath: mediaBox.basePath)
                    }
                    var updatedFlags = message.flags''')
    deletion = "submodules/TelegramCore/Sources/TelegramEngine/Messages/DeleteMessagesInteractively.swift"
    anchor = "    _internal_deleteMessages(transaction: transaction, mediaBox: postbox.mediaBox, ids: messageIds.map(\\.messageId))"
    patches.replace("showDeletedMessages", deletion, anchor, '''    if let accountPeerId = stateManager?.accountPeerId {
        for item in messageIds {
            if let message = transaction.getMessage(item.messageId) {
                WhitegramHistoryStore.capture(message, event: .deleted, accountPeerId: accountPeerId, mediaBoxPath: postbox.mediaBox.basePath)
            }
        }
    }
''' + anchor)
    editing = "submodules/TelegramCore/Sources/PendingMessages/RequestEditMessage.swift"
    anchor = "                                            transaction.updateMessage(id, update: { previousMessage in\n"
    patches.replace("showEditedOriginalText", editing, anchor, anchor + '''                                                if previousMessage.text != message.text {
                                                    WhitegramHistoryStore.capture(previousMessage, event: .edited, accountPeerId: accountPeerId, mediaBoxPath: postbox.mediaBox.basePath)
                                                }
''', count=4)
    return patches.write()
