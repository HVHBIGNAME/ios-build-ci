"""Apply original-semantics patches to the real assembled sources in memory."""

import os
from pathlib import Path
import sys
import unittest
from unittest.mock import patch

sys.path.insert(0, str(Path(__file__).resolve().parents[1]))

import appearance_parity_patches as parity
from test_appearance_extensions import MemoryRoot, syntax_errors


SOURCE = os.environ.get("WHITEGRAM_APPEARANCE_SOURCE")
WHITEGRAM = Path(__file__).resolve().parents[1]
TARGETS = (
    parity.STICKER, parity.ANIMATED, parity.STATUS, parity.BUBBLE,
    parity.PEER + "PeerInfoProfileItems.swift", parity.PEER + "PeerInfoScreen.swift",
    parity.PEER + "PeerInfoHeaderNode.swift", parity.TABS, parity.TAB_CONTROLLER, parity.TAB_COMPONENT, parity.LIST,
    parity.PEER + "PeerInfoSettingsItems.swift",
    parity.STARS + "StarsTransactionsScreen/Sources/StarsTransactionsScreen.swift",
    parity.STARS + "StarsPurchaseScreen/Sources/StarsPurchaseScreen.swift",
    parity.STARS + "StarsTransferScreen/Sources/StarsTransferScreen.swift",
    parity.STARS + "StarsBalanceOverlayComponent/Sources/StarsBalanceOverlayComponent.swift",
)


def apply_recorded(root):
    edits = []
    original = parity.replace

    def record(patches, feature, path, before, after, count=1):
        original(patches, feature, path, before, after, count)
        edits.append((path, before, after, count))

    with patch.object(parity, "replace", record):
        report = parity.apply_appearance_parity_patches(root)
    return report, edits


class AppearanceParitySourceTests(unittest.TestCase):
    def test_runtime_swift_syntax(self):
        for name in parity.APPEARANCE_PARITY_RUNTIME_FILES:
            with self.subTest(name=name):
                self.assertEqual(syntax_errors((WHITEGRAM / "cleanroom" / name).read_bytes()), [])

    def test_native_semantic_suite_parses(self):
        self.assertEqual(syntax_errors((WHITEGRAM / "tests" / "appearance_parity" / "main.swift").read_bytes()), [])


@unittest.skipUnless(SOURCE, "Set WHITEGRAM_APPEARANCE_SOURCE to assembled 12.9.2")
class AppearanceParityPatchTests(unittest.TestCase):
    @classmethod
    def setUpClass(cls):
        cls.files = {path: (Path(SOURCE) / path).read_text(encoding="utf-8") for path in TARGETS}
        cls.report, cls.edits = apply_recorded(MemoryRoot(cls.files))
        for path, before, after, count in reversed(cls.edits):
            if cls.files[path].count(after) == count:
                cls.files[path] = cls.files[path].replace(after, before)

    def test_complete_assembled_files_patch_parse_and_are_idempotent(self):
        root = MemoryRoot(self.files)
        report = parity.apply_appearance_parity_patches(root)
        self.assertEqual({p for paths in report.values() for p in paths}, set(TARGETS))
        first = dict(root.files)
        root.writes.clear()
        self.assertEqual(parity.apply_appearance_parity_patches(root), report)
        self.assertEqual(root.writes, [])
        self.assertEqual(root.files, first)
        for name in TARGETS:
            with self.subTest(name=name):
                self.assertEqual(syntax_errors(root.files[name]), [])

    def test_missing_and_ambiguous_anchors_never_write(self):
        for path, before, _, count in self.edits:
            for replacement in ("/* missing original anchor */", before + before):
                with self.subTest(path=path, anchor=before[:80], ambiguous=replacement != "/* missing original anchor */"):
                    root = MemoryRoot(self.files)
                    self.assertEqual(root.text(path).count(before), count)
                    root.files[path] = root.text(path).replace(before, replacement, 1).encode()
                    original = dict(root.files)
                    with self.assertRaises(ValueError):
                        parity.apply_appearance_parity_patches(root)
                    self.assertEqual(root.files, original)
                    self.assertEqual(root.writes, [])

    def test_mixed_old_new_edits_are_rejected(self):
        root = MemoryRoot(self.files)
        parity.apply_appearance_parity_patches(root)
        path, before, _, _ = self.edits[0]
        root.files[path] += before.encode()
        original = dict(root.files)
        root.writes.clear()
        with self.assertRaises(ValueError):
            parity.apply_appearance_parity_patches(root)
        self.assertEqual(root.files, original)
        self.assertEqual(root.writes, [])

    def test_exact_reversal_and_unrelated_file_isolation(self):
        root = MemoryRoot({**self.files, "untouched.swift": "// user work\r\n"})
        _, edits = apply_recorded(root)
        for path, before, after, count in reversed(edits):
            self.assertEqual(root.text(path).count(after), count)
            root.files[path] = root.text(path).replace(after, before).encode()
        self.assertEqual(root.files, MemoryRoot({**self.files, "untouched.swift": "// user work\r\n"}).files)

    def test_stars_overrides_are_confined_to_display_formatters(self):
        for path, before, after, _ in self.edits:
            if "WhitegramLocalStars" in after and "let actualBalance" not in after:
                self.assertTrue(before.startswith("formatStarsAmountText("))
                self.assertTrue(after.startswith("formatStarsAmountText("))
                self.assertIn("displayBalance(", after)
                self.assertNotIn("TelegramCore/Sources", path)
        root = MemoryRoot(self.files)
        parity.apply_appearance_parity_patches(root)
        settings = root.text(parity.PEER + "PeerInfoSettingsItems.swift")
        self.assertIn("(!isPremiumDisabled || abs(starsState.balance.value) > 0)", settings)
        transactions = root.text(parity.STARS + "StarsTransactionsScreen/Sources/StarsTransactionsScreen.swift")
        self.assertIn("formatTonAmountText(self.starsState?.balance.value ?? 0", transactions)

    def test_payment_functions_real_state_and_revenue_are_preserved(self):
        root = MemoryRoot(self.files)
        parity.apply_appearance_parity_patches(root)
        for path, start, end in (
            (parity.STARS + "StarsTransferScreen/Sources/StarsTransferScreen.swift", "        func buy(", "    func makeState()"),
            (parity.STARS + "StarsPurchaseScreen/Sources/StarsPurchaseScreen.swift", "        func buy(product:", "    func makeState()"),
        ):
            with self.subTest(path=path):
                original = self.files[path]
                left = original.index(start)
                right = original.index(end, left)
                self.assertIn(original[left:right], root.text(path))
        overlay = root.text(parity.STARS + "StarsBalanceOverlayComponent/Sources/StarsBalanceOverlayComponent.swift")
        self.assertIn("component.peerId == component.context.account.peerId ? WhitegramLocalStars", overlay)
        self.assertIn("self.starsBalance = starsState?.balance.value ?? 0", overlay)
        self.assertIn("self.starsBalance = balance", overlay)
        self.assertIn("formatTonAmountText(self.tonBalance", overlay)
        self.assertNotIn("Int32(self.starsBalance)", overlay)

    def test_local_stars_refresh_subscriptions_emit_actual_state(self):
        root = MemoryRoot(self.files)
        parity.apply_appearance_parity_patches(root)
        for name in ("StarsTransactionsScreen", "StarsPurchaseScreen", "StarsTransferScreen", "StarsBalanceOverlayComponent"):
            path = parity.STARS + name + "/Sources/" + name + ".swift"
            with self.subTest(path=path):
                self.assertIn("WhitegramAppearanceSettings.signal()) |> map { state, _ in state }", root.text(path))
                self.assertRegex(root.text(path), r"self\.(?:stateDisposable|disposable|balanceDisposable)\?\.dispose\(\)")

    def test_hide_all_chats_keeps_a_fallback_and_repairs_selection(self):
        root = MemoryRoot(self.files)
        parity.apply_appearance_parity_patches(root)
        source = root.text(parity.LIST)
        self.assertIn('isEnabled("hideAllChatsTab") && allItems.count > 1', source)
        self.assertIn("let firstItem = items.first?.0 ?? .allChats", source)
        self.assertIn("if !hasAllChats && !hideAllChats", source)
        self.assertIn("selectedEntryId = first.id\n                resetCurrentEntry = true", source)

    def test_tab_height_invalidates_component_and_containing_safe_inset(self):
        root = MemoryRoot(self.files)
        parity.apply_appearance_parity_patches(root)
        node = root.text(parity.TABS)
        self.assertIn("self.layoutResult = nil\n            self.whitegramAppearanceUpdated?()", node)
        self.assertIn("self?.updateLayout(transition: .immediate)", root.text(parity.TAB_CONTROLLER))
        component = root.text(parity.TAB_COMPONENT)
        self.assertIn("lhs.heightScale != rhs.heightScale", component)
        self.assertIn("let itemHeight = baseItemHeight * component.heightScale", component)
        self.assertIn("let barHeight = (baseItemHeight + innerInset * 2.0) * component.heightScale", component)
        self.assertIn("height: itemHeight + innerInset * 2.0", component)
        self.assertNotIn('isEnabled("hideBottomTabBar")', node)

    def test_phone_rows_match_original_global_gate_and_header_disclosure_is_hidden(self):
        root = MemoryRoot(self.files)
        parity.apply_appearance_parity_patches(root)
        profile = root.text(parity.PEER + "PeerInfoProfileItems.swift")
        header = root.text(parity.PEER + "PeerInfoHeaderNode.swift")
        self.assertIn('if !WhitegramAppearancePolicy.current.isEnabled("hidePhoneNumber"), let phone', profile)
        self.assertNotIn('isMyProfile && WhitegramAppearancePolicy.current.isEnabled("hidePhoneNumber")', profile)
        self.assertIn('(self.isSettings || self.isMyProfile)', header)
        self.assertIn('subtitle.isEmpty ? "@\\(mainUsername)"', header)
        handler = header[header.index("@objc private func handlePhoneLongPress"):]
        self.assertLess(handler.index('isEnabled("hidePhoneNumber")'), handler.index("gestureRecognizer.state"))

    def test_wallet_visibility_is_a_preference_and_keeps_the_native_action(self):
        root = MemoryRoot(self.files)
        parity.apply_appearance_parity_patches(root)
        source = root.text(parity.PEER + "PeerInfoSettingsItems.swift")
        self.assertIn('bot.shortName.lowercased() == "wallet" && WhitegramAppearancePolicy.current.isEnabled("hideWallet")', source)
        self.assertIn("interaction.openBotApp(bot)", source)
        self.assertIn("bot.flags.contains(.notActivated)", source)


if __name__ == "__main__":
    unittest.main()
