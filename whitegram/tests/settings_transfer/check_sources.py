"""Read-only syntax and source-boundary checks. Does not execute Swift or UIKit."""

import argparse
import ast
from importlib.metadata import version
from pathlib import Path
import re
import sys


ROOT = Path(__file__).resolve().parents[2]
HERE = Path(__file__).resolve().parent


def main() -> int:
    args = argparse.ArgumentParser(description=__doc__)
    args.add_argument("--target", type=Path, required=True, help="Read-only assembled Telegram tree")
    options = args.parse_args()
    for package, expected in (("tree-sitter", "0.25.2"), ("tree-sitter-swift", "0.7.3")):
        if version(package) != expected:
            raise SystemExit(f"{package}=={expected} is required")
    from tree_sitter import Language, Parser
    import tree_sitter_swift

    parser = Parser(Language(tree_sitter_swift.language()))
    production = sorted(path for path in (ROOT / "cleanroom").glob("*.swift") if path.name.startswith(("WhitegramSettingsArchive", "WhitegramSettingsTransfer")))
    production += [ROOT / "cleanroom" / "WhitegramPreferences.swift", ROOT / "generated" / "WhitegramSettingsState.swift"]
    tests = sorted(HERE.glob("*Tests.swift"))
    failures = []
    for path in production + tests:
        tree = parser.parse(path.read_bytes())
        pending = [tree.root_node]
        while pending:
            node = pending.pop()
            if node.type == "ERROR" or node.is_missing:
                failures.append(f"{path.name}:{node.start_point.row + 1}: {node.type}")
            pending.extend(node.children)
    for path in HERE.glob("*.py"):
        ast.parse(path.read_text(encoding="utf-8"), filename=str(path))
    texts = {path.name: path.read_text(encoding="utf-8") for path in production}
    combined = "\n".join(texts.values())
    for forbidden in ("dictionaryRepresentation()", "persistentDomain(forName:", "Data(contentsOf:"):
        if forbidden in combined:
            failures.append("Forbidden broad/unbounded input: " + forbidden)
    core = [text for name, text in texts.items() if name.startswith("WhitegramSettingsArchive") and "Keychain" not in name]
    if any("import UIKit" in text or "import TelegramUIPreferences" in text for text in core):
        failures.append("Archive core gained a UI/public-fork dependency")
    state = texts["WhitegramSettingsState.swift"]
    if "public var localStarsCount: Int64 = 9999" not in state:
        failures.append("Recovered localStarsCount Int64 type/default was lost")
    if "public var activeWhitegramAccountId: Int64? = nil" not in state:
        failures.append("Recovered optional account ID type was lost")
    keychain = texts["WhitegramSettingsArchiveKeychain.swift"]
    if "kSecAttrAccessibleWhenUnlockedThisDeviceOnly" not in keychain or "kSecAttrSynchronizable as String: false" not in keychain:
        failures.append("Settings Keychain must be unlocked/device-local/non-synchronizing")
    if "kSecAttrAccessGroup" in keychain:
        failures.append("Settings backup must not select a shared Keychain access group")
    ui = texts["WhitegramSettingsTransferController.swift"]
    if "ItemListController(context: context, state: signal)" not in ui or "import PresentationDataUtils" not in ui:
        failures.append("Settings UI context/state adapter/import missing")
    adapter = options.target / "submodules/PresentationDataUtils/Sources/ItemListController.swift"
    if "context: AccountContext, state: Signal<" not in adapter.read_text(encoding="utf-8"):
        failures.append("Target context/state ItemList API changed")
    pref_source = options.target / "submodules/TelegramUIPreferences/Sources"
    for name in ("WhiteGramChatSettings.swift", "WhiteGramTabSettings.swift", "WhiteGramStorySettings.swift", "WhiteGramChatFolderSettings.swift", "WhiteGramOtherSettings.swift", "WhiteGramContextMenuSettings.swift", "WhitegramForkBridge.swift"):
        if not (pref_source / name).is_file():
            failures.append("Missing actual public-fork test input: " + name)
    count = sum(len(re.findall(r"\bfunc test\w+\s*\(", path.read_text(encoding="utf-8"))) for path in tests)
    for failure in failures:
        print(failure, file=sys.stderr)
    print(f"{len(production)} production Swift files and {len(tests)} test files parsed; {count} XCTest methods supplied.")
    print("Native Swift/XCTest/UIKit execution is not performed by this check.")
    return 1 if failures else 0


if __name__ == "__main__":
    raise SystemExit(main())
