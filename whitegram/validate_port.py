#!/usr/bin/env python3
"""Check the assembled source tree and compare Swift parse errors to upstream."""

import argparse
import collections
import json
import subprocess
import threading
from pathlib import Path


def errors(parser, content: bytes) -> list[dict]:
    tree = parser.parse(content)
    pending = [tree.root_node]
    result = []
    while pending:
        node = pending.pop()
        if node.type == "ERROR" or node.is_missing:
            result.append({"line": node.start_point.row + 1, "text": content[node.start_byte:node.end_byte].decode("utf-8", errors="replace")})
        else:
            pending.extend(reversed(node.children))
    return result


def check_sources(source: Path, report: Path) -> int:
    from tree_sitter import Language, Parser
    import tree_sitter_swift

    parser = Parser(Language(tree_sitter_swift.language()))
    changed = subprocess.check_output(["git", "-C", str(source), "diff", "--name-only", "HEAD", "--", "*.swift"], stderr=subprocess.PIPE).decode().splitlines()
    added = subprocess.check_output(["git", "-C", str(source), "ls-files", "--others", "--exclude-standard", "--", "*.swift"]).decode().splitlines()
    findings = {}
    for index, relative in enumerate(sorted(set(changed + added))):
        if index % 20 == 0:
            print(f"Parsing Swift {index + 1}/{len(set(changed + added))}: {relative}", flush=True)
        path = source / relative
        if not path.is_file():
            continue
        content = path.read_bytes().replace(b"\r\n", b"\n")
        if b"<<<<<<< upstream" in content or b">>>>>>> whitegram" in content:
            raise ValueError(f"Unresolved conflict in {relative}")
        new = errors(parser, content)
        base = subprocess.run(["git", "-C", str(source), "show", f"HEAD:{relative}"], capture_output=True, check=False)
        baseline = collections.Counter(entry["text"] for entry in errors(parser, base.stdout)) if base.returncode == 0 else collections.Counter()
        introduced = []
        for entry in new:
            if baseline[entry["text"]]:
                baseline[entry["text"]] -= 1
            else:
                introduced.append(entry)
        if introduced:
            findings[relative] = introduced
    result = {"swift_files_checked": len(set(changed + added)), "new_parser_diagnostics": findings, "note": "Syntax comparison only; Xcode type checking and device tests are separate."}
    report.parent.mkdir(parents=True, exist_ok=True)
    report.write_text(json.dumps(result, indent=2), encoding="utf-8")
    print(f"Swift files checked: {result['swift_files_checked']}")
    for path, entries in findings.items():
        print(f"{path}: {len(entries)} new parser diagnostics at lines {', '.join(str(entry['line']) for entry in entries)}")
    return 1 if findings else 0


if __name__ == "__main__":
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("source", type=Path)
    parser.add_argument("--report", type=Path, required=True)
    args = parser.parse_args()
    # Swift's largest generated functions exceed the default Windows thread stack.
    threading.stack_size(64 * 1024 * 1024)
    status = [1]
    def run():
        status[0] = check_sources(args.source, args.report)
    worker = threading.Thread(target=run)
    worker.start()
    worker.join()
    raise SystemExit(status[0])
