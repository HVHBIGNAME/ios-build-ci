"""Stage backend/traffic hooks against the immutable assembled Telegram baseline."""

import json
import os
from pathlib import Path
import sys
import unittest

from tree_sitter import Language, Parser
import tree_sitter_swift

OVERLAY = Path(__file__).resolve().parents[1]
sys.path.insert(0, str(OVERLAY))
from backend_patches import APP_DELEGATE, BACKEND_RUNTIME_FILES, SENT_MESSAGES, STATE_MANAGER, backend_patches
from source_patches import SourcePatches
from traffic_patches import TRAFFIC_RUNTIME_FILES, traffic_patches


def syntax_errors(parser, text):
    data = text.encode("utf-8")
    nodes = [parser.parse(data).root_node]
    errors = []
    while nodes:
        node = nodes.pop()
        if node.type == "ERROR" or node.is_missing:
            errors.append((node.type, node.start_point, data[node.start_byte:node.end_byte]))
        nodes.extend(node.children)
    return errors


class BackendSourceTests(unittest.TestCase):
    def test_runtime_registry_covers_owned_sources_once(self):
        prefixes = ("WhitegramBackend", "WhitegramProfile", "WhitegramRadio", "WhitegramTraffic", "WhitegramAPIStatus", "WhitegramScammer")
        names = {path.name for path in (OVERLAY / "cleanroom").glob("*.swift") if path.name.startswith(prefixes)}
        self.assertFalse(BACKEND_RUNTIME_FILES.keys() & TRAFFIC_RUNTIME_FILES.keys())
        manifest = {**BACKEND_RUNTIME_FILES, **TRAFFIC_RUNTIME_FILES}
        self.assertEqual(names, manifest.keys())
        self.assertEqual(len(manifest), len(set(manifest.values())))
        handoff = json.loads((OVERLAY / "parity/backend.json").read_text(encoding="utf-8"))
        self.assertEqual(manifest, handoff["runtime_files"])

    def test_owned_production_swift_parses(self):
        parser = Parser(Language(tree_sitter_swift.language()))
        for name in {**BACKEND_RUNTIME_FILES, **TRAFFIC_RUNTIME_FILES}:
            with self.subTest(source=name):
                self.assertEqual([], syntax_errors(parser, (OVERLAY / "cleanroom" / name).read_text(encoding="utf-8")))

    def test_native_fixture_sources_parse(self):
        parser = Parser(Language(tree_sitter_swift.language()))
        for path in (OVERLAY / "tests/backend").glob("*.swift"):
            with self.subTest(source=path.name):
                self.assertEqual([], syntax_errors(parser, path.read_text(encoding="utf-8")))

    def test_transport_uses_original_trust_and_account_bound_signing(self):
        client = (OVERLAY / "cleanroom/WhitegramBackendClient.swift").read_text(encoding="utf-8")
        http = (OVERLAY / "cleanroom/WhitegramBackendHTTP.swift").read_text(encoding="utf-8")
        self.assertIn("sessions.load(userId: userId)", client)
        self.assertIn("sessions.remove(userId: userId, matching: session)", client)
        self.assertIn("access.require(userId: userId, path: path, now: now())", client)
        self.assertIn("SecTrustEvaluateWithError(trust, nil)", http)
        self.assertIn("WhitegramBackendProtocol.spkiPins.contains(digest)", http)
        self.assertIn("try transfer.validateSession()", http)
        self.assertIn("session.uploadTask(with: request, fromFile: file)", http)
        self.assertIn("completionHandler(nil)", http)


@unittest.skipUnless(os.environ.get("WHITEGRAM_ASSEMBLED_SOURCE"), "Set WHITEGRAM_ASSEMBLED_SOURCE to the ready reference")
class BackendCompositionTests(unittest.TestCase):
    def setUp(self):
        self.root = Path(os.environ["WHITEGRAM_ASSEMBLED_SOURCE"])

    def test_lifecycle_and_traffic_compose_in_both_orders_and_replay(self):
        for order in ((backend_patches, traffic_patches), (traffic_patches, backend_patches)):
            with self.subTest(order=[patch.__name__ for patch in order]):
                staged = SourcePatches(self.root)
                for patch in order:
                    patch(staged)
                expected = dict(staged.pending)
                for patch in order:
                    patch(staged)
                self.assertEqual(expected, staged.pending)
                self.assertEqual(1, staged.pending[APP_DELEGATE].count("whitegramInstallBackend()"))
                self.assertEqual(1, staged.pending[APP_DELEGATE].count("whitegramInstallTraffic()"))
                self.assertEqual(1, staged.pending[APP_DELEGATE].count("whitegramRegisterBackendAccount(userId: context.account.peerId.id._internalGetInt64Value())"))
                self.assertEqual(2, staged.pending[SENT_MESSAGES].count("WhitegramBackendMessageBridge.record("))
                self.assertEqual(1, staged.pending[STATE_MANAGER].count("WhitegramBackendMessageBridge.record("))
                for relative, original in staged.original.items():
                    self.assertEqual(original, (self.root / relative).read_text(encoding="utf-8"))

    def test_staged_swift_has_no_new_syntax_errors(self):
        staged = SourcePatches(self.root)
        backend_patches(staged)
        traffic_patches(staged)
        parser = Parser(Language(tree_sitter_swift.language()))
        for relative, text in staged.pending.items():
            with self.subTest(source=relative):
                # Existing upstream grammar errors may move when lines are inserted.
                normalized = lambda text: [(kind, snippet) for kind, _, snippet in syntax_errors(parser, text)]
                self.assertEqual(normalized(staged.original[relative]), normalized(text))

    def test_ambiguous_lifecycle_anchor_is_rejected(self):
        staged = SourcePatches(self.root)
        text = staged.read(APP_DELEGATE)
        staged.pending[APP_DELEGATE] = text + "\n        whitegramInstallBackend()\n        whitegramInstallBackend()\n"
        with self.assertRaisesRegex(ValueError, "ambiguous"):
            backend_patches(staged)


if __name__ == "__main__":
    unittest.main()
