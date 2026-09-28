"""Adapt fork BUILD imports to the pinned Telegram Bazel toolchain."""

import json
from pathlib import Path

from source_patches import SourcePatches


def apply_build_patches(root: Path) -> dict[str, list[str]]:
    version = json.loads((root / "versions.json").read_text(encoding="utf-8"))["bazel"]
    if not version.startswith("8."):
        raise ValueError(f"Native BUILD rules must be reviewed for Bazel {version}")
    patches = SourcePatches(root)
    for repository, rule, package in (("rules_cc", "objc_library", "cc"), ("rules_shell", "sh_binary", "shell")):
        patches.replace("bazel8-native-rules", "Telegram/BUILD",
            f'load("@{repository}//{package}:{rule}.bzl", "{rule}")',
            f"# {rule} is supplied by the pinned Bazel 8 toolchain.")
    return patches.write()
