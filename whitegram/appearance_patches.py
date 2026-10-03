"""Display-level custom-font integration for the clean-room appearance screens."""

from pathlib import Path

from source_patches import SourcePatches
from appearance_parity_patches import replace


APPEARANCE_RUNTIME_FILES = {
    "WhitegramFontRegistry.swift": "submodules/Display/Source/WhitegramFontRegistry.swift",
    "WhitegramFontHistory.swift": "submodules/Display/Source/WhitegramFontHistory.swift",
    "WhitegramFontArchivePlan.swift": "submodules/SettingsUI/Sources/WhitegramFontArchivePlan.swift",
    "WhitegramFontArchiveImport.swift": "submodules/SettingsUI/Sources/WhitegramFontArchiveImport.swift",
    "WhitegramFontsController.swift": "submodules/SettingsUI/Sources/WhitegramFontsController.swift",
    "WhitegramIconsController.swift": "submodules/SettingsUI/Sources/WhitegramIconsController.swift",
}


FONT_PATH = "submodules/Display/Source/Font.swift"
FONT_WITH = "    public static func with(size: CGFloat, design: Design = .regular, weight: Weight = .regular, width: Width = .standard, traits: Traits = []) -> UIFont {\n"
FONT_HOOK = (
    "        if let customFont = WhitegramFontRegistry.shared.font(size: size, design: design, weight: weight, width: width, traits: traits) {\n"
    "            return customFont\n"
    "        }\n"
)
CONVENIENCE_FONTS = (
    ("regular", "regular", "[]"),
    ("medium", "medium", "[]"),
    ("semibold", "semibold", "[]"),
    ("bold", "bold", "[]"),
    ("light", "light", "[]"),
    ("semiboldItalic", "semibold", "[.italic]"),
    ("italic", "regular", "[.italic]"),
)


def apply_appearance_patches(root: Path) -> dict[str, list[str]]:
    patches = SourcePatches(root)
    replace(patches, "customFonts", FONT_PATH, FONT_WITH, FONT_WITH + FONT_HOOK)
    for name, weight, traits in CONVENIENCE_FONTS:
        signature = f"    public static func {name}(_ size: CGFloat) -> UIFont {{\n"
        hook = (
            "        if let customFont = WhitegramFontRegistry.shared.font(size: size, design: .regular, "
            f"weight: .{weight}, width: .standard, traits: {traits}) {{\n"
            "            return customFont\n"
            "        }\n"
        )
        replace(patches, "customFonts", FONT_PATH, signature, signature + hook)
    # heavy already delegates to with; leave that route and every original fallback intact.
    return patches.write()
