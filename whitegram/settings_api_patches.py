"""Adapt restored settings rows to the APIs present in the target source tree."""

from pathlib import Path

from source_patches import SourcePatches


SETTINGS = "submodules/SettingsUI/Sources/"
SLIDER_FILES = (
    "WhiteGramSettingsController.swift",
    "WhitegramAppearanceSliderItem.swift",
    "WhitegramPhotoQualitySliderItem.swift",
    "WhitegramVoiceSliderItem.swift",
)


def apply_settings_api_patches(root: Path) -> dict[str, list[str]]:
    patches = SourcePatches(root)
    protocol = patches.read("submodules/Display/Source/ListViewItem.swift")
    if "neighbors: ListViewItemNeighbors" in protocol:
        for name in SLIDER_FILES:
            patches.replace(
                "settings-list-item-neighbors", SETTINGS + name,
                "previousItem: ListViewItem?, nextItem: ListViewItem?,",
                "neighbors: ListViewItemNeighbors,", count=2,
            )

    proxy = patches.read("submodules/TelegramCore/Sources/SyncCore/SyncCore_ProxySettings.swift")
    if "case web(" in proxy:
        patches.replace(
            "settings-web-proxy-status",
            SETTINGS + "Data and Storage/ProxyListSettingsController.swift",
            "        case .mtp:\n            text = strings.SocksProxySetup_ProxyTelegram\n    }\n    switch status {",
            "        case .mtp:\n            text = strings.SocksProxySetup_ProxyTelegram\n"
            "        case .web:\n            text = strings.SocksProxySetup_ProxyWeb\n    }\n    switch status {",
        )
    return patches.write()
