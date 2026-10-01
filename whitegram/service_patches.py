"""Route message indicators to the explicit VirusTotal review screen."""

from pathlib import Path

from source_patches import SourcePatches

MENU = "submodules/TelegramUI/Sources/ChatInterfaceStateContextMenus.swift"
ACTION = '''        if !isAction && !isEmbeddedMode && message.id.peerId.namespace != Namespaces.Peer.SecretChat {
            let whitegramTargets = whitegramVirusTotalTargets(text: message.text, entities: message.textEntitiesAttribute?.entities ?? [])
            if !whitegramTargets.isEmpty {
                actions.append(.action(ContextMenuActionItem(text: "VirusTotal", icon: { theme in
                    return generateTintedImage(image: UIImage(systemName: "checkmark.shield"), color: theme.actionSheet.primaryTextColor)
                }, action: { c, _ in
                    c?.dismiss(completion: {
                        controllerInteraction.navigationController()?.pushViewController(whitegramVirusTotalController(context: context, targets: whitegramTargets))
                    })
                })))
            }
        }

'''


def service_patches(patches: SourcePatches) -> None:
    anchor = "        let isMigrated: Bool\n"
    value = patches.read(MENU)
    replacement = anchor + ACTION
    if replacement in value and anchor in value.replace(replacement, ""):
        raise ValueError("VirusTotal context menu has an ambiguous insertion anchor")
    patches.replace("virusTotalMessageTargets", MENU, anchor, replacement)


def apply_service_patches(root: Path) -> dict[str, list[str]]:
    patches = SourcePatches(root)
    service_patches(patches)
    return patches.write()
