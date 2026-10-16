"""Profile action geometry and the bundled primary-icon preview."""

from source_patches import SourcePatches
from appearance_parity_patches import replace

PEER = "submodules/TelegramUI/Components/PeerInfo/PeerInfoScreen/Sources/"
HEADER = PEER + "PeerInfoHeaderNode.swift"
BUTTON = PEER + "PeerInfoHeaderButtonNode.swift"
APP = "submodules/TelegramUI/Sources/AppDelegate.swift"


def apply_appearance_details_patches(root):
    patches = SourcePatches(root)
    replace(patches, "primaryIconPreview", APP,
            'PresentationAppIcon(name: "Default", imageName: "BlueIcon", isDefault: true)',
            'PresentationAppIcon(name: "Default", imageName: "WhitegramPrimaryPreview", isDefault: true)')
    replace(patches, "roundProfileActionButtons", BUTTON, "import TelegramPresentationData\n", "import TelegramPresentationData\nimport TelegramCore\n")
    replace(patches, "roundProfileActionButtons", BUTTON,
            "        let backgroundY: CGFloat = size.height * (1.0 - fraction)\n        let backgroundFrame = CGRect(origin: CGPoint(x: 0.0, y: backgroundY), size: CGSize(width: size.width, height: max(0.0, size.height - backgroundY)))\n",
            "        let geometry = WhitegramAppearancePolicy.profileActionButtonGeometry(size: size, fraction: fraction, rounded: WhitegramAppearancePolicy.current.isEnabled(\"roundProfileActionButtons\"))\n        let backgroundFrame = geometry.backgroundFrame\n")
    replace(patches, "roundProfileActionButtons", BUTTON,
            "cornerRadius: min(16.0, backgroundFrame.height * 0.5)", "cornerRadius: geometry.cornerRadius")
    replace(patches, "roundProfileActionButtons", BUTTON,
            "y: 1.0), size: iconSize)", "y: geometry.iconY), size: iconSize)", count=2)
    replace(patches, "roundProfileActionButtons", BUTTON,
            "size.height - titleSize.height - 9.0", "size.height - titleSize.height - geometry.labelBottomInset")
    anchor = "        let backgroundCoverSubject: PeerInfoCoverComponent.Subject?\n"
    replace(patches, "roundProfileActionButtons", HEADER, anchor,
            '        let roundActionButtons = WhitegramAppearancePolicy.current.isEnabled("roundProfileActionButtons")\n        let actionRowHeight: CGFloat = roundActionButtons ? 72.0 : 58.0\n' + anchor)
    replace(patches, "roundProfileActionButtons", HEADER,
            "expandedAvatarHeight - bottomInset - 58.0 - UIScreenPixel", "expandedAvatarHeight - bottomInset - actionRowHeight - UIScreenPixel")
    replace(patches, "roundProfileActionButtons", HEADER,
            "                    expandablePart += 99.0\n", "                    expandablePart += 99.0 + (buttonKeys.isEmpty ? 0.0 : actionRowHeight - 58.0)\n")
    for name, keys in (("actionButtonWidth", "actionButtonKeys"), ("buttonWidth", "buttonKeys")):
        replace(patches, "profileButtonFiniteLayout", HEADER,
                f"let {name} = (width - buttonSideInset * 2.0 + buttonSpacing) / CGFloat({keys}.count) - buttonSpacing",
                f"let {name} = WhitegramAppearancePolicy.profileActionButtonWidth(width: width, inset: buttonSideInset, spacing: buttonSpacing, count: {keys}.count)")
    replace(patches, "roundProfileActionButtons", HEADER,
            "let buttonSize = CGSize(width: buttonWidth, height: 58.0)", "let buttonSize = CGSize(width: buttonWidth, height: actionRowHeight)")
    return patches.write()
