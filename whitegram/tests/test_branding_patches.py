"""Verify original logo resources and composition with the target intro renderer."""

import hashlib
import os
from pathlib import Path
import shutil
import tempfile
import unittest
from unittest.mock import patch

from test_history_patches import MemoryRoot
from branding_patches import (
    ANIMATION, DESTINATIONS, INTRO, LOGO_FILES, RESOURCES, SETTINGS, TEXTURE,
    apply_branding_patches, install_intro_logo,
)


class IntroResourceTests(unittest.TestCase):
    def setUp(self):
        temporary = tempfile.TemporaryDirectory(prefix="whitegram-intro-")
        self.addCleanup(temporary.cleanup)
        self.root = Path(temporary.name)
        for relative in DESTINATIONS:
            destination = self.root / relative
            destination.mkdir(parents=True)
            (destination / "telegram_sphere@2x.png").write_bytes(b"old public logo")
            (destination / "other.png").write_bytes(b"unrelated intro artwork")

    def test_installs_exact_original_2x_3x_and_empty_plane_in_both_locations(self):
        install_intro_logo(self.root)
        for relative in DESTINATIONS:
            destination = self.root / relative
            for name, digest in LOGO_FILES.items():
                self.assertEqual(hashlib.sha256((destination / name).read_bytes()).hexdigest(), digest)
            self.assertEqual((destination / "other.png").read_bytes(), b"unrelated intro artwork")
        with patch.object(Path, "write_bytes", side_effect=AssertionError("Replay wrote a resource")):
            install_intro_logo(self.root)

    def test_corrupt_resource_fails_before_replacing_existing_artwork(self):
        resources = self.root / "resources"
        shutil.copytree(RESOURCES, resources)
        (resources / "telegram_plane1@2x.png").write_bytes(b"damaged PNG")
        with patch.object(Path, "write_bytes", side_effect=AssertionError("Partial resource installation")):
            with self.assertRaisesRegex(ValueError, "Original welcome artwork changed"):
                install_intro_logo(self.root, resources)

    @unittest.skipUnless(os.name == "posix", "POSIX root aliases such as macOS /var")
    def test_root_alias_resolves_before_validating_destination_paths(self):
        alias = self.root / "source-alias"
        alias.symlink_to(self.root, target_is_directory=True)
        install_intro_logo(alias)
        for relative in DESTINATIONS:
            for name, digest in LOGO_FILES.items():
                self.assertEqual(hashlib.sha256((self.root / relative / name).read_bytes()).hexdigest(), digest)

    def test_invalid_second_destination_does_not_modify_first(self):
        shutil.rmtree(self.root / DESTINATIONS[1])
        with patch.object(Path, "write_bytes", side_effect=AssertionError("Partial destination installation")):
            with self.assertRaisesRegex(ValueError, "Invalid intro resource destination"):
                install_intro_logo(self.root)


@unittest.skipUnless(os.environ.get("WHITEGRAM_ASSEMBLED_SOURCE"), "Set WHITEGRAM_ASSEMBLED_SOURCE")
class BrandingIntegrationTests(unittest.TestCase):
    def root(self):
        source = Path(os.environ["WHITEGRAM_ASSEMBLED_SOURCE"])
        return MemoryRoot({path: (source / path).read_text(encoding="utf-8")
                           for path in (INTRO, TEXTURE, ANIMATION, SETTINGS)})

    def test_installs_and_replays_without_modifying_unrelated_renderer_code(self):
        root = self.root()
        before = root.texts()
        report = apply_branding_patches(root)
        self.assertEqual({path for paths in report.values() for path in paths}, {INTRO, TEXTURE, ANIMATION, SETTINGS})
        self.assertIn('setup_texture(@"telegram_sphere.png", _primaryColor)', root.text(INTRO))
        self.assertIn('_glkView.hidden = _currentPage == 0;', root.text(INTRO))
        self.assertIn('_simulatorLogoView.hidden = _currentPage != 0;', root.text(INTRO))
        self.assertIn('set_ic_textures(', root.text(INTRO))
        self.assertIn('CGContextClipToMask(spriteContext, CGRectMake(0, 0, width, height), spriteImage)', root.text(TEXTURE))
        self.assertIn('} else {\n        CGContextDrawImage(spriteContext, CGRectMake(0, 0, width, height), spriteImage);', root.text(TEXTURE))
        details = root.text(ANIMATION).split('// LAYER4 - DETAILS', 1)[1].split('else if (current_page==1)', 1)[0]
        self.assertEqual(details.count('draw_textured_shape(&telegram_sphere, main_matrix, NORMAL);'), 2)
        self.assertIn('if (direct == 1)', details)
        self.assertIn('if (direct == 0)', details)
        self.assertIn('UIImage(bundleImageName: "WhitegramPrimaryPreview")', root.text(SETTINGS))
        first = root.texts()
        root.writes.clear()
        self.assertEqual(apply_branding_patches(root), report)
        self.assertEqual(root.writes, [])
        self.assertEqual(root.texts(), first)

    def test_arm_simulator_uses_original_theme_aware_artwork_and_view_lifecycle(self):
        root = self.root()
        apply_branding_patches(root)
        intro = root.text(INTRO)
        simulator = intro.split('#if TARGET_OS_SIMULATOR && defined(__aarch64__)', 1)[1].split('#endif', 1)[0]
        self.assertIn('if (_simulatorLogoView == nil)', simulator)
        self.assertIn('imageNamed:@"telegram_sphere.png"', simulator)
        self.assertIn('UIImageRenderingModeAlwaysTemplate', simulator)
        self.assertIn('imageView.tintColor = _primaryColor;', simulator)
        self.assertIn('imageView.contentMode = UIViewContentModeScaleAspectFit;', simulator)
        self.assertIn('[self.view insertSubview:_simulatorLogoView atIndex:0];', simulator)
        self.assertEqual(intro.count('UIView *logoView = _simulatorLogoView ?: _glkView;'), 2)
        self.assertIn('snapshot.frame = _simulatorLogoView.frame;', intro)
        cleanup = intro.split('- (void)freeGL', 1)[1].split('- (void)loadView', 1)[0]
        self.assertLess(cleanup.index('[_simulatorLogoView removeFromSuperview];'), cleanup.index('if (!_isOpenGLLoaded)'))
        self.assertIn('_simulatorLogoView = nil;', cleanup)

    def test_device_first_page_uses_uikit_without_gl_layers_and_keeps_other_pages(self):
        root = self.root()
        apply_branding_patches(root)
        intro = root.text(INTRO)
        device = intro.split('#if !(TARGET_OS_SIMULATOR && defined(__aarch64__))', 1)[1].split('- (void)freeGL', 1)[0]
        self.assertIn('UIImageRenderingModeAlwaysTemplate', device)
        self.assertIn('imageView.tintColor = _primaryColor;', device)
        self.assertIn('_glkView.hidden = _currentPage == 0;', device)
        self.assertIn('if (_glkView != nil)', intro.split('- (void)scrollViewDidScroll:', 1)[1])
        self.assertIn('(_glkView == nil || _currentPage == 0)', intro)
        self.assertIn('postNotificationName:@"WhitegramLoginDiagnostics.export"', intro)

    def test_missing_last_anchor_does_not_partially_patch_the_intro(self):
        root = self.root()
        root.files[SETTINGS] = b"changed settings icon implementation"
        before = root.texts()
        with self.assertRaises(ValueError):
            apply_branding_patches(root)
        self.assertEqual(root.texts(), before)
        self.assertEqual(root.writes, [])


if __name__ == "__main__":
    unittest.main()
