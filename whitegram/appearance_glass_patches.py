"""Recovered glass surfaces with native blur/glass and accessible local fallbacks."""

from pathlib import Path

from source_patches import SourcePatches
from appearance_parity_patches import replace
from appearance_glass_runtime_patches import patch_glass_runtime


APPEARANCE_GLASS_RUNTIME_FILES = {
    "WhitegramGlassSettings.swift": "submodules/Display/Source/WhitegramGlassSettings.swift",
    "WhitegramGlassSurfaceView.swift": "submodules/TelegramUI/Components/GlassBackgroundComponent/Sources/WhitegramGlassSurfaceView.swift",
    "WhitegramGlassReplacementView.swift": "submodules/TelegramUI/Components/GlassBackgroundComponent/Sources/WhitegramGlassReplacementView.swift",
    "WhitegramGlassController.swift": "submodules/SettingsUI/Sources/WhitegramGlassController.swift",
}

BACKGROUND = "submodules/ChatMessageBackground/Sources/ChatMessageBackground.swift"
GRAPHICS = "submodules/TelegramPresentationData/Sources/PresentationThemeEssentialGraphics.swift"
GLASS = "submodules/TelegramUI/Components/GlassBackgroundComponent/Sources/GlassBackgroundComponent.swift"
INLINE = "submodules/TelegramUI/Components/Chat/ChatMessageActionButtonsNode/Sources/ChatMessageActionButtonsNode.swift"
PEER = "submodules/TelegramUI/Components/PeerInfo/PeerInfoScreen/Sources/"
GIFT = "submodules/TelegramUI/Components/Gifts/GiftItemComponent/Sources/GiftItemComponent.swift"


BUBBLE_SURFACE = """    private var whitegramGlassSurface: WhitegramGlassSurfaceView?
    private let whitegramGlassMask = UIImageView()

    private func updateWhitegramGlass(transition: ContainedViewLayoutTransition = .immediate, animator: ControlledTransitionAnimator? = nil) {
        guard self.isNodeLoaded,
              let type = self.type, let graphics = self.graphics, let imageFrame = self.imageFrame,
              let mask = bubbleMaskForType(type, graphics: graphics) else {
            if let surface = self.whitegramGlassSurface {
                surface.update(size: .zero, cornerRadius: 0, isDark: false, color: .clear, area: .bubbles, isAllowed: false, transition: .immediate)
            }
            return
        }
        let surface: WhitegramGlassSurfaceView
        if let current = self.whitegramGlassSurface { surface = current }
        else {
            surface = WhitegramGlassSurfaceView(frame: imageFrame)
            surface.mask = self.whitegramGlassMask
            surface.enabledUpdated = { [weak self] _ in
                guard let self else { return }
                let appearance = WhitegramBubbleAppearance.current
                let opacity = self.currentHighlighted == true ? 1.0 : appearance.fillOpacity
                self.imageView?.alpha = opacity
                self.outlineImageNode.alpha = appearance.borderEnabled ? 1.0 : opacity
                self.backdropNode?.backgroundContent?.alpha = appearance.fillOpacity
            }
            self.whitegramGlassSurface = surface
            self.view.insertSubview(surface, at: 0)
        }
        self.whitegramGlassMask.image = mask
        let transition: ContainedViewLayoutTransition = UIAccessibility.isReduceMotionEnabled ? .immediate : transition
        if let animator, !UIAccessibility.isReduceMotionEnabled {
            animator.updateFrame(layer: self.whitegramGlassMask.layer, frame: CGRect(origin: .zero, size: imageFrame.size), completion: nil)
            animator.updateFrame(layer: surface.layer, frame: imageFrame, completion: nil)
        } else {
            transition.updateFrame(view: self.whitegramGlassMask, frame: CGRect(origin: .zero, size: imageFrame.size))
            transition.updateFrame(view: surface, frame: imageFrame)
        }
        let incoming: Bool
        if case .incoming = type { incoming = true } else { incoming = false }
        surface.update(size: imageFrame.size, cornerRadius: 0.0, isDark: graphics.whitegramIsDark,
            color: incoming ? graphics.whitegramIncomingFillColor : graphics.whitegramOutgoingFillColor,
            area: .bubbles, isAllowed: self.currentHighlighted != true, transition: transition)
    }

"""


def _bubble_surfaces(patches):
    replace(patches, "glass-bubbles", BACKGROUND, "import WallpaperBackgroundNode\n", "import WallpaperBackgroundNode\nimport GlassBackgroundComponent\n")
    anchor = "    public weak var backdropNode: ChatMessageBubbleBackdrop?\n"
    replace(patches, "glass-bubbles", BACKGROUND, anchor, anchor + BUBBLE_SURFACE)
    anchor = "        imageView.image = self.imageViewImage\n"
    replace(patches, "glass-bubbles", BACKGROUND, anchor, "        defer { self.updateWhitegramGlass() }\n" + anchor)
    for signature, arguments in (
        ("    public func updateLayout(size: CGSize, transition: ContainedViewLayoutTransition) {\n", "transition: transition"),
        ("    public func updateLayout(size: CGSize, transition: ListViewItemUpdateAnimation) {\n", "animator: transition.animator"),
        ("    public func setType(type: ChatMessageBackgroundType, highlighted: Bool, graphics: PrincipalThemeEssentialGraphics, maskMode: Bool, hasWallpaper: Bool, transition: ContainedViewLayoutTransition, backgroundNode: WallpaperBackgroundNode?) {\n", "transition: transition"),
    ):
        replace(patches, "glass-bubbles", BACKGROUND, signature, signature + f"        defer {{ self.updateWhitegramGlass({arguments}) }}\n")
    anchor = "            transition.animateFrame(layer: self.outlineImageNode.layer, from: sourceViewFrame)\n"
    replace(patches, "glass-bubbles", BACKGROUND, anchor, anchor + """            if let surface = self.whitegramGlassSurface, !UIAccessibility.isReduceMotionEnabled {
                transition.animateFrame(layer: surface.layer, from: sourceViewFrame)
                transition.animateFrame(layer: self.whitegramGlassMask.layer, from: CGRect(origin: .zero, size: sourceViewFrame.size))
            }
""")
    anchor = "    public let hasWallpaper: Bool\n"
    replace(patches, "glass-bubbles", GRAPHICS, anchor, "    public let whitegramIsDark: Bool\n    public let whitegramIncomingFillColor: UIColor\n    public let whitegramOutgoingFillColor: UIColor\n" + anchor)
    anchor = "        self.hasWallpaper = !wallpaper.isEmpty\n"
    replace(patches, "glass-bubbles", GRAPHICS, anchor, """        self.whitegramIsDark = presentationTheme.overallDarkAppearance
        self.whitegramIncomingFillColor = theme.message.incoming.bubble.withWallpaper.fill.first ?? presentationTheme.list.itemBlocksBackgroundColor
        self.whitegramOutgoingFillColor = theme.message.outgoing.bubble.withWallpaper.fill.first ?? presentationTheme.list.itemBlocksBackgroundColor
""" + anchor)


def _inline_surfaces(patches):
    replace(patches, "liquidGlassInlineButtons", INLINE, "import Foundation\n", "import Foundation\nimport GlassBackgroundComponent\n")
    anchor = "    private var backgroundColorView: UIImageView?\n"
    replace(patches, "liquidGlassInlineButtons", INLINE, anchor, anchor + "    private var whitegramGlassSurface: WhitegramGlassSurfaceView?\n")
    anchor = "                    node.wallpaperBackgroundNode = backgroundNode\n"
    replace(patches, "liquidGlassInlineButtons", INLINE, anchor, """                    defer {
                        let surface: WhitegramGlassSurfaceView
                        if let current = node.whitegramGlassSurface { surface = current }
                        else {
                            surface = WhitegramGlassSurfaceView(frame: .zero)
                            surface.enabledUpdated = { [weak node] enabled in
                                guard let node else { return }
                                node.backgroundBlurView?.view.isHidden = enabled || node.backgroundContent != nil
                                node.backgroundContent?.isHidden = enabled
                            }
                            node.whitegramGlassSurface = surface
                            node.view.insertSubview(surface, at: 0)
                        }
                        let size = CGSize(width: max(0, width), height: 42)
                        animation.animator.updateFrame(layer: surface.layer, frame: CGRect(origin: .zero, size: size), completion: nil)
                        surface.update(size: size, cornerRadius: bubbleCorners.auxiliaryRadius,
                            isDark: theme.theme.overallDarkAppearance, color: theme.theme.list.itemBlocksBackgroundColor,
                            area: .inlineButtons, transition: .immediate)
                        surface.alpha = customInfo?.isEnabled == false || node.buttonView?.isHighlighted == true ? 0.55 : 1.0
                    }
""" + anchor)
    for value in ("0.55", "1.0"):
        anchor = f"                    strongSelf.backgroundContent?.alpha = {value}\n"
        replace(patches, "liquidGlassInlineButtons", INLINE, anchor,
                anchor + f"                    strongSelf.whitegramGlassSurface?.alpha = {value}\n")


def _profile_surfaces(patches):
    path = PEER + "PeerInfoScreenItemSectionContainerNode.swift"
    replace(patches, "liquidGlassProfileSettings", path, "import Foundation\n", "import Foundation\nimport GlassBackgroundComponent\n")
    anchor = "    private let backgroundNode: ASDisplayNode\n"
    replace(patches, "liquidGlassProfileSettings", path, anchor, anchor + "    private var whitegramGlassSurface: WhitegramGlassSurfaceView?\n    var whitegramIsSettings = false\n")
    anchor = "        return contentHeight\n"
    replace(patches, "liquidGlassProfileSettings", path, anchor, """        let surface: WhitegramGlassSurfaceView
        if let current = self.whitegramGlassSurface { surface = current }
        else {
            surface = WhitegramGlassSurfaceView(frame: .zero)
            surface.enabledUpdated = { [weak self] enabled in self?.backgroundNode.isHidden = enabled }
            self.whitegramGlassSurface = surface
            self.view.insertSubview(surface, at: 0)
        }
        let frame = CGRect(x: 0, y: contentWithBackgroundOffset, width: width, height: max(0, contentWithBackgroundHeight - contentWithBackgroundOffset))
        transition.updateFrame(view: surface, frame: frame)
        surface.update(size: frame.size, cornerRadius: hasCorners ? 11.0 : 0.0,
            isDark: presentationData.theme.overallDarkAppearance, color: presentationData.theme.list.itemBlocksBackgroundColor,
            area: self.whitegramIsSettings ? .settings : .profile, transition: transition)
""" + anchor)
    anchor = "                let sectionHeight = sectionNode.update(context: self.context, width: sectionWidth,"
    replace(patches, "liquidGlassProfileSettings", PEER + "PeerInfoScreen.swift", anchor,
            "                sectionNode.whitegramIsSettings = self.isSettings\n" + anchor, count=2)


def _gift_surfaces(patches):
    replace(patches, "liquidGlassGifts", GIFT, "import Foundation\n", "import Foundation\nimport GlassBackgroundComponent\n")
    anchor = "        public let backgroundLayer = SimpleLayer()\n"
    replace(patches, "liquidGlassGifts", GIFT, anchor, anchor + "        private var whitegramGlassSurface: WhitegramGlassSurfaceView?\n")
    anchor = "            transition.setFrame(layer: self.backgroundLayer, frame: backgroundFrame)\n"
    replace(patches, "liquidGlassGifts", GIFT, anchor, anchor + """            let surface: WhitegramGlassSurfaceView
            if let current = self.whitegramGlassSurface { surface = current }
            else {
                surface = WhitegramGlassSurfaceView(frame: .zero)
                surface.enabledUpdated = { [weak self] enabled in self?.backgroundLayer.isHidden = enabled }
                self.whitegramGlassSurface = surface
                self.insertSubview(surface, at: 0)
            }
            transition.setFrame(view: surface, frame: backgroundFrame)
            surface.update(size: backgroundFrame.size, cornerRadius: cornerRadius,
                isDark: component.theme.overallDarkAppearance, color: UIColor(cgColor: self.backgroundLayer.backgroundColor ?? component.theme.list.itemBlocksBackgroundColor.cgColor),
                area: .gifts, isAllowed: backgroundColor == nil && cornerRadius > 0,
                transition: transition.containedViewLayoutTransition)
""")


def apply_appearance_glass_patches(root: Path) -> dict[str, list[str]]:
    patches = SourcePatches(root)
    patch_glass_runtime(patches)
    _bubble_surfaces(patches)
    _inline_surfaces(patches)
    _profile_surfaces(patches)
    _gift_surfaces(patches)
    return patches.write()
