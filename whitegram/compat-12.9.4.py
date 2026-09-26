#!/usr/bin/env python3
import re
import shutil
import subprocess
import sys
from pathlib import Path

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

cleanroom_root = Path(__file__).resolve().parent / "cleanroom"
cleanroom_files = {
    "WhitegramPrivacySettings.swift": "submodules/TelegramUIPreferences/Sources/WhitegramPrivacySettings.swift",
    "WhitegramPrivacySettingsController.swift": "submodules/SettingsUI/Sources/WhitegramPrivacySettingsController.swift",
    "WhitegramAccountsSettingsController.swift": "submodules/SettingsUI/Sources/WhitegramAccountsSettingsController.swift",
    "WhitegramMenuSection.swift": "submodules/SettingsUI/Sources/WhitegramMenuSection.swift",
    "WhitegramMainMenuController.swift": "submodules/SettingsUI/Sources/WhitegramMainMenuController.swift",
}
for source_name, target_name in cleanroom_files.items():
    source_path = cleanroom_root / source_name
    target_path = source_root / target_name
    if source_path.exists():
        target_path.parent.mkdir(parents=True, exist_ok=True)
        shutil.copy2(source_path, target_path)

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

restore_paths = (
    "submodules/TelegramUI/Sources/Chat/ChatControllerLoadDisplayNode.swift",
    "submodules/TelegramUI/Sources/ChatController.swift",
)
restored_count = 0
for relative in restore_paths:
    result = subprocess.run(
        ["git", "-C", str(source_root), "show", f"HEAD:{relative}"],
        stdout=subprocess.PIPE,
        stderr=subprocess.DEVNULL,
        check=False,
    )
    if result.returncode == 0:
        (source_root / relative).write_bytes(result.stdout)
        restored_count += 1

compat_file = source_root / "submodules/TelegramUI/Components/TabBarComponent/Sources/WhiteGramTabBarCompatibility.swift"
if not compat_file.exists():
    compat_file.parent.mkdir(parents=True, exist_ok=True)
    compat_file.write_text(
        """import UIKit
import TelegramPresentationData

extension TabBarComponent {
    public convenience init(
        theme: PresentationTheme,
        tintSelectedItem: Bool = true,
        isLiftedStateEnabled: Bool = true,
        strings: PresentationStrings,
        items: [Item],
        search: Search?,
        selectedId: AnyHashable?,
        outerInsets: UIEdgeInsets,
        hideItemTitles: Bool,
        forceFullWidth: Bool,
        compactPanel: Bool,
        compactAction: ((UIView) -> Void)?
    ) {
        self.init(
            theme: theme,
            tintSelectedItem: tintSelectedItem,
            isLiftedStateEnabled: isLiftedStateEnabled,
            strings: strings,
            items: items,
            search: search,
            selectedId: selectedId,
            outerInsets: outerInsets
        )
    }
}
""",
        encoding="utf-8",
    )

print(f"Added {import_count} compatibility import(s) and {build_count} BUILD dependency(ies); restored {restored_count} incompatible file(s)")
