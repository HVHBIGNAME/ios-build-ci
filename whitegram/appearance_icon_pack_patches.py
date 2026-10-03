"""Bundle image/animation overrides for recovered local .wgicons packages."""

from pathlib import Path
import re

from source_patches import SourcePatches
from appearance_parity_patches import replace


APPEARANCE_ICON_PACK_RUNTIME_FILES = {
    "WhitegramIconPackArchive.swift": "submodules/SettingsUI/Sources/WhitegramIconPackArchive.swift",
    "WhitegramIconPackManager.swift": "submodules/SettingsUI/Sources/WhitegramIconPackManager.swift",
    "WhitegramIconPacksController.swift": "submodules/SettingsUI/Sources/WhitegramIconPacksController.swift",
    "WhitegramIconPackPresentationCache.swift": "submodules/TelegramPresentationData/Sources/WhitegramIconPackPresentationCache.swift",
}

HEADER = "submodules/AppBundle/PublicHeaders/AppBundle/AppBundle.h"
IMPLEMENTATION = "submodules/AppBundle/Sources/AppBundle/AppBundle.m"
ROOT = "submodules/TelegramUI/Sources/TelegramRootController.swift"
ANIMATION = "submodules/TelegramAnimatedStickerNode/Sources/TelegramAnimatedStickerNode.swift"
MANAGED = "submodules/ManagedAnimationNode/Sources/ManagedAnimationNode.swift"
SETTINGS = "submodules/TelegramPresentationData/Sources/Resources/PresentationResourcesSettings.swift"

DECLARATIONS = """
typedef UIImage * _Nullable (^WGBundleImageOverrideResolver)(NSString * _Nonnull name, UIImage * _Nullable original);
typedef NSString * _Nullable (^WGBundleAnimationOverrideResolver)(NSString * _Nonnull name);
void WGSetBundleImageOverrideResolver(WGBundleImageOverrideResolver _Nullable resolver);
void WGSetBundleAnimationOverrideResolver(WGBundleAnimationOverrideResolver _Nullable resolver);
NSString * _Nullable WGResolveBundleAnimation(NSString * _Nonnull name);
NSUInteger WGBundleOverrideRevision(void);
void WGInvalidateBundleOverrides(void);
"""

PROVIDERS = """
static WGBundleImageOverrideResolver wgImageResolver;
static WGBundleAnimationOverrideResolver wgAnimationResolver;
static NSUInteger wgOverrideRevision = 0;

void WGSetBundleImageOverrideResolver(WGBundleImageOverrideResolver resolver) {
    @synchronized ([UIImage class]) { wgImageResolver = [resolver copy]; wgOverrideRevision++; }
}

void WGSetBundleAnimationOverrideResolver(WGBundleAnimationOverrideResolver resolver) {
    @synchronized ([UIImage class]) { wgAnimationResolver = [resolver copy]; wgOverrideRevision++; }
}

NSUInteger WGBundleOverrideRevision(void) {
    @synchronized ([UIImage class]) { return wgOverrideRevision; }
}

void WGInvalidateBundleOverrides(void) {
    @synchronized ([UIImage class]) { wgOverrideRevision++; }
}

NSString *WGResolveBundleAnimation(NSString *name) {
    WGBundleAnimationOverrideResolver resolver;
    @synchronized ([UIImage class]) { resolver = wgAnimationResolver; }
    return resolver ? resolver(name) : nil;
}
"""


def _settings_images(patches):
    value = patches.read(SETTINGS)
    pattern = re.compile(r"^    public static let (\w+) = (render(?:SettingsIcon|AttachAppIcon)\([^\n]+\))$", re.M)
    matches = list(pattern.finditer(value))
    applied = value.count("WhitegramIconPackPresentationCache.image(")
    if matches and (len(matches) != 89 or applied):
        raise ValueError(f"icon-packs: settings icon inventory changed: {len(matches)} original, {applied} patched")
    if not matches and applied != 92:
        raise ValueError("icon-packs: missing computed settings icon anchors")
    for match in matches:
        name, expression = match.groups()
        replace(patches, "icon-packs-settings-refresh", SETTINGS, match.group(0),
                f'    public static var {name}: UIImage? {{ return WhitegramIconPackPresentationCache.image("{name}") {{ {expression} }} }}')
    for name in ("premium", "stars", "premiumGift"):
        start = f"    public static let {name} = generateImage("
        done = f'    public static var {name}: UIImage? {{ return WhitegramIconPackPresentationCache.image("{name}") {{ generateImage('
        value = patches.read(SETTINGS)
        if value.count(done) == 1 and start not in value:
            patches.features.setdefault("icon-packs-settings-refresh", set()).add(SETTINGS)
            continue
        if value.count(start) != 1:
            raise ValueError(f"icon-packs: missing {name} settings image")
        left = value.index(start)
        right = value.index("\n    })", left) + len("\n    })")
        before = value[left:right]
        after = before.replace(start, done, 1) + " } }"
        replace(patches, "icon-packs-settings-refresh", SETTINGS, before, after)


def apply_appearance_icon_pack_patches(root: Path) -> dict[str, list[str]]:
    patches = SourcePatches(root)
    anchor = "NSBundle * _Nonnull getAppBundle(void);\n"
    replace(patches, "icon-packs-image-resolver", HEADER, anchor, anchor + DECLARATIONS)
    anchor = "@implementation UIImage (AppBundle)\n"
    replace(patches, "icon-packs-image-resolver", IMPLEMENTATION, anchor, PROVIDERS + "\n" + anchor)
    before = "    return [UIImage imageNamed:bundleImageName inBundle:getAppBundle() compatibleWithTraitCollection:nil];\n"
    after = """    UIImage *original = [UIImage imageNamed:bundleImageName inBundle:getAppBundle() compatibleWithTraitCollection:nil];
    WGBundleImageOverrideResolver resolver;
    @synchronized ([UIImage class]) { resolver = wgImageResolver; }
    UIImage *replacement = resolver ? resolver(bundleImageName, original) : nil;
    return replacement ?: original;
"""
    replace(patches, "icon-packs-image-resolver", IMPLEMENTATION, before, after)
    anchor = "    public var path: String? {\n        if let path = getAppBundle().path(forResource: self.name, ofType: \"tgs\") {"
    after = "    public var path: String? {\n        if let path = WGResolveBundleAnimation(self.name) { return path }\n        if let path = getAppBundle().path(forResource: self.name, ofType: \"tgs\") {"
    replace(patches, "icon-packs-animation-resolver", ANIMATION, anchor, after)
    anchor = "            case let .local(name):\n                if let tgsPath = getAppBundle().path(forResource: name, ofType: \"tgs\") {"
    after = "            case let .local(name):\n                if let path = WGResolveBundleAnimation(name) { return path }\n                if let tgsPath = getAppBundle().path(forResource: name, ofType: \"tgs\") {"
    replace(patches, "icon-packs-animation-resolver", MANAGED, anchor, after)
    anchor = "            case let .local(name):\n                return name\n"
    after = '            case let .local(name):\n                return name + ":wg:" + String(WGBundleOverrideRevision())\n'
    replace(patches, "icon-packs-animation-resolver", MANAGED, anchor, after)
    anchor = "        super.init(mode: .automaticMasterDetail, theme: NavigationControllerTheme(presentationTheme: self.presentationData.theme))\n"
    replace(patches, "icon-packs-launch", ROOT, anchor, anchor + "        if context.sharedContext.applicationBindings.isMainApp { WhitegramIconPackManager.shared.setUpAtLaunch() }\n")
    _settings_images(patches)
    return patches.write()
