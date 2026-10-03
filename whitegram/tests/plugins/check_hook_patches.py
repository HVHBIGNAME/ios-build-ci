"""Validate hook patches in memory against an assembled source tree. Never writes it."""

import argparse
from importlib.metadata import version
from pathlib import Path
import sys

sys.path.insert(0, str(Path(__file__).resolve().parents[2]))

from history_patches import _capture_patches
from plugin_hook_patches import plugin_hook_patches
from source_patches import SourcePatches


def check(root: Path) -> None:
    from tree_sitter import Language, Parser
    import tree_sitter_swift

    if version("tree-sitter") != "0.25.2" or version("tree-sitter-swift") != "0.7.3":
        raise RuntimeError("Requires tree-sitter 0.25.2 / tree-sitter-swift 0.7.3")
    parser = Parser(Language(tree_sitter_swift.language()))

    patches = SourcePatches(root)
    _capture_patches(patches)
    plugin_hook_patches(patches)
    once = dict(patches.pending)
    _capture_patches(patches)
    plugin_hook_patches(patches)
    assert patches.pending == once, "History + plugin patch composition is not idempotent"
    print("PASS history capture -> hooks -> history capture -> hooks is idempotent")

    reverse = SourcePatches(root)
    plugin_hook_patches(reverse)
    _capture_patches(reverse)
    assert reverse.pending == once, "History capture and hooks are order-dependent"
    print("PASS both history/hook application orders produce identical sources")

    expected = {
        "submodules/TelegramCore/Sources/State/AccountStateManagementUtils.swift": 5,
        "submodules/TelegramCore/Sources/PendingMessages/EnqueueMessage.swift": 2,
        "submodules/TelegramCore/Sources/Network/Network.swift": 4,
        "submodules/TelegramCore/Sources/State/ApplyUpdateMessage.swift": 2,
        "submodules/TelegramCore/Sources/TelegramEngine/Messages/DeleteMessagesInteractively.swift": 1,
        "submodules/TelegramCore/Sources/PendingMessages/RequestEditMessage.swift": 4,
        "submodules/TelegramUI/Sources/ChatController.swift": 3,
        "submodules/TelegramUI/Sources/TelegramRootController.swift": 1,
        "submodules/TelegramUI/Sources/ChatInterfaceStateContextMenus.swift": 2,
    }
    assert set(patches.pending) == set(expected)
    for path, count in expected.items():
        assert sum(patches.pending[path].count(prefix) for prefix in ["WhitegramPluginHooks.", "WhitegramPluginNativeInterception.", "WhitegramPluginContributions.shared.", "whitegramBootstrapPlugins("]) == count, path
        before = parser.parse(patches.original[path].encode())
        after = parser.parse(patches.pending[path].encode())
        # Full Telegram sources can contain grammar constructs unsupported by
        # tree-sitter. Compare error snippets to distinguish those from our edits.
        def errors(tree, text):
            output, stack = [], [tree.root_node]
            data = text.encode()
            while stack:
                node = stack.pop()
                if node.type == "ERROR" or node.is_missing:
                    output.append((node.type, data[node.start_byte:node.end_byte]))
                stack.extend(reversed(node.children))
            return output
        assert errors(after, patches.pending[path]) == errors(before, patches.original[path]), f"New Swift syntax errors: {path}"
        assert (root / path).read_text(encoding="utf-8") == patches.original[path], f"Input tree changed: {path}"
        print(f"PASS {count} hook callsites, syntax, unchanged input: {path}")

    path = "submodules/TelegramCore/Sources/PendingMessages/EnqueueMessage.swift"
    anchor = "        return messageIds\n    } else {\n        return []\n    }\n"
    for broken in [patches.original[path].replace(anchor, ""), patches.original[path] + anchor]:
        invalid = SourcePatches(root)
        invalid.original[path] = patches.original[path]
        invalid.pending[path] = broken
        try:
            plugin_hook_patches(invalid)
        except ValueError as error:
            assert path in str(error)
        else:
            raise AssertionError("A missing/ambiguous enqueue anchor was accepted")
    print("PASS missing and ambiguous anchors reject before any source write")


def main() -> None:
    arguments = argparse.ArgumentParser(description=__doc__)
    arguments.add_argument("source", type=Path)
    check(arguments.parse_args().source.resolve())


if __name__ == "__main__":
    main()
