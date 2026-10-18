"""Regressions for reviewed 13.0 upstream changes surviving the public overlay."""

import os
from pathlib import Path
import subprocess
import sys
import unittest

OVERLAY = Path(__file__).resolve().parents[1]
sys.path.insert(0, str(OVERLAY))
from port_public import BASE_REF, PUBLIC_REF, merge, normalize_indentation, text
from public_resolutions_13 import REVISION, resolve_13


@unittest.skipUnless(os.environ.get("WHITEGRAM_ASSEMBLED_SOURCE") and os.environ.get("WHITEGRAM_PUBLIC_SOURCE"), "Set assembled and public sources")
class Telegram13MergeTests(unittest.TestCase):
    def merged(self, path):
        def read(root, ref):
            return text(subprocess.check_output(["git", "-C", root, "show", f"{ref}:{path}"]))
        ours = read(os.environ["WHITEGRAM_ASSEMBLED_SOURCE"], REVISION)
        base = read(os.environ["WHITEGRAM_PUBLIC_SOURCE"], BASE_REF)
        theirs = read(os.environ["WHITEGRAM_PUBLIC_SOURCE"], PUBLIC_REF)
        value, clean = merge(ours, base, normalize_indentation(base, theirs))
        self.assertFalse(clean, path)
        result = resolve_13(path, value)
        self.assertNotIn("<<<<<<< upstream", result)
        return result

    def test_scene_attachment_and_rotation_registration_remain(self):
        result = self.merged("submodules/TelegramUI/Sources/AppDelegate.swift")
        for value in ("func attach(scene: UIWindowScene", "configurationForConnecting", "window.rootViewController = nil", "window.rootViewController = rootViewController", "self.mainWindow?.updateDeviceMetrics()"):
            self.assertIn(value, result)

    def test_login_has_one_proxy_observer_and_one_deinitializer(self):
        result = self.merged("submodules/TelegramCore/Sources/Account/Account.swift")
        account = result.split("public class UnauthorizedAccount {", 1)[1].split("public func changedMasterDatacenterId", 1)[0]
        self.assertEqual(account.count("    deinit {"), 1)
        self.assertEqual(account.count("self.proxySettingsDisposable.set("), 1)
        self.assertEqual(account.count("self.automaticProxyBootstrapDisposable.set("), 1)
        self.assertIn("network?.updateProxySettings(activeServer)", account)
        self.assertNotIn("network.context.updateApiEnvironment", account)
        self.assertEqual(account.count("self.automaticProxyBootstrapDisposable.dispose()"), 1)

    def test_new_context_actions_and_original_option_gates_coexist(self):
        result = self.merged("submodules/TelegramUI/Sources/ChatInterfaceStateContextMenus.swift")
        for value in ("isSharedMediaPolls", "hasEphemeralMessages", "WelcomeMessageCloud", "WalletConfiguration.with", "case .gramTransfer"):
            self.assertIn(value, result)
        for option in ("Reply", "Pin", "Select", "Edit"):
            self.assertIn(f"isWhiteGramMessageContextOptionEnabled(fromPrivate: .private{option}, channel: .channel{option})", result)

    def test_relocated_chat_observer_is_registered_once(self):
        result = self.merged("submodules/TelegramUI/Sources/ChatController.swift")
        self.assertEqual(result.count("self.whiteGramChatSettingsObserver = NotificationCenter.default.addObserver"), 1)
        self.assertLess(result.index("self.whiteGramChatSettingsObserver ="), result.index("if case let .messageOptions(_, messageIds, _) = self.subject, messageIds.count > 1"))

    def test_new_wallet_and_earnings_survive_business_visibility(self):
        result = self.merged("submodules/TelegramUI/Components/PeerInfo/PeerInfoScreen/Sources/PeerInfoSettingsItems.swift")
        for value in ("import WalletContext", "import TelegramUIPreferences", "interaction.openSettings(.wallet)", "PresentationResourcesSettings.gramEarnings", "whiteGramContextMenuSettings.isEnabled(.settingsBusiness)"):
            self.assertIn(value, result)

    def test_swipe_consumption_reset_remains_outside_opt_in(self):
        result = self.merged("submodules/TelegramUI/Sources/ChatHistoryListNode.swift")
        start = result.index("let expandProgress = strongSelf.currentOverscrollExpandProgress")
        reset = result.index("strongSelf.currentOverscrollExpandProgress = 0.0", start)
        guard = result.index("if WhiteGramChatSettings.current.channelSwipeToNext && strongSelf.offerNextChannelToRead, expandProgress >= 0.99", start)
        self.assertLess(reset, guard)


if __name__ == "__main__":
    unittest.main()
