"""Exercise the installer's actual patch order without writing the reference tree."""

import ast
from contextlib import ExitStack
import difflib
import importlib
import json
import os
from pathlib import Path
import sys
import unittest
from unittest.mock import patch

from tree_sitter import Language, Parser
import tree_sitter_swift


OVERLAY = Path(__file__).resolve().parents[1]
sys.path.insert(0, str(OVERLAY))
from source_patches import SourcePatches


def installer_configuration():
    source = OVERLAY / "compat-12.9.4.py"
    module = ast.parse(source.read_text(encoding="utf-8"))
    namespace = {}
    for node in module.body:
        if isinstance(node, ast.ImportFrom):
            imported = importlib.import_module(node.module)
            for name in node.names:
                namespace[name.asname or name.name] = getattr(imported, name.name)
    def assigns(node, name):
        return isinstance(node, ast.Assign) and any(isinstance(target, ast.Name) and target.id == name for target in node.targets)
    start = next(index for index, node in enumerate(module.body) if assigns(node, "cleanroom_files"))
    end = next(index for index, node in enumerate(module.body[start:], start) if assigns(node, "missing"))
    manifest = ast.Module(body=module.body[start:end], type_ignores=[])
    exec(compile(manifest, str(source), "exec"), namespace)
    loop = next(node for node in module.body if isinstance(node, ast.For) and isinstance(node.target, ast.Name) and node.target.id == "patcher")
    patchers = [namespace[node.id] for node in loop.iter.elts]
    return namespace["cleanroom_files"], patchers


def stage(patchers, staged, *, replay_each=False):
    def report():
        return {name: sorted(paths) for name, paths in staged.features.items()}
    def capture_report(path, contents, *args, **kwargs):
        if path != staged.root / "whitegram-runtime-report.json":
            raise AssertionError("Unexpected reference write: " + str(path))
        if json.loads(contents) != report():
            raise AssertionError("Runtime report differs from staged features")
        return len(contents)
    with ExitStack() as guards:
        for name in {function.__module__ for function in patchers}:
            guards.enter_context(patch.object(sys.modules[name], "SourcePatches", return_value=staged))
        guards.enter_context(patch.object(staged, "write", side_effect=report))
        guards.enter_context(patch.object(Path, "write_text", autospec=True, side_effect=capture_report))
        for method in ("write_bytes", "unlink", "mkdir"):
            guards.enter_context(patch.object(Path, method, side_effect=AssertionError("Reference mutation attempted")))
        for function in patchers:
            function(staged.root)
            if replay_each:
                first = dict(staged.pending)
                function(staged.root)
                if first != staged.pending:
                    raise AssertionError("Non-idempotent stage: " + function.__name__)


class RuntimeInstallationTests(unittest.TestCase):
    def test_every_runtime_source_is_installed_once_and_destinations_are_unambiguous(self):
        manifest, _ = installer_configuration()
        runtime = {path.relative_to(OVERLAY).as_posix() for path in (OVERLAY / "cleanroom").glob("*.swift")}
        self.assertEqual(runtime - manifest.keys(), set(), "New runtime files must be integrated before shipping")
        self.assertEqual(len(manifest.values()), len({value.lower() for value in manifest.values()}))
        for source, destination in manifest.items():
            with self.subTest(source=source):
                self.assertTrue((OVERLAY / source).is_file())
                self.assertTrue(destination.startswith("submodules/"))
                self.assertNotIn("..", Path(destination).parts)


@unittest.skipUnless(os.environ.get("WHITEGRAM_ASSEMBLED_SOURCE"), "Set WHITEGRAM_ASSEMBLED_SOURCE")
class FullCompositionTests(unittest.TestCase):
    @classmethod
    def setUpClass(cls):
        _, cls.patchers = installer_configuration()
        cls.root = Path(os.environ["WHITEGRAM_ASSEMBLED_SOURCE"])

    def test_actual_installer_order_composes_and_each_stage_replays(self):
        staged = SourcePatches(self.root)
        stage(self.patchers, staged, replay_each=True)
        for relative, original in staged.original.items():
            self.assertEqual((self.root / relative).read_text(encoding="utf-8"), original)

    def test_complete_installer_sequence_preserves_all_later_upgrades_on_replay(self):
        staged = SourcePatches(self.root)
        stage(self.patchers, staged)
        first = dict(staged.pending)
        stage(self.patchers, staged)
        self.assertEqual(first.keys(), staged.pending.keys())
        for relative, text in first.items():
            with self.subTest(source=relative):
                if text != staged.pending[relative]:
                    self.fail("".join(difflib.unified_diff(text.splitlines(keepends=True), staged.pending[relative].splitlines(keepends=True), fromfile=relative + ":first", tofile=relative + ":replayed")))

    def test_replay_rejects_mixed_and_duplicate_upgraded_receipt_hooks(self):
        staged = SourcePatches(self.root)
        stage(self.patchers, staged)
        path = "submodules/TelegramCore/Sources/State/ManagedConsumePersonalMessagesActions.swift"
        upgraded = "WhitegramGhost.channelContentsRequest(network: network, channel: inputChannel, ids: [id.id], peerId: id.peerId)"
        legacy = "WhitegramGhost.channelContentsRequest(network: network, channel: inputChannel, ids: [id.id])"
        text = staged.pending[path]
        for malformed in (text.replace(upgraded, legacy, 1), text + "\n" + upgraded):
            replay = SourcePatches(self.root)
            replay.original = dict(staged.pending, **{path: malformed})
            replay.pending = dict(replay.original)
            with self.assertRaisesRegex(ValueError, "ambiguous upgraded patch"):
                stage(self.patchers, replay)
            self.assertEqual(replay.pending, replay.original)

    def test_composed_sources_have_no_new_swift_parser_errors(self):
        staged = SourcePatches(self.root)
        stage(self.patchers, staged)
        parser = Parser(Language(tree_sitter_swift.language()))
        def errors(text):
            data = text.encode("utf-8")
            nodes = [parser.parse(data).root_node]
            result = []
            while nodes:
                node = nodes.pop()
                if node.type == "ERROR" or node.is_missing:
                    result.append((node.type, data[node.start_byte:node.end_byte]))
                nodes.extend(node.children)
            return result
        for relative, text in staged.pending.items():
            if relative.endswith(".swift"):
                with self.subTest(source=relative):
                    self.assertEqual(errors(text), errors(staged.original[relative]))


if __name__ == "__main__":
    unittest.main()
