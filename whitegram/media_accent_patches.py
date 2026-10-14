"""Neutral colors for bubble media controls and regular reaction pills."""

from appearance_parity_patches import replace
from source_patches import SourcePatches


MEDIA_ACCENT_RUNTIME_FILES = {
    "WhitegramMediaAccent.swift": "submodules/TelegramPresentationData/Sources/WhitegramMediaAccent.swift",
}
CHAT = "submodules/TelegramUI/Components/Chat/"
FILE = CHAT + "ChatMessageInteractiveFileNode/Sources/ChatMessageInteractiveFileNode.swift"
FOOTER = CHAT + "ChatMessageReactionsFooterContentNode/Sources/ChatMessageReactionsFooterContentNode.swift"
STATUS = CHAT + "ChatMessageDateAndStatusNode/Sources/ChatMessageDateAndStatusNode.swift"


def _file_colors(patches):
    for indent, value in (
        ("                ", "arguments.incoming ? arguments.presentationData.theme.theme.chat.message.incoming : arguments.presentationData.theme.theme.chat.message.outgoing"),
        ("        ", "incoming ? presentationData.theme.theme.chat.message.incoming : presentationData.theme.theme.chat.message.outgoing"),
    ):
        replace(patches, "neutralMediaAccent", FILE,
                f"{indent}let messageTheme = {value}\n",
                f"{indent}let messageTheme = WhitegramMediaAccent.mediaColors({value})\n")
    # A live switch can turn a dark control fill white. Update the glyph as well.
    for node in ("statusNode", "streamingStatusNode"):
        before = f"            {node}.backgroundNodeColor = backgroundNodeColor\n"
        replace(patches, "neutralMediaAccent", FILE, before,
                before + f"            {node}.foregroundNodeColor = foregroundNodeColor\n")


def _reaction_colors(patches):
    replace(patches, "neutralMediaAccent", FOOTER,
            "        let reactionColors: ReactionButtonComponent.Colors\n",
            "        let reactionColors: ReactionButtonComponent.Colors\n"
            '        let whitegramNeutralMediaAccent = WhitegramAppearancePolicy.current.isEnabled("neutralMediaAccent")\n')
    replace(patches, "neutralMediaAccent", STATUS,
            "            let reactionColors: ReactionButtonComponent.Colors\n",
            """            let reactionColors: ReactionButtonComponent.Colors
            let whitegramNeutralMediaAccent: Bool
            switch arguments.type {
            case .BubbleIncoming, .BubbleOutgoing:
                whitegramNeutralMediaAccent = WhitegramAppearancePolicy.current.isEnabled("neutralMediaAccent")
            default:
                whitegramNeutralMediaAccent = false
            }
""")
    for path, indent, declaration, data in (
        (FOOTER, "            ", "themeColors", "presentationData"),
        (STATUS, "                ", "let themeColors", "arguments.presentationData"),
    ):
        for incoming, direction in (("true", "incoming"), ("false", "outgoing")):
            before = f"{indent}{declaration} = bubbleColorComponents(theme: {data}.theme.theme, incoming: {incoming}, wallpaper: !{data}.theme.wallpaper.isEmpty)\n"
            after = before + f"{indent}let whitegramReactionColors = WhitegramMediaAccent.reactionColors(themeColors, text: {data}.theme.theme.chat.message.{direction}.primaryTextColor, enabled: whitegramNeutralMediaAccent)\n"
            replace(patches, "neutralMediaAccent", path, before, after)
    before = """            reactionColors = ReactionButtonComponent.Colors(
                deselectedBackground: selectReactionFillStaticColor(theme: presentationData.theme.theme, wallpaper: presentationData.theme.wallpaper).argb,
"""
    replace(patches, "neutralMediaAccent", FOOTER, before,
            "            let whitegramReactionColors = themeColors\n" + before)
    # Keep paid Stars, extracted-menu colors and freeform wallpaper colors native.
    for path, count in ((FOOTER, 3), (STATUS, 2)):
        for field in (
            "deselectedBackground: themeColors.reactionInactiveBackground",
            "selectedBackground: themeColors.reactionActiveBackground",
            "deselectedForeground: themeColors.reactionInactiveForeground",
            "selectedForeground: themeColors.reactionActiveForeground",
            "deselectedMediaPlaceholder: themeColors.reactionInactiveMediaPlaceholder",
            "selectedMediaPlaceholder: themeColors.reactionActiveMediaPlaceholder",
        ):
            expected = count - 1 if path == FOOTER and field.startswith("deselectedBackground:") else count
            replace(patches, "neutralMediaAccent", path, field + ".argb,",
                    field.replace("themeColors.", "whitegramReactionColors.") + ".argb,", count=expected)


def apply_media_accent_patches(root):
    patches = SourcePatches(root)
    _file_colors(patches)
    _reaction_colors(patches)
    return patches.write()
