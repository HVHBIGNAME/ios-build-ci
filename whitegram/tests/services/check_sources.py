"""Offline Swift syntax and integration-contract checks; not a Swift type checker."""

import argparse
import ast
from pathlib import Path
import re
import sys

from tree_sitter import Language, Parser
import tree_sitter_swift


ROOT = Path(__file__).resolve().parents[2]
SOURCE = ROOT / "cleanroom"
PREFIXES = ("WhitegramAI", "WhitegramVirusTotal", "WhitegramService")


def sources():
    return sorted(path for path in SOURCE.glob("*.swift") if path.name.startswith(PREFIXES))


def syntax(parser, path):
    tree = parser.parse(path.read_bytes())
    failures = []
    stack = [tree.root_node]
    while stack:
        node = stack.pop()
        if node.type == "ERROR" or node.is_missing:
            failures.append(f"{path.name}:{node.start_point.row + 1}:{node.start_point.column + 1}: {node.type}")
        stack.extend(reversed(node.children))
    return failures


def contracts(files, target):
    text = {path.name: path.read_text(encoding="utf-8") for path in files}
    failures = []

    def check(condition, description):
        if not condition:
            failures.append(description)

    combined = "\n".join(text.values())
    for endpoint in (
        "https://generativelanguage.googleapis.com/v1beta/models/",
        "https://api.groq.com/openai/v1/chat/completions",
        "https://www.virustotal.com/api/v3/",
    ):
        check(endpoint in combined, f"Missing official endpoint: {endpoint}")
    check(not re.search(r"\b(?:print|NSLog|os_log|debugPrint|dump)\s*\(", combined), "Service code must not log credentials, prompts, or responses")
    check("connectionProxyDictionary" not in combined, "Services must use system-configured networking")
    for resource in ('"files/"', '"urls/"', '"ip_addresses/"'):
        check(resource in text["WhitegramVirusTotalTargets.swift"], "Missing VirusTotal target route: " + resource)
    check("Data(contentsOf:" not in text["WhitegramVirusTotalFileHasher.swift"], "Hashing must not load an entire file into memory")
    check("read(upToCount: WhitegramServiceLimits.fileChunkBytes)" in combined, "Hashing must read bounded chunks")
    check("field.isSecureTextEntry = secure" in combined and combined.count("secure: true") == 2, "Both API key editors must be masked")
    check("kSecAttrAccessibleWhenUnlockedThisDeviceOnly" in combined and "kSecAttrSynchronizable as String: false" in combined, "Keychain credentials must be device-local and available only when unlocked")
    check("completionHandler(nil)" in text["WhitegramServiceHTTP.swift"], "Credentialed requests must refuse redirects")
    check("urlCredentialStorage = nil" in combined and "httpCookieStorage = nil" in combined and "urlCache = nil" in combined, "Requests must not reuse persistent auth, cookie, or cache storage")
    for entry in ("whitegramAISettingsController", "whitegramVirusTotalController"):
        check(f"public func {entry}(context: AccountContext) -> ViewController" in combined, f"Missing integration entrypoint: {entry}")
    if target:
        ui = target / "submodules" / "ItemListUI" / "Sources"
        node = (ui / "ItemListControllerNode.swift").read_text(encoding="utf-8")
        controller = (ui / "ItemListController.swift").read_text(encoding="utf-8")
        check("func item(presentationData: ItemListPresentationData, arguments: Any)" in node, "Target ItemListNodeEntry signature changed")
        check("public var didAppear:" in controller and "public var didDisappear:" in controller, "Target controller lifecycle hooks changed")
        for item in ("Action", "Disclosure", "Switch"):
            source = (ui / "Items" / f"ItemList{item}Item.swift").read_text(encoding="utf-8")
            check("systemStyle: ItemListSystemStyle" in source, f"Target ItemList{item}Item lacks systemStyle")
        check("ItemListController(context: context, state: signal)" in text["WhitegramServiceUI.swift"], "Service controller must use the target state-signal API")
        adapter = (target / "submodules" / "PresentationDataUtils" / "Sources" / "ItemListController.swift").read_text(encoding="utf-8")
        check("context: AccountContext, state: Signal<" in adapter, "Target context/state convenience initializer changed")
        check("import PresentationDataUtils" in text["WhitegramServiceUI.swift"], "The context/state convenience initializer requires PresentationDataUtils")
    return failures


def main():
    args = argparse.ArgumentParser(description=__doc__)
    args.add_argument("--target", type=Path, help="Read-only assembled Telegram source tree")
    options = args.parse_args()
    parser = Parser(Language(tree_sitter_swift.language()))
    files = sources()
    tests = sorted(Path(__file__).parent.glob("*Tests.swift"))
    failures = []
    for path in files + tests:
        errors = syntax(parser, path)
        failures.extend(errors)
        print(("FAIL " if errors else "PASS ") + path.name)
    for path in sorted(Path(__file__).parent.glob("*.py")):
        ast.parse(path.read_text(encoding="utf-8"), filename=str(path))
    failures.extend(contracts(files, options.target))
    for failure in failures:
        print(failure, file=sys.stderr)
    print(f"{len(files)} production and {len(tests)} test Swift files parsed; offline source contracts checked.")
    test_count = sum(len(re.findall(r"\bfunc test\w+\s*\(", path.read_text(encoding="utf-8"))) for path in tests)
    print(f"{test_count} XCTest methods are provided (not executed by this syntax check).")
    print("Swift type checking, XCTest execution, and iOS UI execution are separate checks.")
    return 1 if failures or not files else 0


if __name__ == "__main__":
    sys.exit(main())
