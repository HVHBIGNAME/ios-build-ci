"""Install the verified plugin SDK into a real application resource bundle."""

import plistlib
from pathlib import Path

from source_patches import SourcePatches

SDK_FILES = (
    "whitegram-native-bootstrap.js", "whitegram-sdk-core.js", "whitegram-plugin-lifecycle.js",
    "whitegram-sdk-extensions.js", "whitegram-sdk-bridge.js", "whitegram-plugin-host.js",
)


def install_plugin_resources(root: Path, overlay: Path):
    source = overlay / "cleanroom" / "pluginsdk"
    for name in SDK_FILES:
        if not (source / name).is_file():
            raise ValueError(f"Missing plugin SDK resource: {name}")
    patches = SourcePatches(root)
    build = "Telegram/BUILD"
    anchor = 'load("@rules_cc//cc:objc_library.bzl", "objc_library")'
    patches.replace("plugin-sdk-resources", build, anchor,
        'load("@build_bazel_rules_apple//apple:resources.bzl", "apple_resource_bundle")\n' + anchor)
    anchor = 'ios_application(\n    name = "Telegram",'
    bundle = 'apple_resource_bundle(\n    name = "WhitegramPluginSDK",\n    infoplists = ["WhitegramPluginSDK/Info.plist"],\n    resources = [\n'
    bundle += "".join(f'        "WhitegramPluginSDK/{name}",\n' for name in SDK_FILES)
    bundle += '    ],\n    visibility = ["//visibility:public"],\n)\n\n'
    patches.replace("plugin-sdk-resources", build, anchor, bundle + anchor)
    anchor = '    resources = [\n        ":LaunchScreen",'
    patches.replace("plugin-sdk-resources", build, anchor, anchor + '\n        ":WhitegramPluginSDK",')
    destination = root / "Telegram" / "WhitegramPluginSDK"
    destination.mkdir(parents=True, exist_ok=True)
    for name in SDK_FILES:
        (destination / name).write_bytes((source / name).read_bytes())
    (destination / "Info.plist").write_bytes(plistlib.dumps({
        "CFBundleIdentifier": "org.whitegram.PluginSDK", "CFBundleDevelopmentRegion": "en",
        "CFBundleName": "WhitegramPluginSDK", "CFBundlePackageType": "BNDL", "CFBundleVersion": "1",
    }))
    return patches.write()
