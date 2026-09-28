"""Syntax-only verification; this is not a Swift compiler or an iOS build."""

from pathlib import Path
from importlib.metadata import PackageNotFoundError, version
import sys


def main() -> int:
    for package, expected in {"tree-sitter": "0.25.2", "tree-sitter-swift": "0.7.3"}.items():
        try:
            installed = version(package)
        except PackageNotFoundError:
            installed = "not installed"
        if installed != expected:
            print(f"Requires {package}=={expected}; found {installed}. Refusing an unverified parser/grammar pairing.")
            return 2

    from tree_sitter import Language, Parser
    import tree_sitter_swift

    print("Parser: tree-sitter 0.25.2 / tree-sitter-swift 0.7.3")
    parser = Parser(Language(tree_sitter_swift.language()))
    sources = Path(__file__).resolve().parents[2] / "cleanroom"
    failed = False
    files = sorted(sources.glob("WhitegramPlugin*.swift")) + sorted(Path(__file__).parent.glob("*.swift"))
    for path in files:
        tree = parser.parse(path.read_bytes())
        errors = []
        stack = [tree.root_node]
        while stack:
            node = stack.pop()
            if node.type == "ERROR" or node.is_missing:
                errors.append(f"{node.start_point.row + 1}:{node.start_point.column + 1} {node.type}")
            stack.extend(reversed(node.children))
        if errors:
            failed = True
            print(f"FAIL {path.name}: " + ", ".join(errors))
        else:
            print(f"PASS {path.name}")
    print(f"{len(files)} Swift source files parsed; compilation/device execution not checked.")
    return 1 if failed or not files else 0


if __name__ == "__main__":
    sys.exit(main())
