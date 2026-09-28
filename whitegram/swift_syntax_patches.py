"""Spell inherited Swift casts explicitly for source-parser compatibility."""

from pathlib import Path

from source_patches import SourcePatches


def apply_swift_syntax_patches(root: Path) -> dict[str, list[str]]:
    patches = SourcePatches(root)
    path = "submodules/Display/Source/UIKitUtils.swift"
    types = (
        ("SetTintColor", "(NSObject, Selector, UIColor?) -> Void", 1),
        ("SetInteractive", "(NSObject, Selector, Bool) -> Void", 2),
        ("MakeStyledEffect", "(AnyObject, Selector, Int) -> NSObject?", 1),
        ("AllocateEffect", "(AnyObject, Selector) -> NSObject?", 1),
        ("InitializeStyledEffect", "(NSObject, Selector, Int) -> NSObject?", 1),
        ("InitializeEffect", "(NSObject, Selector) -> NSObject?", 1),
    )
    signature = "public func makeRuntimeTelegramGlassEffect(isDark: Bool, isInteractive: Bool = false) -> UIVisualEffect? {\n"
    aliases = "".join(f"    typealias {name} = @convention(c) {signature}\n" for name, signature, _ in types)
    patches.replace("explicit-objc-function-types", path, signature, signature + aliases)
    for name, signature, count in types:
        patches.replace("explicit-objc-function-types", path, f"to: (@convention(c) {signature}).self", f"to: {name}.self", count=count)
    signature = "    static func createEmitterBehavior(type: String) -> NSObject {\n"
    patches.replace("explicit-objc-function-types", path, signature,
        signature + "        typealias MakeEmitterBehavior = @convention(c) (Any?, Selector, Any?) -> NSObject\n")
    patches.replace("explicit-objc-function-types", path,
        "to:(@convention(c)(Any?, Selector, Any?) -> NSObject).self", "to: MakeEmitterBehavior.self")

    path = "submodules/TelegramUIPreferences/Sources/WhiteGramOtherSettings.swift"
    for field, default in (
        ("autoTranslate", "false"), ("translationButton", "true"),
        ("voiceTranscription", "true"), ("forceDeviceMicrophone", "false"),
        ("hideCameraInGallery", "false"), ("hideCameraPreviewInGallery", "false"),
    ):
        value = f'defaults.object(forKey: "whitegram.other.{field}") as? Bool'
        patches.replace("explicit-optional-casts", path,
            f"self.{field} = {value} ?? {default}", f"self.{field} = ({value}) ?? {default}")
    return patches.write()
