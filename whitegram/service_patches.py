"""Install service workflows and route selected messages to explicit review screens."""

from pathlib import Path

from source_patches import SourcePatches

MENU = "submodules/TelegramUI/Sources/ChatInterfaceStateContextMenus.swift"
SERVICES_RUNTIME_FILES = {
    name: "submodules/SettingsUI/Sources/" + name
    for name in (
        "WhitegramServiceCore.swift", "WhitegramServiceHTTP.swift", "WhitegramServiceCredentials.swift", "WhitegramServiceProxy.swift",
        "WhitegramServiceUI.swift", "WhitegramAIService.swift", "WhitegramAIStreaming.swift", "WhitegramAIModels.swift", "WhitegramAIConversation.swift",
        "WhitegramAILegacyHistory.swift", "WhitegramAISettingsController.swift", "WhitegramVirusTotalService.swift",
        "WhitegramVirusTotalTargets.swift", "WhitegramVirusTotalMessageContext.swift", "WhitegramVirusTotalFileHasher.swift",
        "WhitegramVirusTotalUpload.swift", "WhitegramVirusTotalScan.swift", "WhitegramVirusTotalController.swift",
    )
}
LEGACY_ACTION = '''        if !isAction && !isEmbeddedMode && message.id.peerId.namespace != Namespaces.Peer.SecretChat {
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
ACTION = LEGACY_ACTION.replace(
    "if !isAction && !isEmbeddedMode",
    'if WhitegramPreferences.bool("virusTotalEnabled") && !isAction && !isEmbeddedMode',
).replace(
    "            if !whitegramTargets.isEmpty {",
    "            let whitegramHasFile = message.media.contains(where: { $0 is TelegramMediaFile })\n"
    "            if whitegramHasFile || !whitegramTargets.isEmpty {",
).replace(
    "                        controllerInteraction.navigationController()?.pushViewController(whitegramVirusTotalController(context: context, targets: whitegramTargets))",
    "                        let screen = whitegramHasFile\n"
    "                            ? whitegramVirusTotalController(context: context, message: EngineMessage(message))\n"
    "                            : whitegramVirusTotalController(context: context, targets: whitegramTargets)\n"
    "                        controllerInteraction.navigationController()?.pushViewController(screen)",
)


def service_patches(patches: SourcePatches) -> None:
    anchor = "        let isMigrated: Bool\n"
    value = patches.read(MENU)
    if LEGACY_ACTION in value:
        if value.count(LEGACY_ACTION) != 1 or ACTION in value:
            raise ValueError("VirusTotal context menu has duplicate legacy actions")
        patches.replace("virusTotalMessageTargets", MENU, LEGACY_ACTION, ACTION)
        value = patches.read(MENU)
    replacement = anchor + ACTION
    if ACTION in value and (value.count(ACTION) != 1 or replacement not in value):
        raise ValueError("VirusTotal context menu has an unanchored or duplicate action")
    if value.count(replacement) > 1 or replacement in value and anchor in value.replace(replacement, ""):
        raise ValueError("VirusTotal context menu has an ambiguous insertion anchor")
    patches.replace("virusTotalMessageTargets", MENU, anchor, replacement)


def apply_service_patches(root: Path) -> dict[str, list[str]]:
    patches = SourcePatches(root)
    service_patches(patches)
    return patches.write()
