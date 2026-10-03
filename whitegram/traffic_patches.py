"""Install the recovered foreground-only decoy scheduler without altering MTProto."""

from pathlib import Path

from source_patches import SourcePatches

TRAFFIC_RUNTIME_FILES = {
    name: "submodules/SettingsUI/Sources/" + name
    for name in (
        "WhitegramTrafficPolicy.swift",
        "WhitegramTrafficManager.swift",
        "WhitegramTrafficController.swift",
    )
}

APP_DELEGATE = "submodules/TelegramUI/Sources/AppDelegate.swift"
STARTUP_ANCHOR = '        Logger.setSharedLogger(Logger(rootPath: rootPath, basePath: logsPath))\n'
STARTUP_REPLACEMENT = STARTUP_ANCHOR + '        whitegramInstallTraffic()\n'


def traffic_patches(patches: SourcePatches) -> None:
    value = patches.read(APP_DELEGATE)
    insertion = '        whitegramInstallTraffic()\n'
    if value.count(STARTUP_ANCHOR) != 1 or value.count(insertion) > 1:
        raise ValueError("Whitegram decoy traffic: ambiguous or missing startup anchor")
    if insertion not in value:
        patches.pending[APP_DELEGATE] = value.replace(STARTUP_ANCHOR, STARTUP_REPLACEMENT)
    patches.features.setdefault("antiCensorshipEnabled", set()).add(APP_DELEGATE)


def apply_traffic_patches(root: Path) -> dict[str, list[str]]:
    patches = SourcePatches(root)
    traffic_patches(patches)
    return patches.write()
