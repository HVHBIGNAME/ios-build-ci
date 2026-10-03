"""Exact, idempotent edits: reject missing/ambiguous anchors before writing files."""

import re
from pathlib import Path


class SourcePatches:
    def __init__(self, root: Path):
        self.root = root
        self.original: dict[str, str] = {}
        self.pending: dict[str, str] = {}
        self.features: dict[str, set[str]] = {}

    def read(self, path: str) -> str:
        if path not in self.original:
            self.original[path] = (self.root / path).read_text(encoding="utf-8")
            self.pending[path] = self.original[path]
        return self.pending[path]

    def replace(self, feature: str, path: str, before: str, after: str, count: int = 1, *, accepted_after: tuple[str, ...] = ()):
        value = self.read(path)
        for installed in accepted_after:
            if installed in value:
                normalized = value.replace(installed, after)
                if value.count(installed) != count or normalized.count(after) != count or before in normalized.replace(after, ""):
                    raise ValueError(f"{feature}: {path}: ambiguous upgraded patch")
                self.features.setdefault(feature, set()).add(path)
                return
        if value.count(after) == count:
            self.features.setdefault(feature, set()).add(path)
            return
        found = value.count(before)
        if found != count:
            raise ValueError(f"{feature}: {path}: expected {count} anchors, found {found}: {before[:120]!r}")
        self.pending[path] = value.replace(before, after)
        self.features.setdefault(feature, set()).add(path)

    def guard_requests(self, feature: str, path: str, request: str, condition: str, count: int, *, accepted_conditions: tuple[str, ...] = ()):
        value = self.read(path)
        pattern = re.compile(r"^(?P<indent>[ \t]*)(?P<request>let _ = " + re.escape(request) + r"[^\n]*)$", re.MULTILINE)
        matches = list(pattern.finditer(value))
        if len(matches) != count:
            raise ValueError(f"{feature}: expected {count} requests in {path}, found {len(matches)}")
        for match in reversed(matches):
            indent = match["indent"]
            preceding = value[:match.start()].splitlines()
            if preceding:
                guard = preceding[-1].strip()
                if guard in {f"if {item} {{" for item in (condition, *accepted_conditions)}:
                    continue
                if guard.startswith("if ") and "WhitegramGhost." in guard:
                    raise ValueError(f"{feature}: {path}: unrecognized privacy guard")
            block = f"{indent}if {condition} {{\n{indent}    {match['request']}\n{indent}}}"
            value = value[:match.start()] + block + value[match.end():]
        self.pending[path] = value
        self.features.setdefault(feature, set()).add(path)

    def write(self) -> dict[str, list[str]]:
        for relative, value in self.pending.items():
            if value != self.original[relative]:
                (self.root / relative).write_bytes(value.encode("utf-8"))
        return {feature: sorted(paths) for feature, paths in sorted(self.features.items())}
