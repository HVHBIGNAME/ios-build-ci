"""Original Whitegram welcome artwork and theme-aware in-app branding."""

import hashlib
from pathlib import Path

from source_patches import SourcePatches


RESOURCES = Path(__file__).resolve().parent / "resources/intro-logo"
INTRO = "submodules/RMIntro/Sources/platform/ios/RMIntroViewController.m"
TEXTURE = "submodules/RMIntro/Sources/platform/ios/texture_helper.m"
ANIMATION = "submodules/RMIntro/Sources/core/animations.c"
SETTINGS = "submodules/TelegramPresentationData/Sources/Resources/PresentationResourcesSettings.swift"
DESTINATIONS = (
    "Telegram/Telegram-iOS/Resources/intro",
    "submodules/RMIntro/Sources/platform/ios/Resources",
)
LOGO_FILES = {
    "telegram_sphere@2x.png": "381aba0fa7ff1404da7e4070e1fc9594c5ce655deb43f4888af0c0b01cfc2e82",
    "telegram_sphere@3x.png": "fcf14937842b38a7af8f50ff5588e5f44758f2f7caf8ad665e6c17101a7080b5",
    "telegram_plane1@2x.png": "18c656511c8c5afdb1d6fce72f35fc8ca2a34ccf239e92af9b940b810b88d6d4",
}


def patch_simulator_intro(patches: SourcePatches) -> None:
    feature = "welcome-logo-simulator"
    patches.replace(feature, INTRO, '    UIView *_wrapperView;',
                    '    UIView *_simulatorLogoView;\n    UIView *_wrapperView;')
    patches.replace(
        feature, INTRO,
        '#if TARGET_OS_SIMULATOR && defined(__aarch64__)\n    return;\n#endif',
        '#if TARGET_OS_SIMULATOR && defined(__aarch64__)\n'
        '    if (_simulatorLogoView == nil) {\n'
        '        CGFloat size = ([UIDevice currentDevice].userInterfaceIdiom == UIUserInterfaceIdiomPad) ? 240.0 : 200.0;\n'
        '        _simulatorLogoView = [[UIView alloc] initWithFrame:CGRectMake((self.view.bounds.size.width - size) / 2.0, 50.0, size, size)];\n'
        '        _simulatorLogoView.autoresizingMask = UIViewAutoresizingFlexibleLeftMargin | UIViewAutoresizingFlexibleRightMargin;\n'
        '        _simulatorLogoView.userInteractionEnabled = false;\n'
        '        UIImage *image = [[UIImage imageNamed:@"telegram_sphere.png"] imageWithRenderingMode:UIImageRenderingModeAlwaysTemplate];\n'
        '        UIImageView *imageView = [[UIImageView alloc] initWithImage:image];\n'
        '        CGFloat padding = size * (26.0 / 200.0);\n'
        '        imageView.frame = CGRectInset(_simulatorLogoView.bounds, padding, padding);\n'
        '        imageView.contentMode = UIViewContentModeScaleAspectFit;\n'
        '        imageView.tintColor = _primaryColor;\n'
        '        [_simulatorLogoView addSubview:imageView];\n'
        '        [self.view insertSubview:_simulatorLogoView atIndex:0];\n'
        '    }\n'
        '    return;\n#endif',
    )
    patches.replace(feature, INTRO, '- (void)animateIn {',
                    '- (void)animateIn {\n    UIView *logoView = _simulatorLogoView ?: _glkView;')
    for property_name, count in (("center", 3), ("transform", 2), ("alpha", 2)):
        patches.replace(feature, INTRO, f"_glkView.{property_name}", f"logoView.{property_name}", count=count)
    patches.replace(
        feature, INTRO,
        '    _glkView.frame = CGRectChangedOriginY(_glkView.frame, glViewY - statusBarHeight);',
        '    UIView *logoView = _simulatorLogoView ?: _glkView;\n'
        '    logoView.frame = CGRectChangedOriginY(logoView.frame, glViewY - statusBarHeight);',
    )
    patches.replace(
        feature, INTRO,
        '- (UIView *)createAnimationSnapshot {\n    UIImage *image = _glkView.snapshot;',
        '- (UIView *)createAnimationSnapshot {\n'
        '    if (_simulatorLogoView != nil && (_glkView == nil || _currentPage == 0)) {\n'
        '        UIView *snapshot = [_simulatorLogoView snapshotViewAfterScreenUpdates:false];\n'
        '        snapshot.frame = _simulatorLogoView.frame;\n'
        '        return snapshot;\n'
        '    }\n'
        '    UIImage *image = _glkView.snapshot;',
    )
    patches.replace(
        feature, INTRO,
        '- (void)freeGL\n{\n    if (!_isOpenGLLoaded)',
        '- (void)freeGL\n{\n'
        '    [_simulatorLogoView removeFromSuperview];\n'
        '    _simulatorLogoView = nil;\n'
        '    if (!_isOpenGLLoaded)',
    )


def patch_device_intro(patches: SourcePatches) -> None:
    feature = "welcome-logo-device"
    anchor = '    if (/*[[UIApplication sharedApplication] applicationState] != UIApplicationStateBackground*/true && !_isOpenGLLoaded)'
    patches.replace(feature, INTRO, anchor, '''#if !(TARGET_OS_SIMULATOR && defined(__aarch64__))
    if (_simulatorLogoView == nil) {
        CGFloat size = ([UIDevice currentDevice].userInterfaceIdiom == UIUserInterfaceIdiomPad) ? 240.0 : 200.0;
        _simulatorLogoView = [[UIView alloc] initWithFrame:CGRectMake((self.view.bounds.size.width - size) / 2.0, 50.0, size, size)];
        _simulatorLogoView.autoresizingMask = UIViewAutoresizingFlexibleLeftMargin | UIViewAutoresizingFlexibleRightMargin;
        _simulatorLogoView.userInteractionEnabled = false;
        UIImageView *imageView = [[UIImageView alloc] initWithImage:[[UIImage imageNamed:@"telegram_sphere.png"] imageWithRenderingMode:UIImageRenderingModeAlwaysTemplate]];
        CGFloat padding = size * (26.0 / 200.0);
        imageView.frame = CGRectInset(_simulatorLogoView.bounds, padding, padding);
        imageView.contentMode = UIViewContentModeScaleAspectFit;
        imageView.tintColor = _primaryColor;
        [_simulatorLogoView addSubview:imageView];
        [self.view insertSubview:_simulatorLogoView atIndex:0];
    }
    _simulatorLogoView.hidden = _currentPage != 0;
#endif
''' + anchor)
    patches.replace(feature, INTRO, '        [self.view addSubview:_glkView];',
                    '        [self.view addSubview:_glkView];\n        _glkView.hidden = _currentPage == 0;')
    anchor = '    logoView.frame = CGRectChangedOriginY(logoView.frame, glViewY - statusBarHeight);'
    patches.replace(feature, INTRO, anchor, anchor + '\n    if (_glkView != nil && _simulatorLogoView != nil) {\n        _glkView.frame = _simulatorLogoView.frame;\n    }')
    anchor = '    [_pageControl setCurrentPage:_currentPage];'
    patches.replace(feature, INTRO, anchor, anchor + '\n    if (_glkView != nil) {\n        _glkView.hidden = _currentPage == 0;\n        _simulatorLogoView.hidden = _currentPage != 0;\n    }')
    anchor = '- (void)startButtonPress\n{'
    patches.replace(feature, INTRO, anchor, '''- (void)exportWhitegramLoginDiagnostics:(UILongPressGestureRecognizer *)recognizer {
    if (recognizer.state == UIGestureRecognizerStateBegan) {
        [[NSNotificationCenter defaultCenter] postNotificationName:@"WhitegramLoginDiagnostics.export" object:nil];
    }
}

''' + anchor)
    anchor = '    self.view.backgroundColor = _backgroundColor;'
    patches.replace(feature, INTRO, anchor, anchor + '''
    UILongPressGestureRecognizer *diagnosticsGesture = [[UILongPressGestureRecognizer alloc] initWithTarget:self action:@selector(exportWhitegramLoginDiagnostics:)];
    diagnosticsGesture.minimumPressDuration = 2.0;
    diagnosticsGesture.cancelsTouchesInView = false;
    [self.view addGestureRecognizer:diagnosticsGesture];''')


def apply_branding_patches(root: Path) -> dict[str, list[str]]:
    patches = SourcePatches(root)
    patch_simulator_intro(patches)
    patch_device_intro(patches)
    patches.replace(
        "welcome-logo-color", INTRO,
        'set_telegram_textures(setup_texture(@"telegram_sphere.png", color),',
        'set_telegram_textures(setup_texture(@"telegram_sphere.png", _primaryColor),',
    )
    patches.replace(
        "welcome-logo-mask", TEXTURE,
        '    if ([fileName isEqualToString:@"telegram_sphere.png"]) {\n'
        '        CGContextSetFillColorWithColor(spriteContext, color.CGColor);\n'
        '        CGContextFillRect(spriteContext, CGRectMake(0, 0, width, height));\n'
        '    }\n'
        '    CGContextDrawImage(spriteContext, CGRectMake(0, 0, width, height), spriteImage);',
        '    if ([fileName isEqualToString:@"telegram_sphere.png"]) {\n'
        '        CGContextClipToMask(spriteContext, CGRectMake(0, 0, width, height), spriteImage);\n'
        '        CGContextSetFillColorWithColor(spriteContext, color.CGColor);\n'
        '        CGContextFillRect(spriteContext, CGRectMake(0, 0, width, height));\n'
        '    } else {\n'
        '        CGContextDrawImage(spriteContext, CGRectMake(0, 0, width, height), spriteImage);\n'
        '    }',
    )
    anchor = '    if (current_page == 0)\n    {\n        rglNormalDraw();\n'
    returning = '\n        if (direct == 0) {\n\n            telegram_sphere.params.alpha = t(0, 1, 0, duration_const*.8, Linear);'
    patches.replace(
        "welcome-logo-first-frame", ANIMATION, anchor + returning,
        anchor + '\n        if (direct == 1) {\n'
        '            telegram_sphere.params.alpha = 1;\n'
        '            telegram_sphere.params.scale = xyzMake(1, 1, 1);\n'
        '            draw_textured_shape(&telegram_sphere, main_matrix, NORMAL);\n'
        '        }\n' + returning,
    )
    patches.replace(
        "settings-whitegram-logo", SETTINGS,
        'UIImage(bundleImageName: "Item List/Icons/WhiteGram")',
        'UIImage(bundleImageName: "WhitegramPrimaryPreview")',
    )
    return patches.write()


def install_intro_logo(root: Path, resources: Path = RESOURCES) -> None:
    root = Path(root).resolve(strict=True)
    payloads = {}
    for name, digest in LOGO_FILES.items():
        data = (resources / name).read_bytes()
        if hashlib.sha256(data).hexdigest() != digest:
            raise ValueError(f"Original welcome artwork changed: {name}")
        payloads[name] = data
    destinations = [root / path for path in DESTINATIONS]
    for destination in destinations:
        if not destination.is_dir() or destination.resolve() != destination.absolute():
            raise ValueError(f"Invalid intro resource destination: {destination}")
        for name in payloads:
            if (destination / name).is_symlink():
                raise ValueError(f"Intro resource must not be a symlink: {name}")
    for destination in destinations:
        for name, data in payloads.items():
            path = destination / name
            if not path.exists() or path.read_bytes() != data:
                path.write_bytes(data)
