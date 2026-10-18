import sys
from pathlib import Path
import unittest
from unittest.mock import patch

sys.path.insert(0, str(Path(__file__).resolve().parents[1]))
from check_upstream import compare_tags, notify


class UpstreamMonitorTests(unittest.TestCase):
    def setUp(self):
        self.config = {"repository": "TelegramMessenger/Telegram-iOS", "source_tag": "release-12.9.2", "source_sha": "a" * 40}
        self.tags = [{"name": "release-12.9.2", "commit": {"sha": "a" * 40}}]

    def test_semantic_sort_ignores_prereleases_and_response_order(self):
        tags = [*self.tags, {"name": "release-13.0.0", "commit": {"sha": "b" * 40}},
                {"name": "release-14.0-beta", "commit": {"sha": "c" * 40}},
                {"name": "release-12.10", "commit": {"sha": "d" * 40}}]
        report = compare_tags(self.config, tags)
        self.assertEqual(report["latest_tag"], "release-13.0.0")
        self.assertTrue(report["update_available"])
        self.assertFalse(report["pinned_tag_moved"])

    def test_equal_versions_do_not_propose_an_update(self):
        self.assertFalse(compare_tags(self.config, self.tags)["attention_required"])

    def test_changed_pin_is_reported_even_without_newer_version(self):
        self.tags[0]["commit"]["sha"] = "b" * 40
        self.assertTrue(compare_tags(self.config, self.tags)["pinned_tag_moved"])

    def test_absent_and_malformed_sources_fail(self):
        for tags in ([], [{"name": "release-13.0.0", "commit": {"sha": "b" * 40}}],
                     [{"name": "release-12.9.2", "commit": {"sha": "invalid"}}]):
            with self.assertRaises(ValueError):
                compare_tags(self.config, tags)
        with self.assertRaises(ValueError):
            compare_tags({**self.config, "repository": "unofficial/mirror"}, self.tags)

    def test_existing_issue_prevents_repeat_notifications(self):
        self.tags.append({"name": "release-13.0.0", "commit": {"sha": "b" * 40}})
        report = compare_tags(self.config, self.tags)
        with patch("check_upstream.gh_json", return_value=[{"title": "[Telegram upstream] release-13.0.0", "url": "https://github.com/test/repo/issues/1"}]), \
                patch("check_upstream.subprocess.check_output") as create:
            self.assertEqual(notify(report, "test/repo"), "https://github.com/test/repo/issues/1")
            create.assert_not_called()


if __name__ == "__main__":
    unittest.main()
