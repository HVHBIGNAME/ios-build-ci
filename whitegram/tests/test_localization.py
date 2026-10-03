"""Check localization source syntax, recovered literals and installation reachability."""

import ast
import json
from pathlib import Path
import re
import unittest

from tree_sitter import Language, Parser
import tree_sitter_swift


ROOT = Path(__file__).resolve().parents[1]


class LocalizationIntegrationTests(unittest.TestCase):
    def test_localization_and_consumers_parse(self):
        parser = Parser(Language(tree_sitter_swift.language()))
        paths = list((ROOT / "cleanroom").glob("WhitegramLocalization*.swift"))
        paths.extend((ROOT / "tests/localization").glob("*.swift"))
        paths.extend(ROOT / "cleanroom" / name for name in (
            "WhitegramMenuSection.swift", "WhitegramMainMenuController.swift",
            "WhitegramGeneratedSettingsScreen.swift", "WhitegramPortCapabilities.swift",
        ))
        paths.append(ROOT / "generated/WhitegramLocalizationStrings.swift")
        for path in paths:
            with self.subTest(path=path.name):
                data = path.read_bytes()
                nodes = [parser.parse(data).root_node]
                errors = []
                while nodes:
                    node = nodes.pop()
                    if node.type == "ERROR" or node.is_missing:
                        errors.append((node.start_point, data[node.start_byte:node.end_byte]))
                    nodes.extend(node.children)
                self.assertEqual(errors, [])

    def test_original_table_and_explicit_menu_bindings(self):
        table = (ROOT / "generated/WhitegramLocalizationStrings.swift").read_text(encoding="utf-8")
        pairs = re.findall(r'^\s*("(?:[^"\\]|\\.)+"):\s*(\[.*\]),$', table, re.MULTILINE)
        entries = {json.loads(key): json.loads(values) for key, values in pairs}
        self.assertEqual(len(pairs), 1597)
        self.assertEqual(len(entries), 1597)
        self.assertTrue(all(len(values) == 3 and all(isinstance(value, str) for value in values) for values in entries.values()))
        self.assertEqual(entries["section.ghost"], ["Режим призрака", "Режим привида", "Ghost Mode"])
        self.assertEqual(entries["desc.camera"][0], "Зум, HD-отправка, кружки")
        menu = (ROOT / "cleanroom/WhitegramMenuSection.swift").read_text(encoding="utf-8")
        aliases = re.findall(r'return \("([^"]+)", "([^"]+)"\)', menu)
        self.assertGreater(len(aliases), 5)
        for title, description in aliases:
            self.assertIn(title, entries)
            self.assertIn(description, entries)

    def test_installer_contains_runtime_table_and_ui(self):
        module = ast.parse((ROOT / "compat-12.9.4.py").read_text(encoding="utf-8"))
        mapping = next(ast.literal_eval(node.value) for node in module.body
                       if isinstance(node, ast.Assign) and any(isinstance(target, ast.Name) and target.id == "cleanroom_files" for target in node.targets))
        expected = {
            "generated/WhitegramLocalizationStrings.swift": "TelegramCore",
            "cleanroom/WhitegramLocalization.swift": "TelegramCore",
            "cleanroom/WhitegramLocalizationPack.swift": "TelegramCore",
            "cleanroom/WhitegramLocalizationStore.swift": "TelegramCore",
            "cleanroom/WhitegramLocalizationController.swift": "SettingsUI",
            "cleanroom/WhitegramLocalizationUI.swift": "SettingsUI",
        }
        for source, target in expected.items():
            self.assertTrue((ROOT / source).is_file())
            self.assertEqual(mapping[source], f"submodules/{target}/Sources/{Path(source).name}")


if __name__ == "__main__":
    unittest.main()
