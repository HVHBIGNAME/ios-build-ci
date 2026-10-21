"""Verify actual public proxy/login code and the installed, replayable integration."""

import os
from pathlib import Path
import subprocess
import sys
import unittest

OVERLAY = Path(__file__).resolve().parents[1]
sys.path.insert(0, str(OVERLAY))
from network_patches import APPLICATION, APP_DELEGATE, AUTHORIZATION, NETWORK, PROXIES, PROXY_UI, apply_network_patches
from port_public import PUBLIC_REF
from test_history_patches import MemoryRoot, parse_sources
from login_check import evaluate


class LoginEvidenceTests(unittest.TestCase):
    def test_server_rejection_of_fictional_number_proves_request_reached_telegram(self):
        for auth in ({"auth": "success"}, {"auth": "rpc-error", "auth_error": "PHONE_NUMBER_INVALID"}, {"auth": "rpc-error", "auth_error": "PHONE_NUMBER_BANNED"}):
            self.assertIn("Telegram", evaluate({"schema": 1, "token": "a" * 32, "probe": "success", **auth}, "a" * 32))

    def test_transport_timeout_api_rejection_and_missing_submission_cannot_pass(self):
        valid = {"schema": 1, "token": "a" * 32, "probe": "success", "auth": "success"}
        for invalid in ({"probe": "timeout"}, {"token": "b" * 32}, {"auth": "not-submitted"},
                        {"auth": "pending", "auth_error": "PHONE_MIGRATE_1"},
                        {"auth": "rpc-error", "auth_error": "PHONE_MIGRATE_1"},
                        {"auth_flow": "timeout"},
                        {"auth": "rpc-error", "auth_error": "API_ID_INVALID"}, {"auth": "rpc-error", "auth_error": "TIMEOUT"}):
            with self.subTest(invalid=invalid), self.assertRaises(ValueError):
                evaluate({**valid, **invalid}, "a" * 32)

    def test_probe_and_ui_fixture_parse(self):
        paths = [OVERLAY / "cleanroom/WhitegramLoginProbe.swift", *sorted((OVERLAY / "tests/login").rglob("*.swift"))]
        self.assertTrue(all(not diagnostics for diagnostics in parse_sources({str(path): path.read_text(encoding="utf-8") for path in paths}).values()))

    def test_verified_package_rejection_explains_pending_login_failure(self):
        record = {"schema": 1, "token": "a" * 32, "probe": "success", "auth": "pending", "auth_flow": "timeout",
                  "events": [{"name": "recaptcha-execute-error", "code": 4}]}
        with self.assertRaisesRegex(ValueError, "errorInvalidPackageName"):
            evaluate(record, "a" * 32)
        with self.assertRaisesRegex(ValueError, "timed out"):
            evaluate({**record, "events": [{"name": "recaptcha-execute-error", "code": 1}]}, "a" * 32)
        with self.assertRaisesRegex(ValueError, "timed out"):
            evaluate({**record, "events": record["events"] + [{"name": "recaptcha-execute-success"}]}, "a" * 32)
        self.assertIn("accepted", evaluate({**record, "auth": "success", "auth_flow": "pending"}, "a" * 32))


@unittest.skipUnless(os.environ.get("WHITEGRAM_PUBLIC_SOURCE"), "Set WHITEGRAM_PUBLIC_SOURCE")
class NetworkPatchTests(unittest.TestCase):
    @classmethod
    def setUpClass(cls):
        cls.original = {path: subprocess.check_output(["git", "-C", os.environ["WHITEGRAM_PUBLIC_SOURCE"], "show", f"{PUBLIC_REF}:{path}"]).decode("utf-8") for path in (APPLICATION, APP_DELEGATE, AUTHORIZATION, NETWORK, PROXIES, PROXY_UI)}

    def patched(self):
        root = MemoryRoot(self.original)
        apply_network_patches(root)
        return root

    def test_real_fork_applies_and_replays_without_writes(self):
        root = MemoryRoot(self.original)
        report = apply_network_patches(root)
        result = root.texts()
        root.writes.clear()
        self.assertEqual(apply_network_patches(root), report)
        self.assertEqual(root.writes, [])
        self.assertEqual(root.texts(), result)
        for path, diagnostics in parse_sources(result).items():
            self.assertEqual(diagnostics, [], path)

    def test_no_proxy_hint_without_connection_evidence(self):
        app = self.patched().text(APPLICATION)
        self.assertNotIn("didShowProxyRecommendation", app)
        self.assertNotIn("proxyRecommendationText", app)
        self.assertIn("account.shouldBeServiceTaskMaster.set(sharedContext.applicationBindings.applicationInForeground", app)
        self.assertEqual(app.count("whitegramObserveLoginConnection("), 1)
        self.assertIn("self.whitegramLoginProbe?.dispose()", app)

    def test_refresh_preserves_manual_ip_proxy_and_large_user_lists(self):
        source = self.patched().text(PROXIES)
        self.assertNotIn("automaticProxyHostIsIPAddress(activeServer.host)", source)
        self.assertNotIn("migrateLegacyAutomaticServers", source)
        self.assertIn("server == settings.activeServer || !automaticSet.contains(server)", source)
        self.assertIn("existing: manualServers, fetched: fetchedServers, limit: max(automaticProxyStoredServerLimit, manualServers.count)", source)
        self.assertIn("fetchedServers.filter { !manualServers.contains($0) && settings.servers.contains($0) }", source)

    def test_login_flow_observation_preserves_errors_migration_and_deadline(self):
        source = self.patched().text(AUTHORIZATION)
        observation = ("        |> mapError { error -> AuthorizationCodeRequestError in\n"
                       "            WhitegramLoginProbe.authFlowError(error)\n"
                       "            return error\n"
                       "        }\n")
        self.assertEqual(source.count(observation), 1)
        self.assertEqual(source.replace(observation, ""), self.original[AUTHORIZATION])

    def test_live_and_waiting_networks_do_not_switch_on_ping_updates(self):
        root = self.patched()
        source = root.text(PROXIES)
        self.assertNotIn("settings.activeServer = automaticProxySortedAvailableServers", source)
        self.assertEqual(source.count("strongSelf.currentSettings.enabled && strongSelf.currentSettings.autoConnectOnLaunch && strongSelf.proxyNeeded"), 2)
        waiting = source.split("        case .waitingForNetwork, .updating:", 1)[1].split("    private func scheduleProxyActivation", 1)[0]
        self.assertNotIn("scheduleProxyActivation()", waiting)
        self.assertNotIn("current.activeServer = bestServer", root.text(PROXY_UI))

    def test_verification_observation_preserves_providers_and_does_not_record_secrets(self):
        root = self.patched()
        for path in (APP_DELEGATE, NETWORK):
            source = root.text(path)
            lines = source.splitlines(keepends=True)
            stripped = "".join(line for line in lines if "whitegramRecordLoginVerification(" not in line)
            self.assertEqual(stripped, self.original[path])
        self.assertIn('event: "recaptcha-requested"', root.text(NETWORK))
        delegate = root.text(APP_DELEGATE)
        self.assertIn('"recaptcha-client-error"', delegate)
        self.assertIn('"recaptcha-execute-error"', delegate)
        self.assertEqual(delegate.count('code: (error as NSError?)?.code'), 2)

    def test_drift_aborts_all_writes(self):
        files = dict(self.original)
        files[PROXY_UI] = files[PROXY_UI].replace("proxySettings.enabled && proxySettings.autoConnectOnLaunch, let bestServer", "changedPolicy, let bestServer")
        root = MemoryRoot(files)
        with self.assertRaises(ValueError):
            apply_network_patches(root)
        self.assertEqual(root.writes, [])
        self.assertEqual(root.texts(), files)


if __name__ == "__main__":
    unittest.main()
