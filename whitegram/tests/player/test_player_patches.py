"""Apply real SourcePatches to a memory copy; never write either reference tree."""
import os
from pathlib import Path
import re
import sys
import unittest

WHITEGRAM = Path(__file__).resolve().parents[2]
sys.path.insert(0, str(WHITEGRAM))
sys.path.insert(0, str(WHITEGRAM / "tests" / "voice"))
import player_patches as player
import test_voice_patches as voice_tests
from test_voice_patches import MemoryRoot, Parser


SOURCE = os.environ.get("WHITEGRAM_PLAYER_SOURCE")
PATHS = (player.PLAYER, player.RENDERER, player.SHARED, player.OVERLAY, player.PROFILE)


class PlayerManifestTests(unittest.TestCase):
    def test_every_owned_runtime_has_an_install_destination(self):
        sources = {path.name for path in (WHITEGRAM / "cleanroom").glob("WhitegramPlayer*.swift")}
        self.assertEqual(sources, set(player.PLAYER_RUNTIME_FILES))
        self.assertEqual(len(set(player.PLAYER_RUNTIME_FILES.values())), len(sources))


@unittest.skipUnless(SOURCE, "Set WHITEGRAM_PLAYER_SOURCE to the read-only assembled source")
class PlayerPatchTests(unittest.TestCase):
    def setUp(self):
        self.source = Path(SOURCE)
        self.originals = {path: (self.source / path).read_bytes() for path in PATHS}
        self.root = MemoryRoot(dict(self.originals))

    def test_idempotent_patch_and_originals_untouched(self):
        report = player.apply_player_patches(self.root)
        self.assertEqual({path for paths in report.values() for path in paths}, set(PATHS))
        changed = {path for path in PATHS if self.originals[path] != self.root.files[path]}
        self.assertEqual(set(self.root.writes), changed)
        first = dict(self.root.files)
        self.root.writes.clear()
        self.assertEqual(player.apply_player_patches(self.root), report)
        self.assertEqual(self.root.files, first)
        self.assertEqual(self.root.writes, [])
        for path in PATHS:
            self.assertEqual((self.source / path).read_bytes(), self.originals[path])

    def test_late_anchor_failure_prevents_all_writes(self):
        self.root.change(player.SHARED, "    func stop() {", "    func stopAfterDrift() {")
        before = dict(self.root.files)
        with self.assertRaisesRegex(ValueError, "expected 1 anchors"):
            player.apply_player_patches(self.root)
        self.assertEqual(self.root.files, before)
        self.assertEqual(self.root.writes, [])

    def test_music_flag_reaches_both_renderer_creation_paths(self):
        player.apply_player_patches(self.root)
        self.assertEqual(self.root.text(player.PLAYER).count("isForMusicPlayback: self.isForMusicPlayback"), 2)
        renderer = self.root.text(player.RENDERER)
        self.assertIn("self.isForMusicPlayback ? kAudioUnitSubType_NewTimePitch", renderer)
        self.assertLess(renderer.index("configureEqualizer(equalizerAudioUnit"), renderer.index("guard AUGraphInitialize"))
        self.assertNotIn("WhitegramPreferences", renderer[renderer.index("private func rendererInputProc"):renderer.index("private struct RequestingFramesContext")])

    def test_pitch_graph_keeps_both_units_until_close_and_disposes_failed_setup(self):
        player.apply_player_patches(self.root)
        renderer = self.root.text(player.RENDERER)
        self.assertIn("timePitchNode, 0, whitegramVarispeedNode, 0", renderer)
        self.assertIn("whitegramVarispeedNode, 0, mixerNode, 0", renderer)
        self.assertLess(renderer.index("guard AUGraphInitialize"), renderer.index("self.whitegramVarispeedAudioUnit = whitegramVarispeed"))
        self.assertIn("if !whitegramGraphInstalled { DisposeAUGraph(audioGraph) }", renderer)
        self.assertIn("self.whitegramVarispeedAudioUnit = nil", renderer)
        self.assertEqual(len(re.findall(r"^\s+renderer\.setVolume\(self\.whitegramVolume\)$", self.root.text(player.PLAYER), re.MULTILINE)), 2)

    def test_bass_sample_format_drift_aborts_all_files(self):
        for before, after in (("mSampleRate = 44100.00", "mSampleRate = 48000.00"),
                              ("mChannelsPerFrame = 2", "mChannelsPerFrame = 1"),
                              ("mBytesPerFrame = 2 * 2", "mBytesPerFrame = 4 * 2"),
                              ("kAudioFormatFlagIsSignedInteger", "kAudioFormatFlagIsFloat")):
            with self.subTest(change=before):
                root = MemoryRoot(dict(self.originals))
                root.change(player.RENDERER, before, after)
                original = dict(root.files)
                with self.assertRaisesRegex(ValueError, "unexpected renderer PCM format"):
                    player.apply_player_patches(root)
                self.assertEqual(root.files, original)
                self.assertEqual(root.writes, [])

    def test_profile_card_preserves_native_saved_music_action_and_disabled_layout(self):
        player.apply_player_patches(self.root)
        profile = self.root.text(player.PROFILE)
        self.assertIn("whitegramCustomMusicCard ? 52.0 : (hasBackground || self.isAvatarExpanded ? 24.0 : 16.0)", profile)
        self.assertEqual(profile.count("self?.displaySavedMusic?()"), self.originals[player.PROFILE].decode().count("self?.displaySavedMusic?()"))
        self.assertIn("self.whitegramMusicCard?.removeFromSuperview()", profile)
        card = (WHITEGRAM / "cleanroom/WhitegramPlayerProfileCard.swift").read_text(encoding="utf-8")
        self.assertIn("self.isUserInteractionEnabled = false", card)
        self.assertIn("!UIAccessibility.isReduceMotionEnabled", card)

    def test_runtime_imports_and_convenience_initializer_dependencies(self):
        sdk = {"Foundation", "CoreFoundation", "UIKit", "QuartzCore", "AudioToolbox"}
        for filename, destination in player.PLAYER_RUNTIME_FILES.items():
            code = (WHITEGRAM / "cleanroom" / filename).read_text(encoding="utf-8")
            parent = (self.source / destination).parent
            while not (parent / "BUILD").is_file() and parent != self.source:
                parent = parent.parent
            build = (parent / "BUILD").read_text(encoding="utf-8")
            for dependency in set(re.findall(r"^import (\w+)$", code, re.MULTILINE)) - sdk:
                self.assertRegex(build, r'//[^"\n]*(?:/|:)' + re.escape(dependency) + '"', filename)
            if "ItemListController(context:" in code:
                self.assertIn("import PresentationDataUtils\n", code)

    def test_transition_retains_outgoing_player_and_observes_real_playback(self):
        player.apply_player_patches(self.root)
        shared = self.root.text(player.SHARED)
        self.assertIn("player !== strongSelf.whitegramOutgoing", shared)
        self.assertIn("self.whitegramOutgoing = player", shared)
        self.assertIn("state.order == .regular ? state.previousItem : state.nextItem", shared)
        self.assertIn("strongSelf.whitegramPlaybackGeneration == whitegramGeneration", shared)
        self.assertNotIn("strongSelf.playbackItem == playbackItem", shared)
        crossfade = (WHITEGRAM / "cleanroom" / "WhitegramPlayerCrossfade.swift").read_text(encoding="utf-8")
        self.assertIn("case .playing:", crossfade)
        self.assertIn("self.outgoing?.setVolume(gains.outgoing)", crossfade)
        self.assertIn("self.incoming?.setVolume(gains.incoming)", crossfade)

    @unittest.skipIf(Parser is None, "Swift tree-sitter parser unavailable")
    def test_runtime_and_all_patched_sources_parse(self):
        player.apply_player_patches(self.root)
        checker = voice_tests.VoiceSwiftSyntaxTests()
        for path in PATHS:
            checker.assert_parses(path, self.root.files[path])
        for filename in player.PLAYER_RUNTIME_FILES:
            checker.assert_parses(filename, (WHITEGRAM / "cleanroom" / filename).read_bytes())
        checker.assert_parses("WhitegramPlayerTests.swift", Path(__file__).with_name("WhitegramPlayerTests.swift").read_bytes())


if __name__ == "__main__":
    unittest.main()
