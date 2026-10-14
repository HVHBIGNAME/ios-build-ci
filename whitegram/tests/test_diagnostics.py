"""Diagnostic receiver, privacy contract, native source and installation checks."""

import copy
import json
import os
from pathlib import Path
import subprocess
import sys
import tempfile
import threading
import unittest
import urllib.error
import urllib.request
import uuid
from unittest.mock import patch
from http.server import ThreadingHTTPServer

ROOT = Path(__file__).resolve().parents[1]
sys.path.insert(0, str(ROOT))
from diagnostics.receiver import Inbox, handler, validate_report, fingerprint
from diagnostics_patches import APP, DIAGNOSTICS_RUNTIME_FILES, apply_diagnostics_patches
from test_history_patches import MemoryRoot, PIN, parse_sources


def report():
    return {"schema": 1, "id": str(uuid.uuid4()).upper(), "timestamp": 1791936000, "version": "12.9.4", "build": "34639",
            "revision": "a" * 40, "os": "26.0.1", "kind": "test", "component": "app", "code": 0, "frames": []}


class ReceiverTests(unittest.TestCase):
    def setUp(self):
        self.temporary = tempfile.TemporaryDirectory(prefix="whitegram-diagnostics-test-")
        self.addCleanup(self.temporary.cleanup)
        self.inbox = Inbox(Path(self.temporary.name) / "inbox.sqlite3", "example/private")
        self.addCleanup(self.inbox.db.close)

    def test_schema_rejects_extra_sensitive_fields_and_wrong_types(self):
        self.assertEqual(validate_report(report())["kind"], "test")
        for key, value in (("message", "secret chat"), ("url", "https://secret"), ("code", True), ("component", []), ("frames", ["secret"]), ("version", "token")):
            invalid = report()
            invalid[key] = value
            with self.subTest(key=key), self.assertRaises((ValueError, TypeError)):
                validate_report(invalid)

    def test_retry_is_idempotent_and_errors_group_into_one_issue(self):
        first = report()
        self.inbox.accept(first)
        self.inbox.accept(first)
        other = copy.deepcopy(first)
        other["id"] = str(uuid.uuid4()).upper()
        self.inbox.accept(other)
        self.assertEqual(fingerprint(first), fingerprint(other))
        with patch("diagnostics.receiver.github", side_effect=[[], {"number": 4}]) as github:
            self.assertTrue(self.inbox.deliver_one())
            self.assertTrue(self.inbox.deliver_one())
            self.assertFalse(self.inbox.deliver_one())
            self.assertEqual(github.call_count, 2)
        self.assertEqual(self.inbox.db.execute("SELECT COUNT(*) FROM reports").fetchone()[0], 2)
        first["code"] = 7
        with self.assertRaises(ValueError):
            self.inbox.accept(first)

    def test_github_outage_preserves_pending_reports(self):
        self.inbox.accept(report())
        with patch("diagnostics.receiver.github", side_effect=RuntimeError("offline")), self.assertRaises(RuntimeError):
            self.inbox.deliver_one()
        self.assertEqual(self.inbox.db.execute("SELECT delivered FROM reports").fetchone()[0], 0)

    def test_http_requires_auth_and_only_acknowledges_persisted_reports(self):
        server = ThreadingHTTPServer(("127.0.0.1", 0), handler(self.inbox, "a" * 64, "test"))
        worker = threading.Thread(target=server.serve_forever, daemon=True)
        worker.start()
        self.addCleanup(server.server_close)
        self.addCleanup(server.shutdown)
        url = f"http://127.0.0.1:{server.server_port}/v1/reports"
        value = report()
        request = urllib.request.Request(url, data=json.dumps(value).encode(), headers={"Content-Type": "application/json"})
        with self.assertRaises(urllib.error.HTTPError) as failure:
            urllib.request.urlopen(request, timeout=3)
        self.assertEqual(failure.exception.code, 401)
        request.add_header("Authorization", "Bearer " + "a" * 64)
        with urllib.request.urlopen(request, timeout=3) as response:
            self.assertEqual(json.load(response), {"accepted": True, "id": value["id"]})
        self.assertEqual(self.inbox.db.execute("SELECT COUNT(*) FROM reports").fetchone()[0], 1)


class DiagnosticSourceTests(unittest.TestCase):
    def test_production_and_native_sources_parse(self):
        paths = [ROOT / "cleanroom" / name for name in DIAGNOSTICS_RUNTIME_FILES]
        paths.append(ROOT / "tests/diagnostics/DiagnosticsTests.swift")
        for name, errors in parse_sources({str(path): path.read_text(encoding="utf-8") for path in paths}).items():
            self.assertEqual(errors, [], name)

    @unittest.skipUnless(os.environ.get("WHITEGRAM_ASSEMBLED_SOURCE"), "Set WHITEGRAM_ASSEMBLED_SOURCE")
    def test_startup_installs_and_replays_before_ui_without_writes(self):
        root = os.environ["WHITEGRAM_ASSEMBLED_SOURCE"]
        source = subprocess.check_output(["git", "-C", root, "show", f"{PIN}:{APP}"]).decode()
        memory = MemoryRoot({APP: source})
        apply_diagnostics_patches(memory)
        first = memory.text(APP)
        memory.writes.clear()
        apply_diagnostics_patches(memory)
        self.assertEqual(memory.text(APP), first)
        self.assertEqual(memory.writes, [])
        self.assertLess(first.index("WhitegramDiagnosticsLifecycle.shared.start()"), first.index("defaultNavigationBarImpl ="))


if __name__ == "__main__":
    unittest.main()
