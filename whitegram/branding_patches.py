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


def apply_branding_patches(root: Path) -> dict[str, list[str]]:
    patches = SourcePatches(root)
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
