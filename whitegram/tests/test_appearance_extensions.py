"""Exercise appearance edits on real 12.9.2 sources entirely in memory.

WHITEGRAM_APPEARANCE_SOURCE is a read-only assembled checkout containing the
pinned upstream commit. No fixture, bytecode or patched source is written there.
"""

import ast
import os
from pathlib import Path
import re
import subprocess
import sys
import unittest
from unittest.mock import patch

from tree_sitter import Language, Parser
import tree_sitter_swift


WHITEGRAM = Path(__file__).resolve().parents[1]
sys.path.insert(0, str(WHITEGRAM))

import appearance_extension_patches as extensions


SOURCE = os.environ.get("WHITEGRAM_APPEARANCE_SOURCE")
UPSTREAM = "6ad963e5b62d354da79040f388ae2b9132fb17b8"
TARGETS = (
    "submodules/ChatMessageBackground/Sources/ChatMessageBackground.swift",
    "submodules/TelegramPresentationData/Sources/PresentationThemeEssentialGraphics.swift",
    "submodules/TelegramUI/Components/Chat/ChatTextInputPanelNode/Sources/ChatTextInputPanelNode.swift",
    "submodules/TelegramUI/Components/Chat/ChatMessageTextBubbleContentNode/Sources/ChatMessageTextBubbleContentNode.swift",
    "submodules/TelegramUI/Components/Chat/ChatMessageActionBubbleContentNode/Sources/ChatMessageActionBubbleContentNode.swift",
    "submodules/TelegramUI/Sources/ChatInterfaceTitlePanelNodes.swift",
    "submodules/TelegramUI/Sources/ChatHistoryListNode.swift",
    "submodules/TelegramUI/Sources/ChatController.swift",
)
SWIFT_FILES = (
    "WhitegramAppearanceSettings.swift",
    "WhitegramBubbleAppearance.swift",
    "WhitegramAppearanceController.swift",
)
# Original menu case -> actual stored field, independent of the patch inventory.
RECOVERED_KEYS = {
    "messageBorder": ("messageBorderEnabled", "Bool"),
    "transparentMessages": ("transparentMessages", "Bool"),
    "semiTransparentBubbles": ("semiTransparentBubbles", "Bool"),
    "showCharCountTyping": ("showCharCountTyping", "Bool"),
    "showCharCountMessages": ("showCharCountMessages", "Bool"),
    "showActionTime": ("showActionTime", "Bool"),
    "hideBusinessBotPanel": ("hideBusinessBotPanel", "Bool"),
}


class MemoryFile:
    def __init__(self, root, path):
        self.root = root
        self.path = path

    def read_text(self, encoding):
        if self.path not in self.root.files:
            raise FileNotFoundError(self.path)
        return self.root.files[self.path].decode(encoding).replace("\r\n", "\n").replace("\r", "\n")

    def write_bytes(self, value):
        self.root.files[self.path] = value
        self.root.writes.append(self.path)
        return len(value)


class MemoryRoot:
    def __init__(self, files):
        self.files = {name: text.encode("utf-8") for name, text in files.items()}
        self.writes = []

    def __truediv__(self, path):
        return MemoryFile(self, path)

    def text(self, path):
        return self.files[path].decode("utf-8")


def apply_recorded(root):
    edits = []
    replace = extensions._replace

    def record(patches, feature, path, before, after):
        replace(patches, feature, path, before, after)
        edits.append((feature, path, before, after))

    with patch.object(extensions, "_replace", record):
        report = extensions.apply_appearance_extensions(root)
    return report, edits


def syntax_errors(source):
    parser = Parser(Language(tree_sitter_swift.language()))
    tree = parser.parse(source)
    pending = [tree.root_node]
    errors = []
    while pending:
        node = pending.pop()
        if node.type == "ERROR" or node.is_missing:
            errors.append((node.start_point.row + 1, node.start_point.column + 1, node.type))
        pending.extend(reversed(node.children))
    return errors


class AppearanceSourceTests(unittest.TestCase):
    def test_new_swift_files_parse(self):
        for name in SWIFT_FILES:
            with self.subTest(file=name):
                self.assertEqual(syntax_errors((WHITEGRAM / "cleanroom" / name).read_bytes()), [])

    def test_python_patch_module_parses(self):
        ast.parse((WHITEGRAM / "appearance_extension_patches.py").read_text(encoding="utf-8"))

    def test_screen_and_persistence_use_recovered_names_and_control_types(self):
        state = (WHITEGRAM / "generated" / "WhitegramSettingsState.swift").read_text(encoding="utf-8")
        catalog = (WHITEGRAM / "generated" / "WhitegramSettingsCatalog.swift").read_text(encoding="utf-8")
        model = (WHITEGRAM / "cleanroom" / "WhitegramAppearanceSettings.swift").read_text(encoding="utf-8")
        screen = (WHITEGRAM / "cleanroom" / "WhitegramAppearanceController.swift").read_text(encoding="utf-8")
        cases = re.search(r"public enum WhitegramAppearanceToggle[^\{]*\{(.*?)\n\}", model, re.S).group(1)
        self.assertEqual(set(re.findall(r"case (\w+)", cases)), {key for key, _ in RECOVERED_KEYS.values()})
        for row, (key, kind) in RECOVERED_KEYS.items():
            with self.subTest(key=key):
                self.assertRegex(state, rf"public var {key}: {kind}\b")
                self.assertRegex(catalog, rf'id: "{row}", [^\n]*kind: \.switchRow')
                self.assertIn(f"toggle(.{key},", screen)
        self.assertIn('public var messageBorderColorHex: String', state)
        self.assertNotIn('"messageBorder":', model)

    def test_no_independent_store_or_lower_layer_preference_mirrors(self):
        model = (WHITEGRAM / "cleanroom" / SWIFT_FILES[0]).read_text(encoding="utf-8")
        renderer = (WHITEGRAM / "cleanroom" / SWIFT_FILES[1]).read_text(encoding="utf-8")
        screen = (WHITEGRAM / "cleanroom" / SWIFT_FILES[2]).read_text(encoding="utf-8")
        self.assertIn("WhitegramPreferences.values()", model)
        self.assertIn("CFBooleanGetTypeID()", model)
        self.assertNotIn("UserDefaults.standard.set", model + renderer + screen)
        self.assertNotIn("UserDefaults", renderer)
        self.assertIn("WhitegramPreferences.update(changes)", screen)
        self.assertIn("WhitegramPreferences.updatedNotification", model)
        self.assertIn("ActionDisposable { NotificationCenter.default.removeObserver(observer) }", model)


@unittest.skipUnless(SOURCE, "Set WHITEGRAM_APPEARANCE_SOURCE to the read-only 12.9.2 assembled tree")
class AppearanceExtensionPatchTests(unittest.TestCase):
    @classmethod
    def setUpClass(cls):
        cls.source = Path(SOURCE)
        cls.installed = {name: (cls.source / name).read_text(encoding="utf-8") for name in TARGETS}
        cls.pristine = {}
        for name in TARGETS:
            result = subprocess.run(["git", "show", f"{UPSTREAM}:{name}"], cwd=cls.source,
                                    check=True, capture_output=True, encoding="utf-8")
            cls.pristine[name] = result.stdout
        # CI validates after assembly. Remove only our exact edits in memory so
        # missing-anchor tests keep the public overlay and other feature patches.
        _, edits = apply_recorded(MemoryRoot(cls.pristine))
        cls.assembled = dict(cls.installed)
        for _, path, before, after in reversed(edits):
            occurrences = cls.assembled[path].count(after)
            if occurrences > 1:
                raise AssertionError(f"Duplicate installed appearance edit: {path}")
            if occurrences == 1:
                cls.assembled[path] = cls.assembled[path].replace(after, before, 1)

    def test_pinned_pristine_and_assembled_sources_are_patchable_and_idempotent(self):
        for stage, files in (("pristine", self.pristine), ("assembled", self.assembled), ("installed", self.installed)):
            with self.subTest(stage=stage):
                root = MemoryRoot(files)
                report = extensions.apply_appearance_extensions(root)
                first = dict(root.files)
                self.assertEqual({path for paths in report.values() for path in paths}, set(TARGETS))
                expected_writes = {path for path in TARGETS if first[path] != files[path].encode("utf-8")}
                self.assertEqual(set(root.writes), expected_writes)
                root.writes.clear()
                self.assertEqual(extensions.apply_appearance_extensions(root), report)
                self.assertEqual(root.files, first)
                self.assertEqual(root.writes, [])

    def test_reverse_all_exact_edits_preserves_every_original_byte(self):
        root = MemoryRoot(self.assembled)
        _, edits = apply_recorded(root)
        for _, path, before, after in reversed(edits):
            self.assertEqual(root.text(path).count(after), 1)
            root.files[path] = root.text(path).replace(after, before, 1).encode("utf-8")
        self.assertEqual(root.files, MemoryRoot(self.assembled).files)

    def test_every_missing_anchor_fails_before_any_native_write(self):
        _, edits = apply_recorded(MemoryRoot(self.assembled))
        for feature, path, before, _ in edits:
            with self.subTest(feature=feature, path=path, anchor=before[:90]):
                root = MemoryRoot(self.assembled)
                self.assertIn(before, root.text(path))
                root.files[path] = root.text(path).replace(before, "/* upstream changed this anchor */", 1).encode("utf-8")
                initial = dict(root.files)
                with self.assertRaises(ValueError):
                    extensions.apply_appearance_extensions(root)
                self.assertEqual(root.writes, [])
                self.assertEqual(root.files, initial)

    def test_missing_last_file_does_not_write_preceding_files(self):
        root = MemoryRoot(self.assembled)
        del root.files[TARGETS[-1]]
        initial = dict(root.files)
        with self.assertRaises(FileNotFoundError):
            extensions.apply_appearance_extensions(root)
        self.assertEqual(root.files, initial)
        self.assertEqual(root.writes, [])

    def test_ambiguous_original_and_already_applied_anchors_are_rejected(self):
        full = MemoryRoot(self.assembled)
        _, edits = apply_recorded(full)
        _, path, before, after = edits[0]
        for sources, suffix in ((self.assembled, before),
                                ({name: full.text(name) for name in TARGETS}, before),
                                ({name: full.text(name) for name in TARGETS}, after)):
            with self.subTest(suffix=suffix):
                root = MemoryRoot(sources)
                root.files[path] += suffix.encode("utf-8")
                initial = dict(root.files)
                with self.assertRaises(ValueError):
                    extensions.apply_appearance_extensions(root)
                self.assertEqual(root.files, initial)
                self.assertEqual(root.writes, [])

    def test_partial_application_converges_to_the_complete_result(self):
        full = MemoryRoot(self.assembled)
        report, edits = apply_recorded(full)
        root = MemoryRoot(self.assembled)
        for _, path, before, after in edits[:12]:
            root.files[path] = root.text(path).replace(before, after, 1).encode("utf-8")
        self.assertEqual(extensions.apply_appearance_extensions(root), report)
        self.assertEqual(root.files, full.files)

    def test_coexists_with_other_chat_lifecycle_hooks(self):
        root = MemoryRoot(self.assembled)
        controller = TARGETS[-1]
        plugin_hook = "        WhitegramPluginHooks.chatClosed(postbox: self.context.account.postbox, token: self.whitegramPluginChatToken)\n"
        anchor = "    deinit {\n"
        if anchor + plugin_hook not in root.text(controller):
            root.files[controller] = root.text(controller).replace(anchor, anchor + plugin_hook, 1).encode("utf-8")
        extensions.apply_appearance_extensions(root)
        self.assertIn(anchor + plugin_hook, root.text(controller))
        self.assertEqual(root.text(controller).count("self.whitegramAppearanceDisposable?.dispose()"), 1)
        root.writes.clear()
        extensions.apply_appearance_extensions(root)
        self.assertEqual(root.writes, [])

    def test_crlf_input_normalizes_without_rewriting_unrelated_files(self):
        originals = {name: text.replace("\n", "\r\n") for name, text in self.assembled.items()}
        originals["submodules/Display/Source/Font.swift"] = "untouched\r\n"
        originals["Telegram/Telegram-iOS/Info.plist"] = "untouched\r\n"
        root = MemoryRoot(originals)
        extensions.apply_appearance_extensions(root)
        normal = MemoryRoot(self.assembled)
        extensions.apply_appearance_extensions(normal)
        for name in TARGETS:
            self.assertEqual(root.files[name], normal.files[name])
        for name in set(originals) - set(TARGETS):
            self.assertEqual(root.text(name), originals[name])
            self.assertNotIn(name, root.writes)

    def test_all_patched_native_sources_parse(self):
        root = MemoryRoot(self.assembled)
        extensions.apply_appearance_extensions(root)
        for name in TARGETS:
            with self.subTest(file=name):
                self.assertEqual(syntax_errors(root.files[name]), [])

    def test_bubble_masks_geometry_and_layout_functions_are_untouched(self):
        root = MemoryRoot(self.assembled)
        extensions.apply_appearance_extensions(root)
        original = self.assembled[TARGETS[0]]
        changed = root.text(TARGETS[0])
        for start, end in (("    public func currentCorners(", "    public func setType("),
                           ("public func bubbleMaskForType(", "public final class ChatMessageBubbleBackdrop"),
                           ("    public func updateLayout(size:", "    public func setMaskMode(")):
            with self.subTest(function=start):
                self.assertEqual(original[original.index(start):original.index(end, original.index(start))],
                                 changed[changed.index(start):changed.index(end, changed.index(start))])

    def test_all_native_merge_variants_have_the_matching_outline_direction(self):
        root = MemoryRoot(self.assembled)
        extensions.apply_appearance_extensions(root)
        source = root.text(TARGETS[0])
        matches = re.findall(r"outlineImage = whitegramAppearance\.outlineImage\(incoming: (true|false), neighbors: (.*?), graphics: graphics\) \?\? graphics\.chatMessageBackground(Incoming|Outgoing)(\w*)OutlineImage", source)
        self.assertEqual(len(matches), 14)
        expected = {"": ".none", "MergedTop": ".top(side: false)", "MergedTopSide": ".top(side: true)",
                    "MergedBottom": ".bottom", "MergedBoth": ".both", "MergedSide": ".side", "Extracted": ".extracted"}
        for incoming, neighbor, direction, suffix in matches:
            self.assertEqual(incoming, "true" if direction == "Incoming" else "false")
            self.assertEqual(neighbor, expected[suffix])
        self.assertNotIn("TelegramCore", source)
        self.assertIn("self.backgroundContent?.alpha = WhitegramBubbleAppearance.current.fillOpacity", source)
        self.assertIn("self.contentNode.alpha = WhitegramBubbleAppearance.current.fillOpacity", source)

    def test_message_content_and_status_layout_arguments_are_preserved(self):
        root = MemoryRoot(self.assembled)
        extensions.apply_appearance_extensions(root)
        original = self.assembled[TARGETS[3]]
        changed = root.text(TARGETS[3])
        layout = "statusLayout(ChatMessageDateAndStatusNode.Arguments("
        self.assertEqual(original[original.index(layout):], changed[changed.index(layout):])
        self.assertNotRegex(changed, r"item\.message\.text\s*=")
        self.assertIn("dateText: dateText,", changed)

    def test_live_refresh_uses_the_real_history_identity_invalidation_contract(self):
        root = MemoryRoot(self.assembled)
        extensions.apply_appearance_extensions(root)
        entries = (self.source / "submodules/TelegramUI/Components/Chat/ChatHistoryEntry/Sources/ChatHistoryEntry.swift").read_text(encoding="utf-8")
        self.assertIn("lhsPresentationData !== rhsPresentationData", entries)
        self.assertIn("lhsPresentationData === rhsPresentationData", entries)
        history = root.text(TARGETS[6])
        self.assertIn("let updated = ChatPresentationData(", history)
        self.assertIn("self.chatPresentationDataPromise.set(.single(updated))", history)
        controller = root.text(TARGETS[7])
        self.assertIn("self.whitegramAppearanceDisposable?.dispose()", controller)
        self.assertIn("|> deliverOnMainQueue).start(next: { [weak self]", controller)

    def test_native_preview_and_renderer_api_contracts_exist_on_the_pin(self):
        preview = (self.source / "submodules/SettingsUI/Sources/Themes/ThemeSettingsChatPreviewItem.swift").read_text(encoding="utf-8")
        bubbles = (self.source / "submodules/TelegramPresentationData/Sources/ChatMessageBubbleImages.swift").read_text(encoding="utf-8")
        chat_data = (self.source / "submodules/TelegramPresentationData/Sources/ChatPresentationData.swift").read_text(encoding="utf-8")
        self.assertIn("struct ChatPreviewMessageItem: Equatable", preview)
        self.assertIn("init(context: AccountContext, systemStyle: ItemListSystemStyle", preview)
        self.assertIn("messageItems: [ChatPreviewMessageItem]", preview)
        self.assertIn("shadow: PresentationThemeBubbleShadow?", bubbles)
        self.assertIn("onlyOutline: Bool = false", bubbles)
        self.assertIn("public let animatedEmojiScale: CGFloat", chat_data)
        self.assertIn("public let isPreview: Bool", chat_data)


if __name__ == "__main__":
    unittest.main()
