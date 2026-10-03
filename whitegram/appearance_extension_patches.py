"""Recovered bubble, message-metadata and composer preferences on Telegram 12.9.2."""

from pathlib import Path

from source_patches import SourcePatches


APPEARANCE_EXTENSION_RUNTIME_FILES = {
    "WhitegramAppearanceSettings.swift": "submodules/TelegramCore/Sources/Settings/WhitegramAppearanceSettings.swift",
    "WhitegramBubbleAppearance.swift": "submodules/TelegramPresentationData/Sources/WhitegramBubbleAppearance.swift",
    "WhitegramAppearanceController.swift": "submodules/SettingsUI/Sources/WhitegramAppearanceController.swift",
}


BACKGROUND = "submodules/ChatMessageBackground/Sources/ChatMessageBackground.swift"
GRAPHICS = "submodules/TelegramPresentationData/Sources/PresentationThemeEssentialGraphics.swift"
CHAT = "submodules/TelegramUI/Components/Chat/"
INPUT = CHAT + "ChatTextInputPanelNode/Sources/ChatTextInputPanelNode.swift"
TEXT = CHAT + "ChatMessageTextBubbleContentNode/Sources/ChatMessageTextBubbleContentNode.swift"
ACTION = CHAT + "ChatMessageActionBubbleContentNode/Sources/ChatMessageActionBubbleContentNode.swift"
PANELS = "submodules/TelegramUI/Sources/ChatInterfaceTitlePanelNodes.swift"
HISTORY = "submodules/TelegramUI/Sources/ChatHistoryListNode.swift"
CONTROLLER = "submodules/TelegramUI/Sources/ChatController.swift"


def _replace(patches: SourcePatches, feature: str, path: str, before: str, after: str):
    value = patches.read(path)
    applied = value.count(after)
    if applied and (applied != 1 or before in value.replace(after, "")):
        raise ValueError(f"{feature}: {path}: ambiguous partially applied appearance patch")
    patches.replace(feature, path, before, after)


def _bubble_patches(patches: SourcePatches):
    feature = "bubble-presentation"
    before = "    public let hasWallpaper: Bool\n"
    _replace(patches, feature, GRAPHICS, before, before + """    public let whitegramBubbleCorners: PresentationChatBubbleCorners
    public let whitegramIncomingBorderColor: UIColor
    public let whitegramOutgoingBorderColor: UIColor
""")
    before = "        self.hasWallpaper = !wallpaper.isEmpty\n"
    _replace(patches, feature, GRAPHICS, before, before + """        self.whitegramBubbleCorners = bubbleCorners
        self.whitegramIncomingBorderColor = theme.message.incoming.accentTextColor
        self.whitegramOutgoingBorderColor = theme.message.outgoing.accentTextColor
""")

    before = "    private var imageViewImage: UIImage?\n"
    _replace(patches, feature, BACKGROUND, before, before + """    private var whitegramAppearance: WhitegramBubbleAppearance?

    private var whitegramFillOpacity: CGFloat {
        return self.currentHighlighted == true ? 1.0 : (self.whitegramAppearance?.fillOpacity ?? 1.0)
    }

    private var whitegramOutlineOpacity: CGFloat {
        return self.whitegramAppearance?.borderEnabled == true ? 1.0 : self.whitegramFillOpacity
    }
""")
    before = "        imageView.tintColor = self.customHighlightColor\n"
    _replace(patches, feature, BACKGROUND, before, before + """        imageView.alpha = self.whitegramFillOpacity
        if self.whitegramAppearance?.borderEnabled == true {
            self.view.bringSubviewToFront(self.outlineImageNode.view)
        }
""")
    before = "        let previousType = self.type\n"
    _replace(patches, feature, BACKGROUND, before,
             "        let whitegramAppearance = WhitegramBubbleAppearance.current\n" + before)
    before = "self.maskMode == maskMode, self.hasWallpaper == hasWallpaper {\n"
    _replace(patches, feature, BACKGROUND, before,
             "self.maskMode == maskMode, self.hasWallpaper == hasWallpaper, self.whitegramAppearance == whitegramAppearance {\n")
    before = "        self.type = type\n        self.currentHighlighted = highlighted\n"
    _replace(patches, feature, BACKGROUND, before,
             "        self.whitegramAppearance = whitegramAppearance\n" + before)


def _bubble_outline_patches(patches: SourcePatches):
    feature = "bubble-presentation"
    before = "        let outlineImage: UIImage?\n        if hasWallpaper {\n"
    _replace(patches, feature, BACKGROUND, before,
             "        let outlineImage: UIImage?\n        if hasWallpaper || whitegramAppearance.borderEnabled {\n")

    neighbors = (
        ("", ".none"), ("MergedTopSide", ".top(side: true)"),
        ("MergedTop", ".top(side: false)"), ("MergedBottom", ".bottom"),
        ("MergedBoth", ".both"), ("MergedSide", ".side"), ("Extracted", ".extracted"),
    )
    for direction, incoming in (("Incoming", "true"), ("Outgoing", "false")):
        for suffix, neighbor in neighbors:
            before = f"outlineImage = graphics.chatMessageBackground{direction}{suffix}OutlineImage\n"
            after = (f"outlineImage = whitegramAppearance.outlineImage(incoming: {incoming}, "
                     f"neighbors: {neighbor}, graphics: graphics) ?? graphics.chatMessageBackground{direction}{suffix}OutlineImage\n")
            _replace(patches, feature, BACKGROUND, before, after)

    before = "        self.outlineImageNode.image = outlineImage\n"
    _replace(patches, feature, BACKGROUND, before, before + """        self.outlineImageNode.alpha = self.whitegramOutlineOpacity
        if let imageView = self.imageView {
            imageView.alpha = self.whitegramFillOpacity
            if whitegramAppearance.borderEnabled {
                self.view.bringSubviewToFront(self.outlineImageNode.view)
            } else {
                self.view.insertSubview(self.outlineImageNode.view, belowSubview: imageView)
            }
        }
""")


def _bubble_animation_patches(patches: SourcePatches):
    feature = "bubble-presentation"
    for indentation in (16, 20):
        indent = " " * indentation
        before = "\n" + indent + "tempLayer.contentsCenter = imageView.layer.contentsCenter\n"
        _replace(patches, feature, BACKGROUND, before,
                 before + indent + "tempLayer.opacity = Float(self.whitegramFillOpacity)\n")
    for node, opacity in (("self.imageView?", "self.whitegramFillOpacity"),
                          ("self.outlineImageNode", "self.whitegramOutlineOpacity")):
        before = f"{node}.layer.animateAlpha(from: 0.0, to: 1.0, duration: 0.1)"
        _replace(patches, feature, BACKGROUND, before,
                 f"{node}.layer.animateAlpha(from: 0.0, to: {opacity}, duration: 0.1)")
    before = "sourceView.layer.animateAlpha(from: 1.0, to: 0.0, duration: 0.15, removeOnCompletion: false, completion:"
    _replace(patches, feature, BACKGROUND, before,
             before.replace("from: 1.0", "from: self.whitegramFillOpacity"))

    before = "        self.contentNode.image = shadowImage\n"
    _replace(patches, feature, BACKGROUND, before,
             before + "        self.contentNode.alpha = WhitegramBubbleAppearance.current.fillOpacity\n")
    before = "        let maskMode = self.fixedMaskMode ?? inputMaskMode\n"
    _replace(patches, feature, BACKGROUND, before, """        defer {
            self.backgroundContent?.alpha = WhitegramBubbleAppearance.current.fillOpacity
        }
""" + before)


def _composer_patches(patches: SourcePatches):
    feature = "showCharCountTyping"
    before = "    private let counterTextNode: ImmediateTextNode\n"
    _replace(patches, feature, INPUT, before, before + "    private var whitegramCounterTop: CGFloat?\n")
    before = "        self.counterTextNode.textAlignment = .center\n"
    _replace(patches, feature, INPUT, before, before + "        self.counterTextNode.maximumNumberOfLines = 1\n")
    before = "        let textFieldTopContentOffset = contentHeight\n"
    _replace(patches, feature, INPUT, before, """        self.whitegramCounterTop = nil
        if WhitegramAppearanceSettings.current.isEnabled(.showCharCountTyping), inputHasText, !isRecording, !hasMediaDraft, !sendingTextDisabled {
            self.whitegramCounterTop = contentHeight
            contentHeight += 22.0
        }
""" + before)
    before = ("""        if let presentationInterfaceState = self.presentationInterfaceState, let inputTextMaxLength {
            let textCount = Int32(self.richTextInputNode?.text.count ?? 0)
            let counterColor: UIColor = textCount > inputTextMaxLength ? presentationInterfaceState.theme.chat.inputPanel.panelControlDestructiveColor : presentationInterfaceState.theme.chat.inputPanel.panelControlColor
"""
              "            \n"
              """            let remainingCount = max(-999, inputTextMaxLength - textCount)
            let counterText = remainingCount >= 5 ? "" : "\\(remainingCount)"
            self.counterTextNode.attributedText = NSAttributedString(string: counterText, font: counterFont, textColor: counterColor)
        } else {
            self.counterTextNode.attributedText = NSAttributedString(string: "", font: counterFont, textColor: .black)
        }
"""
              "            \n"
              """        let counterSize = self.counterTextNode.updateLayout(CGSize(width: 40.0, height: 40.0))
        let counterFrame = CGRect(origin: CGPoint(x: backgroundSize.width - 11.0 - counterSize.width, y: 4.0), size: CGSize(width: counterSize.width, height: counterSize.height))
        transition.updateFrame(node: self.counterTextNode, frame: counterFrame)
        transition.updateAlpha(node: self.counterTextNode, alpha: backgroundSize.height > 50.0 ? 1.0 : 0.0)
""")
    after = """        if let presentationInterfaceState = self.presentationInterfaceState {
            let counter = WhitegramAppearanceSettings.current.inputCounter(text: self.richTextInputNode?.text ?? "", limit: inputTextMaxLength)
            let counterColor = counter.isOverLimit ? presentationInterfaceState.theme.chat.inputPanel.panelControlDestructiveColor : presentationInterfaceState.theme.chat.inputPanel.panelControlColor
            self.counterTextNode.attributedText = NSAttributedString(string: counter.text, font: counterFont, textColor: counterColor)
        } else {
            self.counterTextNode.attributedText = NSAttributedString(string: "", font: counterFont, textColor: .black)
        }

        let counterWidth = self.whitegramCounterTop == nil ? 40.0 : max(0.0, backgroundSize.width - 28.0)
        let counterSize = self.counterTextNode.updateLayout(CGSize(width: counterWidth, height: 40.0))
        let counterRightInset: CGFloat = self.whitegramCounterTop == nil ? 11.0 : 14.0
        let counterFrame = CGRect(origin: CGPoint(x: backgroundSize.width - counterRightInset - counterSize.width, y: self.whitegramCounterTop.map { $0 + 2.0 } ?? 4.0), size: counterSize)
        transition.updateFrame(node: self.counterTextNode, frame: counterFrame)
        let showCounter = self.whitegramCounterTop != nil || (!WhitegramAppearanceSettings.current.isEnabled(.showCharCountTyping) && backgroundSize.height > 50.0)
        transition.updateAlpha(node: self.counterTextNode, alpha: showCounter ? 1.0 : 0.0)
        self.counterTextNode.isAccessibilityElement = showCounter && !(self.counterTextNode.attributedText?.string.isEmpty ?? true)
        self.counterTextNode.accessibilityLabel = self.counterTextNode.attributedText?.string
"""
    _replace(patches, feature, INPUT, before, after)
    before = "        self.updateTextHeight(animated: animated)\n    }\n"
    _replace(patches, feature, INPUT, before, """        self.updateTextHeight(animated: animated)
        self.updateCounterTextNode(backgroundSize: self.textInputContainerBackgroundView.bounds.size, transition: .immediate)
    }
""")
    before = "            let panelHeight = self.panelHeight(textFieldHeight: textFieldHeight, metrics: metrics, bottomInset: bottomInset)\n"
    _replace(patches, feature, INPUT, before,
             before.rstrip("\n") + " + (self.whitegramCounterTop == nil ? 0.0 : 22.0)\n")


def _metadata_patches(patches: SourcePatches):
    before = "                let dateText = stringForMessageTimestampStatus(context: item.context, message: EngineMessage(item.message), dateTimeFormat: item.presentationData.dateTimeFormat, nameDisplayOrder: item.presentationData.nameDisplayOrder, strings: item.presentationData.strings, format: dateFormat, associatedData: item.associatedData)\n"
    _replace(patches, "showCharCountMessages", TEXT, before, before.replace("let dateText", "var dateText") + """                if item.message.adAttribute == nil && !item.message.isRestricted(platform: "ios", contentSettings: item.context.currentContentSettings.with { $0 }) {
                    dateText = WhitegramAppearanceSettings.current.messageStatus(dateText: dateText, text: item.message.text, russian: item.presentationData.strings.baseLanguageCode.lowercased().hasPrefix("ru"))
                }
""")
    before = "                let (labelLayout, apply) = makeLabelLayout(TextNodeLayoutArguments(attributedString: updatedAttributedString,"
    _replace(patches, "showActionTime", ACTION, before, """                if WhitegramAppearanceSettings.current.isEnabled(.showActionTime), item.message.timestamp > 0, item.message.media.contains(where: { $0 is TelegramMediaAction }), let original = updatedAttributedString, original.length > 0 {
                    let time = stringForMessageTimestamp(timestamp: item.message.timestamp, dateTimeFormat: item.presentationData.dateTimeFormat)
                    let timed = NSMutableAttributedString(attributedString: original)
                    timed.append(NSAttributedString(string: "\\n" + time, font: Font.regular(11.0), textColor: primaryTextColor))
                    updatedAttributedString = timed
                }

""" + before)


def _chat_refresh_patches(patches: SourcePatches):
    before = "        } else if !chatPresentationInterfaceState.peerIsBlocked && !inhibitTitlePanelDisplay, let contactStatus = chatPresentationInterfaceState.contactStatus, contactStatus.managingBot != nil {\n"
    _replace(patches, "hideBusinessBotPanel", PANELS, before,
             before.replace("else if !chat", "else if !WhitegramAppearanceSettings.current.isEnabled(.hideBusinessBotPanel), !chat"))
    before = "    private func beginPresentationDataManagement(updated: Signal<PresentationData, NoError>) {\n"
    _replace(patches, "appearance-live-refresh", HISTORY, before, """    func refreshWhitegramAppearance() {
        let current = self.currentPresentationData
        let updated = ChatPresentationData(
            theme: current.theme, fontSize: current.fontSize, strings: current.strings,
            dateTimeFormat: current.dateTimeFormat, nameDisplayOrder: current.nameDisplayOrder,
            disableAnimations: current.disableAnimations, largeEmoji: current.largeEmoji,
            chatBubbleCorners: current.chatBubbleCorners, animatedEmojiScale: current.animatedEmojiScale,
            isPreview: current.isPreview
        )
        self.currentPresentationData = updated
        self.chatPresentationDataPromise.set(.single(updated))
    }

""" + before)
    before = "    var presentationDataDisposable: Disposable?\n"
    _replace(patches, "appearance-live-refresh", CONTROLLER, before,
             before + "    private var whitegramAppearanceDisposable: Disposable?\n")
    before = "        self.presentationDataDisposable?.dispose()\n"
    _replace(patches, "appearance-live-refresh", CONTROLLER, before,
             before + "        self.whitegramAppearanceDisposable?.dispose()\n")
    before = "    override public func viewWillAppear(_ animated: Bool) {\n        super.viewWillAppear(animated)\n"
    _replace(patches, "appearance-live-refresh", CONTROLLER, before, before + """        if self.whitegramAppearanceDisposable == nil {
            self.whitegramAppearanceDisposable = (WhitegramAppearanceSettings.signal()
            |> deliverOnMainQueue).start(next: { [weak self] _ in
                guard let self else { return }
                self.chatDisplayNode.historyNode.refreshWhitegramAppearance()
                self.chatDisplayNode.updateChatPresentationInterfaceState(self.presentationInterfaceState, transition: .immediate, interactive: false, forceLayout: true, completion: { _ in })
            })
        }
""")


def apply_appearance_extensions(root: Path) -> dict[str, list[str]]:
    patches = SourcePatches(root)
    _bubble_patches(patches)
    _bubble_outline_patches(patches)
    _bubble_animation_patches(patches)
    _composer_patches(patches)
    _metadata_patches(patches)
    _chat_refresh_patches(patches)
    return patches.write()
