#!/usr/bin/env python3
import re
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

print(f"Added {import_count} compatibility import(s) and {build_count} BUILD dependency(ies)")
