"""Adapt fork BUILD rules and shared-library dependencies to pinned Bazel."""

import json
import re
from pathlib import Path

from source_patches import SourcePatches


def add_dep(build_path: Path, label: str) -> bool:
    text = build_path.read_text(encoding="utf-8")
    base_label = label.rsplit(":", 1)[0]
    if f'"{label}"' in text or f'"{base_label}"' in text:
        return False
    match = re.search(r"(?m)^(?P<indent>[ \t]*)deps\s*=\s*\[", text)
    if match is None:
        return False
    # Prepending also works when the existing final item has no trailing comma.
    insertion = f'\n{match["indent"]}    "{label}",'
    build_path.write_text(text[:match.end()] + insertion + text[match.end():], encoding="utf-8")
    return True


def apply_build_patches(root: Path) -> dict[str, list[str]]:
    version = json.loads((root / "versions.json").read_text(encoding="utf-8"))["bazel"]
    if not version.startswith("8."):
        raise ValueError(f"Native BUILD rules must be reviewed for Bazel {version}")
    patches = SourcePatches(root)
    for repository, rule, package in (("rules_cc", "objc_library", "cc"), ("rules_shell", "sh_binary", "shell")):
        patches.replace("bazel8-native-rules", "Telegram/BUILD",
            f'load("@{repository}//{package}:{rule}.bzl", "{rule}")',
            f"# {rule} is supplied by the pinned Bazel 8 toolchain.")
    patches.replace("audio-waveform-foundation-only", "submodules/AudioWaveform/BUILD",
        '    deps = [\n    \t"//submodules/AsyncDisplayKit:AsyncDisplayKit",\n\t"//submodules/Display:Display",\n        "//submodules/LegacyComponents:LegacyComponents",\n    ],',
        '    deps = [],')
    patches.replace("opus-shared-framework-exports", "third-party/opus/BUILD", '''cc_library(
    name = "opus_lib",
    srcs = [":Public/opus/lib/lib" + x + ".a" for x in libs],
)''', '''cc_import(
    name = "opus_lib",
    static_library = ":Public/opus/lib/libopus.a",
    # TelegramCore owns Opus; WebRTC in TelegramUI also needs its multistream encoder.
    alwayslink = True,
)''')
    return patches.write()
