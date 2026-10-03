#!/usr/bin/env python3
import re
import shutil
import subprocess
import sys
from pathlib import Path

from runtime_patches import apply_runtime_patches
from appearance_patches import APPEARANCE_RUNTIME_FILES, apply_appearance_patches
from appearance_parity_patches import APPEARANCE_PARITY_RUNTIME_FILES, apply_appearance_parity_patches
from appearance_icon_pack_patches import APPEARANCE_ICON_PACK_RUNTIME_FILES, apply_appearance_icon_pack_patches
from appearance_glass_patches import APPEARANCE_GLASS_RUNTIME_FILES, apply_appearance_glass_patches
from appearance_extension_patches import apply_appearance_extensions
from public_api_adaptations import apply_public_api_adaptations
from voice_patches import VOICE_RUNTIME_FILES, VOICE_REQUIRED_DEPENDENCIES, apply_voice_patches
from player_patches import PLAYER_RUNTIME_FILES, apply_player_patches
from plugin_resources import install_plugin_resources
from interface_patches import apply_interface_patches
from history_patches import HISTORY_RUNTIME_FILES, apply_history_patches
from plugin_hook_patches import PLUGIN_HOOK_RUNTIME_FILES, apply_plugin_hook_patches
from translation_patches import TRANSLATION_RUNTIME_FILES, apply_translation_patches
from service_patches import SERVICES_RUNTIME_FILES, apply_service_patches
from media_camera_patches import MEDIA_RUNTIME_FILES, apply_media_camera_patches
from message_actions_patches import apply_message_action_patches
from account_patches import ACCOUNTS_RUNTIME_FILES, ACCOUNTS_REQUIRED_DEPENDENCIES, apply_account_patches
from content_control_patches import PRIVACY_RUNTIME_FILES, apply_content_control_patches
from transfer_patches import TRANSFER_RUNTIME_FILES, apply_transfer_patches
from backend_patches import BACKEND_RUNTIME_FILES, apply_backend_patches
from traffic_patches import TRAFFIC_RUNTIME_FILES, apply_traffic_patches
from swift_syntax_patches import apply_swift_syntax_patches
from build_patches import apply_build_patches

source_root = Path(sys.argv[1]).resolve()
public_root = Path(sys.argv[2]).resolve()
public_ref = "db18308774f863074278feedc4df4507b0fb174e"
public_base = "release-12.6.2"

changed = subprocess.check_output(
    [
        "git",
        "-C",
        str(public_root),
        "diff",
        "--name-only",
        public_base,
        public_ref,
        "--",
        "*.swift",
    ],
    text=True,
).splitlines()


def module_map(root: Path) -> dict[str, str]:
    result: dict[str, str] = {}
    for build in root.rglob("BUILD"):
        if not build.is_file():
            continue
        text = build.read_text(encoding="utf-8", errors="replace")
        relative_build = build.relative_to(root).as_posix()
        package = relative_build.rsplit("/", 1)[0] if "/" in relative_build else ""
        for match in re.finditer(r'module_name\s*=\s*"([^"]+)"', text):
            module = match.group(1)
            before = text[:match.start()]
            names = re.findall(r'name\s*=\s*"([^"]+)"', before)
            target = names[-1] if names else module
            label = f"//{package}:{target}" if package else f"//:{target}"
            result.setdefault(module, label)
    result.setdefault("Postbox", "//submodules/Postbox:Postbox")
    result.setdefault("TelegramUIPreferences", "//submodules/TelegramUIPreferences:TelegramUIPreferences")
    return result


def nearest_build(path: Path) -> Path | None:
    current = path.parent
    while current != source_root and current != current.parent:
        candidate = current / "BUILD"
        if candidate.is_file():
            return candidate
        current = current.parent
    return None


def add_dep(build_path: Path, label: str) -> bool:
    text = build_path.read_text(encoding="utf-8", errors="replace")
    base_label = label.rsplit(":", 1)[0]
    if label in text or f'"{base_label}"' in text:
        return False
    match = re.search(r"deps\s*=\s*\[", text)
    if match is None:
        return False
    open_pos = text.find("[", match.start())
    depth = 0
    close_pos = -1
    for index in range(open_pos, len(text)):
        if text[index] == "[":
            depth += 1
        elif text[index] == "]":
            depth -= 1
            if depth == 0:
                close_pos = index
                break
    if close_pos < 0:
        return False
    insertion = f'        "{label}",\n'
    build_path.write_text(text[:close_pos] + insertion + text[close_pos:], encoding="utf-8")
    return True


def imports(text: str) -> set[str]:
    return {
        line.strip()[len("import "):].strip()
        for line in text.splitlines()
        if line.strip().startswith("import ")
    }


modules = module_map(source_root)
import_count = 0
build_count = 0

for relative in changed:
    public_path = public_root / relative
    target_path = source_root / relative
    if not public_path.exists() or not target_path.exists():
        continue
    public_text = public_path.read_text(encoding="utf-8", errors="replace")
    target_text = target_path.read_text(encoding="utf-8", errors="replace")
    public_modules = imports(public_text) & modules.keys()
    if not public_modules:
        continue
    target_modules = imports(target_text)
    missing = sorted(module for module in public_modules if module not in target_modules)
    if missing:
        lines = target_text.splitlines(keepends=True)
        import_indices = [index for index, line in enumerate(lines) if line.strip().startswith("import ")]
        insert_at = (max(import_indices) + 1) if import_indices else 0
        for module in reversed(missing):
            lines.insert(insert_at, f"import {module}\n")
            import_count += 1
        target_path.write_text("".join(lines), encoding="utf-8")
    build_path = nearest_build(target_path)
    if build_path is None:
        continue
    build_package = build_path.parent.relative_to(source_root).as_posix()
    for module in sorted(public_modules):
        label = modules[module]
        label_package = label[2:].split(":", 1)[0]
        if label_package == build_package:
            continue
        dependency_path = source_root / label_package
        if dependency_path.exists() and add_dep(build_path, label):
            build_count += 1

source_base = Path(__file__).resolve().parent
cleanroom_files = {
    "cleanroom/WhitegramPrivacySettings.swift": "submodules/TelegramUIPreferences/Sources/WhitegramPrivacySettings.swift",
    "cleanroom/WhitegramForkBridge.swift": "submodules/TelegramUIPreferences/Sources/WhitegramForkBridge.swift",
    "cleanroom/WhitegramPrivacySettingsController.swift": "submodules/SettingsUI/Sources/WhitegramPrivacySettingsController.swift",
    "cleanroom/WhitegramAccountsSettingsController.swift": "submodules/SettingsUI/Sources/WhitegramAccountsSettingsController.swift",
    "cleanroom/WhitegramMenuSection.swift": "submodules/SettingsUI/Sources/WhitegramMenuSection.swift",
    "cleanroom/WhitegramMainMenuController.swift": "submodules/SettingsUI/Sources/WhitegramMainMenuController.swift",
    "cleanroom/WhitegramGeneratedSettingsScreen.swift": "submodules/SettingsUI/Sources/WhitegramGeneratedSettingsScreen.swift",
    "cleanroom/WhitegramSettingsPlaceholderController.swift": "submodules/SettingsUI/Sources/WhitegramSettingsPlaceholderController.swift",
    "generated/WhitegramSettingsState.swift": "submodules/TelegramCore/Sources/WhitegramSettingsState.swift",
    "generated/WhitegramSettingsCatalog.swift": "submodules/SettingsUI/Sources/WhitegramSettingsCatalog.swift",
    "generated/WhitegramLocalizationStrings.swift": "submodules/TelegramCore/Sources/WhitegramLocalizationStrings.swift",
    "cleanroom/WhitegramLocalization.swift": "submodules/TelegramCore/Sources/WhitegramLocalization.swift",
    "cleanroom/WhitegramLocalizationPack.swift": "submodules/TelegramCore/Sources/WhitegramLocalizationPack.swift",
    "cleanroom/WhitegramLocalizationStore.swift": "submodules/TelegramCore/Sources/WhitegramLocalizationStore.swift",
    "cleanroom/WhitegramLocalizationController.swift": "submodules/SettingsUI/Sources/WhitegramLocalizationController.swift",
    "cleanroom/WhitegramLocalizationUI.swift": "submodules/SettingsUI/Sources/WhitegramLocalizationUI.swift",
    "cleanroom/WhitegramGhost.swift": "submodules/TelegramCore/Sources/WhitegramGhost.swift",
    "cleanroom/WhitegramPreferences.swift": "submodules/TelegramCore/Sources/WhitegramPreferences.swift",
    "cleanroom/WhitegramFontRegistry.swift": "submodules/Display/Source/WhitegramFontRegistry.swift",
    "cleanroom/WhitegramFontsController.swift": "submodules/SettingsUI/Sources/WhitegramFontsController.swift",
    "cleanroom/WhitegramIconsController.swift": "submodules/SettingsUI/Sources/WhitegramIconsController.swift",
    "cleanroom/WhitegramHistoryStore.swift": "submodules/TelegramCore/Sources/WhitegramHistoryStore.swift",
    "cleanroom/WhitegramHistoryModels.swift": "submodules/TelegramCore/Sources/WhitegramHistoryModels.swift",
    "cleanroom/WhitegramHistoryCapture.swift": "submodules/TelegramCore/Sources/WhitegramHistoryCapture.swift",
    "cleanroom/WhitegramHistoryController.swift": "submodules/SettingsUI/Sources/WhitegramHistoryController.swift",
    "cleanroom/WhitegramHistoryPresentation.swift": "submodules/SettingsUI/Sources/WhitegramHistoryPresentation.swift",
    "cleanroom/WhitegramAppearanceSettings.swift": "submodules/TelegramCore/Sources/Settings/WhitegramAppearanceSettings.swift",
    "cleanroom/WhitegramBubbleAppearance.swift": "submodules/TelegramPresentationData/Sources/WhitegramBubbleAppearance.swift",
    "cleanroom/WhitegramAppearanceController.swift": "submodules/SettingsUI/Sources/WhitegramAppearanceController.swift",
    "cleanroom/WhitegramPortCapabilities.swift": "submodules/SettingsUI/Sources/WhitegramPortCapabilities.swift",
}
cleanroom_files.update({"cleanroom/" + name: destination for name, destination in VOICE_RUNTIME_FILES.items()})
cleanroom_files.update({"cleanroom/" + name: destination for name, destination in PLUGIN_HOOK_RUNTIME_FILES.items()})
cleanroom_files.update({"cleanroom/" + name: destination for name, destination in TRANSLATION_RUNTIME_FILES.items()})
cleanroom_files.update({"cleanroom/" + name: destination for name, destination in MEDIA_RUNTIME_FILES.items()})
for manifest in (
    APPEARANCE_RUNTIME_FILES, APPEARANCE_PARITY_RUNTIME_FILES, APPEARANCE_ICON_PACK_RUNTIME_FILES,
    APPEARANCE_GLASS_RUNTIME_FILES, HISTORY_RUNTIME_FILES, ACCOUNTS_RUNTIME_FILES,
    PRIVACY_RUNTIME_FILES, TRANSFER_RUNTIME_FILES, PLAYER_RUNTIME_FILES, BACKEND_RUNTIME_FILES, TRAFFIC_RUNTIME_FILES,
):
    cleanroom_files.update({"cleanroom/" + name: destination for name, destination in manifest.items()})
for name in (
    "WhitegramSettingsArchive.swift", "WhitegramSettingsArchiveJSON.swift",
    "WhitegramSettingsArchiveSchema.swift", "WhitegramSettingsArchiveMirrors.swift",
    "WhitegramSettingsArchiveStore.swift",
):
    cleanroom_files["cleanroom/" + name] = "submodules/TelegramCore/Sources/" + name
for name in (
    "WhitegramPluginHTTP.swift", "WhitegramPluginManagerController.swift",
    "WhitegramPluginRuntime.swift", "WhitegramPluginStorage.swift",
    "WhitegramPluginTelegram.swift", "WhitegramPluginUI.swift",
    "WhitegramAIService.swift", "WhitegramAISettingsController.swift",
    "WhitegramAIConversation.swift", "WhitegramVirusTotalTargets.swift", "WhitegramVirusTotalMessageContext.swift",
    "WhitegramVirusTotalService.swift", "WhitegramVirusTotalFileHasher.swift",
    "WhitegramVirusTotalController.swift", "WhitegramServiceCore.swift",
    "WhitegramServiceHTTP.swift", "WhitegramServiceCredentials.swift", "WhitegramServiceUI.swift",
    "WhitegramSettingsArchiveKeychain.swift", "WhitegramSettingsTransferController.swift",
    "WhitegramSettingsTransferDocuments.swift",
):
    cleanroom_files["cleanroom/" + name] = "submodules/SettingsUI/Sources/Whitegram/" + name
for name in SERVICES_RUNTIME_FILES:
    cleanroom_files["cleanroom/" + name] = "submodules/SettingsUI/Sources/Whitegram/" + name
missing = [name for name in cleanroom_files if not (source_base / name).is_file()]
if missing:
    raise SystemExit("Missing clean-room sources: " + ", ".join(sorted(missing)))

# The CI filesystem is case-insensitive, so a target name that differs from an
# existing file only by case silently overwrites it. That once destroyed the
# fork's whiteGramSettingsController, so refuse to allow it.
for target_name in cleanroom_files.values():
    target = source_root / target_name
    if not target.parent.is_dir():
        continue
    lowered = target.name.lower()
    for existing in target.parent.iterdir():
        if existing.name.lower() == lowered and existing.name != target.name:
            raise SystemExit(
                "Case-insensitive collision: {} would overwrite {}".format(
                    target_name, existing.name
                )
            )
for source_name, target_name in cleanroom_files.items():
    source_path = source_base / source_name
    target_path = source_root / target_name
    target_path.parent.mkdir(parents=True, exist_ok=True)
    shutil.copy2(source_path, target_path)

if add_dep(source_root / "submodules/SettingsUI/BUILD", "//submodules/Camera:Camera"):
    build_count += 1


def patch_file(relative_path, anchor, replacement):
    """Insert `replacement` in place of `anchor`, refusing to guess."""
    path = source_root / relative_path
    if not path.is_file():
        raise SystemExit("Patch target missing: " + relative_path)
    text = path.read_bytes().decode("utf-8")
    newline = "\r\n" if "\r\n" in text else "\n"
    anchor = anchor.replace("\n", newline)
    replacement = replacement.replace("\n", newline)
    if replacement in text:
        print("  already patched: " + relative_path)
        return
    found = text.count(anchor)
    if found != 1:
        raise SystemExit(
            "Patch anchor matched {} times in {}: {!r}".format(
                found, relative_path, anchor[:80]
            )
        )
    path.write_bytes(text.replace(anchor, replacement).encode("utf-8"))
    print("  patched: " + relative_path)


patched_sources = set(cleanroom_files.values()) | set(changed)
for patcher in (
    apply_runtime_patches, apply_build_patches, apply_public_api_adaptations,
    apply_appearance_patches, apply_interface_patches, apply_history_patches,
    apply_account_patches, apply_plugin_hook_patches, apply_appearance_extensions,
    apply_appearance_parity_patches, apply_appearance_icon_pack_patches, apply_appearance_glass_patches,
    apply_translation_patches, apply_service_patches, apply_media_camera_patches,
    apply_transfer_patches, apply_message_action_patches, apply_content_control_patches,
    apply_player_patches, apply_swift_syntax_patches, apply_voice_patches,
    apply_backend_patches, apply_traffic_patches,
):
    report = patcher(source_root)
    if isinstance(report, dict):
        for paths in report.values():
            patched_sources.update(paths)

for relative in sorted(patched_sources):
    source = source_root / relative
    if source.suffix != ".swift" or not source.is_file():
        continue
    build = nearest_build(source)
    if build is None:
        raise SystemExit("Missing BUILD for installed source: " + relative)
    package = build.parent.relative_to(source_root).as_posix()
    for module in sorted(imports(source.read_text(encoding="utf-8")) & modules.keys()):
        label = modules[module]
        if label[2:].split(":", 1)[0] != package and add_dep(build, label):
            build_count += 1
for relative, dependencies in ACCOUNTS_REQUIRED_DEPENDENCIES.items():
    for label in dependencies:
        if add_dep(source_root / relative, label):
            build_count += 1
for module, dependencies in VOICE_REQUIRED_DEPENDENCIES.items():
    for label in dependencies:
        if add_dep(source_root / "submodules" / module / "BUILD", label):
            build_count += 1
install_plugin_resources(source_root, source_base)
patch_file(
    "submodules/TelegramUI/Components/PeerInfo/PeerInfoScreen/Sources/PeerInfoScreenSettingsActions.swift",
    "whiteGramSettingsController(context:",
    "whitegramMainMenuController(context:",
)

settings_path = source_root / "submodules/SettingsUI/Sources/WhiteGramSettingsController.swift"
if settings_path.exists():
    text = settings_path.read_text(encoding="utf-8", errors="replace")
    changed = False
    if "case privacy" not in text:
        text = text.replace("    case contextMenu\n    case other\n", "    case contextMenu\n    case privacy\n    case other\n", 1)
        text = text.replace("        case .other:\n            return whiteGramString(strings, ru: \"Другие\", en: \"Other\")", "        case .privacy:\n            return whiteGramString(strings, ru: \"Приватность\", en: \"Privacy\")\n        case .other:\n            return whiteGramString(strings, ru: \"Другие\", en: \"Other\")", 1)
        text = text.replace("        case .other:\n            return PresentationResourcesSettings.settings", "        case .privacy:\n            return PresentationResourcesSettings.settings\n        case .other:\n            return PresentationResourcesSettings.settings", 1)
        text = text.replace("            case .other:\n                pushController?(whiteGramOtherSettingsController(context: context))", "            case .privacy:\n                pushController?(whitegramPrivacySettingsController(context: context))\n            case .other:\n                pushController?(whiteGramOtherSettingsController(context: context))", 1)
        changed = True
    if "case accounts" not in text:
        text = text.replace("    case tabs\n", "    case tabs\n    case accounts\n", 1)
        text = text.replace("        case .privacy:\n", "        case .accounts:\n            return whiteGramString(strings, ru: \"Аккаунты\", en: \"Accounts\")\n        case .privacy:\n", 1)
        text = text.replace("        case .privacy:\n            return PresentationResourcesSettings.settings\n", "        case .accounts:\n            return PresentationResourcesSettings.settings\n        case .privacy:\n            return PresentationResourcesSettings.settings\n", 1)
        text = text.replace("            case .privacy:\n", "            case .accounts:\n                pushController?(whitegramAccountsSettingsController(context: context))\n            case .privacy:\n", 1)
        changed = True
    if "case whitegramMain" not in text:
        text = text.replace("    case tabs\n", "    case whitegramMain\n    case tabs\n", 1)
        text = text.replace("        case .privacy:\n", "        case .whitegramMain:\n            return whiteGramString(strings, ru: \"Whitegram\", en: \"Whitegram\")\n        case .privacy:\n", 1)
        text = text.replace("        case .privacy:\n            return PresentationResourcesSettings.settings\n", "        case .whitegramMain:\n            return PresentationResourcesSettings.settings\n        case .privacy:\n            return PresentationResourcesSettings.settings\n", 1)
        text = text.replace("            case .privacy:\n", "            case .whitegramMain:\n                pushController?(whitegramMainMenuController(context: context))\n            case .privacy:\n", 1)
        changed = True
    if changed:
        settings_path.write_text(text, encoding="utf-8")

for name in ("whiteGramStorySettingsController", "whiteGramTabsSettingsController", "whiteGramChatSettingsController", "whiteGramChatFoldersSettingsController"):
    patch_file("submodules/SettingsUI/Sources/WhiteGramSettingsController.swift", f"private func {name}(", f"public func {name}(")
patch_file(
    "submodules/SettingsUI/Sources/WhiteGramSettingsController.swift",
    "            case .media:\n                break",
    "            case .media:\n                pushController?(whiteGramOtherSettingsController(context: context))",
)

patch_file(
    "submodules/TelegramUI/Components/Chat/ChatTextInputPanelNode/Sources/ChatTextInputPanelNode.swift",
    "            guard let self, let presentationInterfaceState = self.presentationInterfaceState, let (width, leftInset, rightInset, bottomInset, additionalSideInsets, maxHeight, maxOverlayHeight, metrics, isSecondary, isMediaInputExpanded) = self.validLayout else {\n"
    "                return\n"
    "            }\n"
    "            let _ = self.updateLayout(width: width, leftInset: leftInset, rightInset: rightInset, bottomInset: bottomInset, additionalSideInsets: additionalSideInsets, maxHeight: maxHeight, maxOverlayHeight: maxOverlayHeight, isSecondary: isSecondary, transition: .animated(duration: 0.25, curve: .easeInOut), interfaceState: presentationInterfaceState, metrics: metrics, isMediaInputExpanded: isMediaInputExpanded)",
    "            self?.requestLayout(transition: .animated(duration: 0.25, curve: .easeInOut))",
)

print(f"Added {import_count} compatibility import(s) and {build_count} BUILD dependency(ies)")
