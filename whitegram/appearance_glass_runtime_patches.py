"""Live material replacement while retaining Telegram's native content containers."""

from appearance_parity_patches import replace


GLASS = "submodules/TelegramUI/Components/GlassBackgroundComponent/Sources/GlassBackgroundComponent.swift"
LENS = "submodules/TelegramUI/Components/LiquidLens/Sources/LiquidLensView.swift"

BACKGROUND_MEMBERS = """    var whitegramSolidColor: UIColor?
    private var whitegramReplacementView: WhitegramGlassReplacementView?
    private var whitegramLayout: (CGSize, Params)?
    private var whitegramObservers: [NSObjectProtocol] = []

    private func observeWhitegramGlass() {
        for name in [WhitegramGlassSettings.updatedNotification, UIAccessibility.reduceTransparencyStatusDidChangeNotification, UIAccessibility.reduceMotionStatusDidChangeNotification] {
            self.whitegramObservers.append(NotificationCenter.default.addObserver(forName: name, object: nil, queue: .main) { [weak self] _ in
                guard let self, let (size, params) = self.whitegramLayout else { return }
                self.update(size: size, shape: params.shape, isDark: params.isDark, tintColor: params.tintColor,
                    isInteractive: params.isInteractive, isVisible: params.isVisible, transition: .immediate)
            })
        }
    }

    private func updateWhitegramReplacement(size: CGSize, shape: Shape, isDark: Bool, tintColor: TintColor,
                                            mode: WhitegramGlassSettings.Replacement, isVisible: Bool, transition: ComponentTransition) {
        guard mode != .system else {
            self.whitegramReplacementView?.removeFromSuperview()
            self.whitegramReplacementView = nil
            return
        }
        let view: WhitegramGlassReplacementView
        if let current = self.whitegramReplacementView { view = current }
        else {
            view = WhitegramGlassReplacementView(frame: .zero)
            self.whitegramReplacementView = view
            self.insertSubview(view, at: 0)
        }
        transition.setFrame(view: view, frame: CGRect(origin: .zero, size: size))
        view.update(size: size, shape: shape, isDark: isDark, tintColor: tintColor,
            solidColor: self.whitegramSolidColor, mode: mode, transition: transition)
        transition.setAlpha(view: view, alpha: isVisible ? 1.0 : 0.0)
    }

"""

BACKGROUND_UPDATE = """        self.whitegramLayout = (size, Params(shape: shape, isDark: isDark, tintColor: tintColor, isInteractive: isInteractive, isVisible: isVisible))
        let whitegramSettings = WhitegramGlassSettings.current
        var replacement = UIAccessibility.isReduceTransparencyEnabled ? WhitegramGlassSettings.Replacement.color : whitegramSettings.replacement
        if replacement == .telegram, self.legacyView != nil { replacement = .system }
        let whitegramVisible = isVisible
        let isVisible = isVisible && replacement == .system
        let isInteractive = isInteractive && replacement == .system && !UIAccessibility.isReduceMotionEnabled
        let transition: ComponentTransition = UIAccessibility.isReduceMotionEnabled ? .immediate : transition
        let tintColor = WhitegramGlassReplacementView.tint(tintColor, settings: whitegramSettings)
        defer {
            self.updateWhitegramReplacement(size: size, shape: shape, isDark: isDark, tintColor: tintColor,
                mode: replacement, isVisible: whitegramVisible, transition: transition)
        }
"""

CONTAINER_MEMBERS = """    private let whitegramSpacing: CGFloat
    private var whitegramContainerEnabled: Bool?
    private var whitegramObservers: [NSObjectProtocol] = []

    private func observeWhitegramGlass() {
        for name in [WhitegramGlassSettings.updatedNotification, UIAccessibility.reduceTransparencyStatusDidChangeNotification] {
            self.whitegramObservers.append(NotificationCenter.default.addObserver(forName: name, object: nil, queue: .main) { [weak self] _ in
                self?.updateWhitegramGlassContainer()
            })
        }
        self.updateWhitegramGlassContainer()
    }

    private func updateWhitegramGlassContainer() {
        let enabled = WhitegramGlassSettings.current.replacement == .system && !UIAccessibility.isReduceTransparencyEnabled
        guard enabled != self.whitegramContainerEnabled else { return }
        self.whitegramContainerEnabled = enabled
        #if compiler(>=6.2)
        if #available(iOS 26.0, *), let nativeView = self.nativeView {
            if enabled {
                let effect = UIGlassContainerEffect()
                effect.spacing = self.whitegramSpacing
                nativeView.effect = effect
            } else {
                // Keep nativeView.contentView and every child in place across mode changes.
                nativeView.effect = UIVisualEffect()
            }
        }
        #endif
    }

"""

LENS_LEGACY_SETUP = """            let legacySelectionView = GlassBackgroundView.ContentImageView()
            self.legacySelectionView = legacySelectionView
            if let backgroundView = self.backgroundView {
                backgroundView.contentView.insertSubview(legacySelectionView, at: 0)
            } else {
                self.containerView.insertSubview(legacySelectionView, at: 0)
            }

            let legacyContentMaskView = UIView()
            legacyContentMaskView.backgroundColor = .white
            self.legacyContentMaskView = legacyContentMaskView
            self.contentView.mask = legacyContentMaskView

            if let filter = CALayer.luminanceToAlpha() {
                legacyContentMaskView.layer.filters = [filter]
            }

            let legacyContentMaskBlobView = UIImageView()
            self.legacyContentMaskBlobView = legacyContentMaskBlobView
            legacyContentMaskView.addSubview(legacyContentMaskBlobView)

            self.containerView.addSubview(self.contentView)

            let legacyLiftedContentBlobMaskView = UIImageView()
            self.legacyLiftedContentBlobMaskView = legacyLiftedContentBlobMaskView
            self.liftedContainerView.mask = legacyLiftedContentBlobMaskView

            self.containerView.addSubview(self.liftedContainerView)
""".replace("\n\n", "\n" + " " * 12 + "\n")

LENS_MEMBERS = """    private var whitegramNativeLensView: UIView?
    private weak var whitegramLiftedContainer: UIView?
    private var whitegramUsesLegacyLens: Bool?
    private var whitegramObservers: [NSObjectProtocol] = []

    private func observeWhitegramLens() {
        self.whitegramNativeLensView = self.lensView
        for name in [WhitegramGlassSettings.updatedNotification, UIAccessibility.reduceTransparencyStatusDidChangeNotification, UIAccessibility.reduceMotionStatusDidChangeNotification] {
            self.whitegramObservers.append(NotificationCenter.default.addObserver(forName: name, object: nil, queue: .main) { [weak self] _ in
                guard let self, let params = self.params else { return }
                self.update(params: params, transition: .immediate)
            })
        }
    }

    private func updateWhitegramLensMode() {
        let usesLegacy = self.whitegramNativeLensView == nil || WhitegramGlassSettings.current.replacement != .system || UIAccessibility.isReduceTransparencyEnabled || UIAccessibility.isReduceMotionEnabled
        guard self.whitegramUsesLegacyLens != usesLegacy else { return }
        self.whitegramUsesLegacyLens = usesLegacy
        self.liftedDisplayLink?.invalidate()
        self.liftedDisplayLink = nil
        self.pendingLensParams = nil
        self.appliedLensParams = nil
        self.isApplyingLensParams = false
        self.isAnimating = false
        self.whitegramNativeLensView?.isHidden = usesLegacy
        self.lensView = usesLegacy ? nil : self.whitegramNativeLensView
        if usesLegacy && self.legacySelectionView == nil {
            self.setUpWhitegramLegacySelection()
        }
        self.legacySelectionView?.isHidden = !usesLegacy
        self.contentView.mask = usesLegacy ? self.legacyContentMaskView : nil
        self.liftedContainerView.mask = usesLegacy ? self.legacyLiftedContentBlobMaskView : nil
        if !usesLegacy, let lensView = self.lensView {
            self.containerView.addSubview(self.liftedContainerView)
            self.containerView.addSubview(lensView)
            self.containerView.addSubview(self.contentView)
            if let container = self.whitegramLiftedContainer { self.setLiftedContainer(view: container) }
        }
    }

    private func setUpWhitegramLegacySelection() {
""" + "\n".join(line[4:] if line.startswith("    ") else line for line in LENS_LEGACY_SETUP.splitlines()) + """
    }

    deinit {
        for observer in self.whitegramObservers { NotificationCenter.default.removeObserver(observer) }
        self.liftedDisplayLink?.invalidate()
    }

"""


def _lens_runtime(patches):
    feature = "glass-lens-replacement"
    replace(patches, feature, LENS, LENS_LEGACY_SETUP + "        }\n    }\n",
            "            self.setUpWhitegramLegacySelection()\n        }\n        self.observeWhitegramLens()\n    }\n")
    anchor = "    private var lensView: UIView?\n"
    replace(patches, feature, LENS, anchor, anchor + LENS_MEMBERS)
    anchor = "    public func setLiftedContainer(view: UIView) {\n"
    replace(patches, feature, LENS, anchor, anchor + "        self.whitegramLiftedContainer = view\n")
    anchor = "    private func update(params: Params, transition: ComponentTransition) {\n"
    replace(patches, feature, LENS, anchor, anchor + "        self.updateWhitegramLensMode()\n")
    replace(patches, feature, LENS, "        let transition: ComponentTransition = isFirstTime ? .immediate : transition\n",
            "        let transition: ComponentTransition = isFirstTime || UIAccessibility.isReduceMotionEnabled ? .immediate : transition\n")
    replace(patches, feature, LENS, "        self.restingBackgroundView.update(isDark: params.isDark)\n",
            "        if self.lensView != nil { self.restingBackgroundView.update(isDark: params.isDark) }\n", count=2)
    replace(patches, feature, LENS, "        if let legacyContentMaskView = self.legacyContentMaskView {\n",
            "        if self.lensView == nil, let legacyContentMaskView = self.legacyContentMaskView {\n")
    replace(patches, feature, LENS, "        if let legacyContentMaskBlobView = self.legacyContentMaskBlobView, let legacyLiftedContentBlobMaskView = self.legacyLiftedContentBlobMaskView, let legacySelectionView = self.legacySelectionView {\n",
            "        if self.lensView == nil, let legacyContentMaskBlobView = self.legacyContentMaskBlobView, let legacyLiftedContentBlobMaskView = self.legacyLiftedContentBlobMaskView, let legacySelectionView = self.legacySelectionView {\n")
    replace(patches, feature, LENS, "alpha: (params.isLifted || params.isCollapsed) ? 0.0 : 1.0)",
            "alpha: (self.lensView == nil || params.isLifted || params.isCollapsed) ? 0.0 : 1.0)")
    replace(patches, feature, LENS, "        if params.isLifted {\n            if self.liftedDisplayLink == nil {\n",
            "        if self.lensView != nil && params.isLifted {\n            if self.liftedDisplayLink == nil {\n")


def patch_glass_runtime(patches):
    feature = "glass-material-replacement"
    anchor = "    public private(set) var params: Params?\n"
    replace(patches, feature, GLASS, anchor, BACKGROUND_MEMBERS + anchor)
    anchor = "        self.addSubview(self.contentContainer)\n"
    replace(patches, feature, GLASS, anchor, anchor + "        self.observeWhitegramGlass()\n")
    anchor = "    @objc private func onHighlightGesture(_ recognizer: GlassHighlightGestureRecognizer) {\n"
    replace(patches, feature, GLASS, anchor, """    deinit {
        for observer in self.whitegramObservers { NotificationCenter.default.removeObserver(observer) }
    }

""" + anchor)
    _lens_runtime(patches)
    anchor = "    func update(size: CGSize, shape: Shape, isDark: Bool, tintColor: TintColor, isInteractive: Bool = false, isVisible: Bool = true, transition: ComponentTransition) {\n"
    replace(patches, feature, GLASS, anchor, anchor + BACKGROUND_UPDATE)

    anchor = "public final class GlassBackgroundContainerView: UIView {\n"
    replace(patches, feature, GLASS, anchor, anchor + CONTAINER_MEMBERS)
    anchor = "    public init(spacing: CGFloat = 7.0) {\n"
    replace(patches, feature, GLASS, anchor, anchor + "        self.whitegramSpacing = spacing\n")
    anchor = "        } else if let legacyView = self.legacyView {\n            self.addSubview(legacyView)\n        }\n"
    replace(patches, feature, GLASS, anchor, anchor + "        self.observeWhitegramGlass()\n")
    anchor = "    override public func didAddSubview(_ subview: UIView) {\n"
    replace(patches, feature, GLASS, anchor, """    deinit {
        for observer in self.whitegramObservers { NotificationCenter.default.removeObserver(observer) }
    }

""" + anchor)
