"""Expose the recovered Saved Messages action through the existing forward pipeline."""

from pathlib import Path
from source_patches import SourcePatches

MENU = "submodules/TelegramUI/Sources/ChatInterfaceStateContextMenus.swift"
ANCHOR = "        if data.messageActions.options.contains(.forward), isWhiteGramMessageContextOptionEnabled(fromPrivate: .privateForward, channel: .channelForward) {\n"
ACTION = '''        if WhitegramPreferences.bool("saveToFavoritesInMenu"), data.messageActions.options.contains(.forward),
            !isCopyProtected && !message.containsSecretMedia && !isAction && !isEmbeddedMode,
            message.id.namespace == Namespaces.Message.Cloud && message.id.peerId != context.account.peerId {
            let title = chatPresentationInterfaceState.strings.baseLanguageCode.hasPrefix("ru") ? "Сохранить в Избранное" : "Save to Saved Messages"
            actions.append(.action(ContextMenuActionItem(text: title, icon: { theme in
                return generateTintedImage(image: UIImage(systemName: "bookmark"), color: theme.actionSheet.primaryTextColor)
            }, action: { c, _ in
                c?.dismiss(completion: {
                    _ = controllerInteraction.performPersonalChatDoubleTapAction(message, .savedMessages)
                })
            })))
        }

'''


def message_action_patches(patches: SourcePatches) -> None:
    value = patches.read(MENU)
    replacement = ACTION + ANCHOR
    if replacement in value and ANCHOR in value.replace(replacement, ""):
        raise ValueError("Saved Messages action has an ambiguous insertion anchor")
    patches.replace("saveToFavoritesInMenu", MENU, ANCHOR, replacement)


def apply_message_action_patches(root: Path) -> dict[str, list[str]]:
    patches = SourcePatches(root)
    message_action_patches(patches)
    return patches.write()
