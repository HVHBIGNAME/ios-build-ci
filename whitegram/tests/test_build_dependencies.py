"""Verify that installed Bazel dependencies remain separate Starlark list items."""

import ast
import io
import os
from pathlib import Path
import re
import subprocess
import sys
import tempfile
import tokenize
import unittest
from unittest.mock import patch

OVERLAY = Path(__file__).resolve().parents[1]
sys.path.insert(0, str(OVERLAY))
from build_patches import add_dep


def dependencies(text):
    call = ast.parse(text).body[0].value
    return ast.literal_eval(next(keyword.value for keyword in call.keywords if keyword.arg == "deps"))


class BuildDependencyTests(unittest.TestCase):
    def test_insertion_preserves_items_with_optional_trailing_commas_and_comments(self):
        for items, expected in [
            ("[]", []),
            ('["//old:old"]', ["//old:old"]),
            ('[\n        "//old:old",\n    ]', ["//old:old"]),
            ('[\n        "//old:old" # A bracket ] in a comment\n    ]', ["//old:old"]),
        ]:
            with self.subTest(items=items), tempfile.TemporaryDirectory() as directory:
                path = Path(directory) / "BUILD"
                path.write_text(f'swift_library(\n    name = "Example",\n    deps = {items},\n)\n', encoding="utf-8")
                self.assertTrue(add_dep(path, "//new:new"))
                self.assertEqual(["//new:new", *expected], dependencies(path.read_text(encoding="utf-8")))
                installed = path.read_bytes()
                with patch.object(Path, "write_text", side_effect=AssertionError("Duplicate dependency rewrote BUILD")):
                    self.assertFalse(add_dep(path, "//new:new"))
                self.assertEqual(installed, path.read_bytes())

    def test_package_shorthand_is_already_a_dependency(self):
        with tempfile.TemporaryDirectory() as directory:
            path = Path(directory) / "BUILD"
            original = 'swift_library(\n    deps = ["//submodules/AudioWaveform"],\n)\n'
            path.write_text(original, encoding="utf-8")
            self.assertFalse(add_dep(path, "//submodules/AudioWaveform:AudioWaveform"))
            self.assertEqual(original, path.read_text(encoding="utf-8"))


@unittest.skipUnless(os.environ.get("WHITEGRAM_ASSEMBLED_SOURCE"), "Set WHITEGRAM_ASSEMBLED_SOURCE")
class AssembledBuildTests(unittest.TestCase):
    def test_opus_archive_is_force_loaded_for_downstream_framework_consumers(self):
        root = Path(os.environ["WHITEGRAM_ASSEMBLED_SOURCE"])
        build = ast.parse((root / "third-party/opus/BUILD").read_text(encoding="utf-8"))
        targets = [node.value for node in build.body if isinstance(node, ast.Expr) and isinstance(node.value, ast.Call)
                   and any(keyword.arg == "name" and ast.literal_eval(keyword.value) == "opus_lib" for keyword in node.value.keywords)]
        self.assertEqual(len(targets), 1)
        target = targets[0]
        self.assertEqual(target.func.id, "cc_import", "cc_library.alwayslink does not force-load precompiled .a inputs")
        attributes = {keyword.arg: ast.literal_eval(keyword.value) for keyword in target.keywords}
        self.assertEqual(attributes["static_library"], ":Public/opus/lib/libopus.a")
        self.assertIs(attributes["alwayslink"], True)

    def test_audio_waveform_model_has_no_ui_dependencies(self):
        root = Path(os.environ["WHITEGRAM_ASSEMBLED_SOURCE"]) / "submodules/AudioWaveform"
        source_files = list((root / "Sources").rglob("*.swift"))
        self.assertTrue(source_files)
        for source in source_files:
            imports = set(re.findall(r"(?m)^import (\w+)", source.read_text(encoding="utf-8")))
            self.assertEqual(imports, {"Foundation"}, f"Review AudioWaveform dependencies for {source.name}")
        build = ast.parse((root / "BUILD").read_text(encoding="utf-8"))
        target = next(node.value for node in build.body if isinstance(node, ast.Expr) and isinstance(node.value, ast.Call)
                      and isinstance(node.value.func, ast.Name) and node.value.func.id == "swift_library")
        deps = ast.literal_eval(next(keyword.value for keyword in target.keywords if keyword.arg == "deps"))
        self.assertEqual(deps, [], "AudioWaveform must not pull UI libraries into TelegramCoreFramework")

    def test_modified_build_files_have_no_implicit_string_concatenation(self):
        root = Path(os.environ["WHITEGRAM_ASSEMBLED_SOURCE"])
        paths = subprocess.check_output(["git", "-C", str(root), "diff", "--name-only", "HEAD", "--", "*BUILD", "*BUILD.bazel"], text=True).splitlines()
        self.assertTrue(paths, "The assembled tree has no modified BUILD files")
        for relative in paths:
            with self.subTest(path=relative):
                text = (root / relative).read_text(encoding="utf-8")
                previous = None
                for token in tokenize.generate_tokens(io.StringIO(text).readline):
                    if token.type in (tokenize.COMMENT, tokenize.NL):
                        continue
                    self.assertFalse(previous == tokenize.STRING and token.type == tokenize.STRING,
                                     f"Implicit string concatenation in {relative}:{token.start[0]}")
                    previous = token.type


if __name__ == "__main__":
    unittest.main()
