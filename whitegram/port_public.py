#!/usr/bin/env python3
"""Three-way port of the pinned WhiteGram delta, with reviewed conflict patches."""

import argparse
import difflib
import hashlib
import json
import re
import subprocess
import tempfile
from pathlib import Path

from public_resolutions import resolve

PUBLIC_REF = "db18308774f863074278feedc4df4507b0fb174e"
BASE_REF = "release-12.6.2"


def git(root: Path, *args: str) -> bytes:
    return subprocess.check_output(["git", "-C", str(root), *args])


def blob(root: Path, ref: str, path: str) -> bytes | None:
    result = subprocess.run(
        ["git", "-C", str(root), "show", f"{ref}:{path}"],
        capture_output=True,
        check=False,
    )
    if result.returncode:
        if b"does not exist" in result.stderr or b"exists on disk, but not in" in result.stderr:
            return None
        raise RuntimeError(result.stderr.decode("utf-8", errors="replace"))
    return result.stdout


def text(data: bytes) -> str:
    return data.decode("utf-8").replace("\r\n", "\n")


def normalize_indentation(base: str, changed: str) -> str:
    before, after = base.splitlines(keepends=True), changed.splitlines(keepends=True)
    matcher = difflib.SequenceMatcher(
        None, [line.lstrip() for line in before], [line.lstrip() for line in after], autojunk=False
    )
    result = []
    for operation, a, b, c, d in matcher.get_opcodes():
        result.extend(before[a:b] if operation == "equal" else after[c:d])
    return "".join(result)


def merge(current: str, base: str, public: str) -> tuple[str, bool]:
    with tempfile.TemporaryDirectory(prefix="whitegram-merge-") as directory:
        paths = [Path(directory) / name for name in ("upstream", "base", "whitegram")]
        for path, value in zip(paths, (current, base, public)):
            path.write_bytes(value.encode("utf-8"))
        result = subprocess.run(
            ["git", "merge-file", "--diff3", "-p", "-L", "upstream", "-L", "base", "-L", "whitegram", *map(str, paths)],
            capture_output=True,
            check=False,
        )
        if result.returncode < 0 or result.returncode > 127:
            raise RuntimeError(result.stderr.decode("utf-8", errors="replace"))
        return result.stdout.decode("utf-8"), result.returncode == 0


def apply_reviewed_patch(current: str, patch: str) -> str:
    original = current.splitlines(keepends=True)
    result = []
    cursor = 0
    lines = patch.splitlines(keepends=True)
    index = 0
    while index < len(lines):
        header = re.match(r"@@ -(\d+)(?:,(\d+))? \+(\d+)(?:,(\d+))? @@", lines[index])
        if not header:
            index += 1
            continue
        count = int(header.group(2) or 1)
        start = int(header.group(1)) - (1 if count else 0)
        if start < cursor:
            raise ValueError("Overlapping resolution hunks")
        result.extend(original[cursor:start])
        before, after = [], []
        index += 1
        while index < len(lines) and not lines[index].startswith("@@ "):
            line = lines[index]
            if line.startswith(" "):
                before.append(line[1:])
                after.append(line[1:])
            elif line.startswith("-"):
                before.append(line[1:])
            elif line.startswith("+"):
                after.append(line[1:])
            else:
                raise ValueError(f"Unsupported resolution line: {line!r}")
            index += 1
        if len(before) != count or original[start:start + count] != before:
            raise ValueError(f"Resolution no longer matches upstream at line {start + 1}")
        if len(after) != int(header.group(4) or 1):
            raise ValueError("Invalid resolution new-line count")
        result.extend(after)
        cursor = start + count
    if cursor == 0:
        raise ValueError("Empty resolution patch")
    result.extend(original[cursor:])
    return "".join(result)


def runtime_path(path: str) -> bool:
    if not path.startswith(("Telegram/", "submodules/")):
        return False
    return not path.endswith(".xcconfig")


def conflict_review(relative: str, merged: str) -> str:
    sections = [f"## {relative}\n"]
    pattern = re.compile(r"^<<<<<<< upstream\n(.*?)^\|\|\|\|\|\|\| base\n(.*?)^=======\n(.*?)^>>>>>>> whitegram\n", re.MULTILINE | re.DOTALL)
    for index, match in enumerate(pattern.finditer(merged), 1):
        ours, base, theirs = match.groups()
        sections.append(f"### Conflict {index}\n")
        for name, value in (("upstream", ours), ("whitegram", theirs)):
            diff = "".join(difflib.unified_diff(base.splitlines(keepends=True), value.splitlines(keepends=True), fromfile="base", tofile=name, n=2))
            # Entire deleted helpers are identified by their signature; their fork
            # delta is printed separately rather than duplicating thousands of lines.
            if name == "upstream" and not value.strip() and len(base.splitlines()) > 80:
                diff = "Removed/moved block, " + str(len(base.splitlines())) + " lines:\n" + "".join(base.splitlines(keepends=True)[:12])
            sections.append(f"```diff\n{diff}```\n")
    return "\n".join(sections)


def port(source: Path, public: Path, report: Path, resolutions: Path, apply: bool) -> int:
    changed = git(public, "diff", "--name-only", "-z", BASE_REF, PUBLIC_REF).decode().split("\0")
    entries = []
    pending: dict[Path, bytes | None] = {}
    failed = []
    review = []
    for index, relative in enumerate(filter(None, changed), 1):
        if index % 50 == 1:
            print(f"Porting file {index}/{len(changed) - 1}: {relative}", flush=True)
        if not runtime_path(relative):
            entries.append({"path": relative, "status": "build-metadata", "reason": "Target toolchain/signing is configured separately"})
            continue
        path = source / relative
        base, incoming = blob(public, BASE_REF, relative), blob(public, PUBLIC_REF, relative)
        current = path.read_bytes() if path.is_file() else None
        entry = {"path": relative}
        resolution = resolutions / (relative + ".patch")
        if resolution.is_file():
            if current is None:
                raise ValueError(f"Resolution target missing: {relative}")
            upstream = blob(source, "HEAD", relative)
            if upstream is None:
                raise ValueError(f"Resolution has no upstream base: {relative}")
            resolved = apply_reviewed_patch(text(upstream), resolution.read_text(encoding="utf-8"))
            if text(current) not in (text(upstream), resolved):
                raise ValueError(f"Local edits would be overwritten: {relative}")
            pending[path] = resolved.encode("utf-8")
            entry["status"] = "reviewed-resolution"
        elif current == incoming:
            entry["status"] = "already-present"
        elif current == base:
            pending[path] = incoming
            entry["status"] = "added" if base is None else "ported"
        elif relative == "submodules/TranslateUI/Sources/TranslateButtonComponent.swift" and current is None and incoming is not None:
            pending[path] = incoming
            entry["status"] = "restored-translation-component"
        elif base is None or current is None or incoming is None:
            entry["status"] = "conflict"
        elif b"\0" in base + incoming + current:
            entry["status"] = "conflict"
        else:
            try:
                old, new, ours = text(base), text(incoming), text(current)
            except UnicodeDecodeError:
                entry["status"] = "conflict"
            else:
                merged, clean = merge(ours, old, new)
                if not clean and relative.endswith((".swift", ".m")):
                    merged, clean = merge(ours, old, normalize_indentation(old, new))
                if not clean:
                    review.append(conflict_review(relative, merged))
                    merged = resolve(relative, merged)
                    clean = True
                    entry["status"] = "reviewed-resolution"
                if clean:
                    pending[path] = merged.encode("utf-8")
                    entry.setdefault("status", "merged")
                else:
                    conflict = report.parent / "conflicts" / (relative + ".merge")
                    conflict.parent.mkdir(parents=True, exist_ok=True)
                    conflict.write_bytes(merged.encode("utf-8"))
                    review.append(conflict_review(relative, merged))
                    entry["status"] = "conflict"
                    entry["review_file"] = str(conflict)
        if entry["status"] == "conflict":
            failed.append(relative)
        value = pending.get(path, current)
        if value is not None:
            entry["sha256"] = hashlib.sha256(value).hexdigest()
        entries.append(entry)
    report.parent.mkdir(parents=True, exist_ok=True)
    report.write_text(json.dumps({"public_ref": PUBLIC_REF, "base_ref": BASE_REF, "target": git(source, "rev-parse", "HEAD").decode().strip(), "files": entries, "conflicts": failed}, indent=2), encoding="utf-8")
    (report.parent / "REVIEW.md").write_text("\n".join(review), encoding="utf-8")
    for status in sorted({entry["status"] for entry in entries}):
        print(f"{status}: {sum(entry['status'] == status for entry in entries)}")
    if failed:
        print("Unresolved files:\n" + "\n".join(failed))
        return 1
    if apply:
        for path, value in pending.items():
            if value is None:
                path.unlink()
            else:
                path.parent.mkdir(parents=True, exist_ok=True)
                path.write_bytes(value)
        print(f"Applied {len(pending)} files; no rejected hunks discarded")
    return 0


def main() -> int:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("source", type=Path)
    parser.add_argument("public", type=Path)
    parser.add_argument("--report", type=Path, required=True)
    parser.add_argument("--resolutions", type=Path, default=Path(__file__).parent / "patches" / "public-12.9.2")
    parser.add_argument("--apply", action="store_true")
    args = parser.parse_args()
    return port(args.source.resolve(), args.public.resolve(), args.report.resolve(), args.resolutions.resolve(), args.apply)


if __name__ == "__main__":
    raise SystemExit(main())
