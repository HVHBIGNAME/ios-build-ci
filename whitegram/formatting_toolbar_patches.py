"""Install a keyboard formatting toolbar through the chat input panel's layout."""

from source_patches import SourcePatches

PANEL = "submodules/TelegramUI/Components/Chat/ChatTextInputPanelNode/Sources/ChatTextInputPanelNode.swift"
FORMATTING_TOOLBAR_RUNTIME_FILES = {
    "WhitegramFormattingToolbar.swift": "submodules/TelegramUI/Components/Chat/ChatTextInputPanelNode/Sources/WhitegramFormattingToolbar.swift",
}

METHODS = '''    private func whitegramUpdateFormattingToolbar(width: CGFloat, leftInset: CGFloat, rightInset: CGFloat, y: CGFloat, interfaceState: ChatPresentationInterfaceState) -> CGFloat {
        let visible = WhitegramTextSettings.current.formattingToolbar && self.isFocused && !self.sendingTextDisabled && self.richTextInputNode?.keyboardInputView == nil && interfaceState.inputTextPanelState.mediaRecordingState == nil
        guard visible else {
            self.whitegramFormattingToolbar?.isHidden = true
            return 0.0
        }
        let toolbar: WhitegramFormattingToolbar
        if let current = self.whitegramFormattingToolbar {
            toolbar = current
        } else {
            toolbar = WhitegramFormattingToolbar(frame: .zero)
            toolbar.action = { [weak self] action in self?.whitegramFormattingAction(action) }
            self.whitegramFormattingToolbar = toolbar
            self.view.addSubview(toolbar)
        }
        toolbar.isHidden = false
        toolbar.frame = CGRect(x: leftInset, y: y, width: max(0.0, width - leftInset - rightInset), height: 44.0)
        let state = self.whitegramFormattingState(interfaceState: interfaceState)
        toolbar.update(theme: interfaceState.theme, strings: interfaceState.strings, enabled: state.enabled, selected: state.selected)
        return 44.0
    }

    private func whitegramFormattingState(interfaceState: ChatPresentationInterfaceState) -> (enabled: Set<WhitegramFormattingAction>, selected: Set<WhitegramFormattingAction>) {
        var enabled = Set(WhitegramFormattingAction.allCases)
        var selected = Set<WhitegramFormattingAction>()
        if self.inputTextState.isEmpty {
            enabled.subtract([.clear, .selectAll, .speak, .bold, .italic, .strike, .monospace, .underline, .spoiler, .link, .quote, .collapsedQuote, .codeBlock, .clearFormatting])
        }
        if let editor = self.richTextInputNode?.inputView as? RichTextEditorView {
            let state = editor.currentState()
            if !state.canUndo { enabled.remove(.undo) }
            if !state.canRedo { enabled.remove(.redo) }
            for (action, active) in [(WhitegramFormattingAction.bold, state.bold), (.italic, state.italic),
                (.underline, state.underline), (.strike, state.strikethrough), (.monospace, state.code),
                (.spoiler, state.spoiler), (.link, state.link != nil), (.quote, state.blockQuoteDepth > 0), (.codeBlock, state.isCodeBlock)] {
                if active { selected.insert(action) }
            }
            if state.code || state.isCodeBlock { enabled.remove(.spoiler) }
            if state.spoiler { enabled.remove(.monospace) }
            if !self.inputTextState.content.isEntityExpressible() {
                enabled.subtract([.collapsedQuote, .clearFormatting])
            }
        } else {
            if self.richTextInputNode?.inputView.undoManager?.canUndo != true { enabled.remove(.undo) }
            if self.richTextInputNode?.inputView.undoManager?.canRedo != true { enabled.remove(.redo) }
            let input = self.inputTextState
            let range = input.selectionRange.isEmpty ? NSRange(location: 0, length: input.inputText.length) : NSRange(location: input.selectionRange.lowerBound, length: input.selectionRange.count)
            if range.length > 0, range.location >= 0, NSMaxRange(range) <= input.inputText.length {
                for (action, key) in [(WhitegramFormattingAction.bold, ChatTextInputAttributes.bold), (.italic, ChatTextInputAttributes.italic),
                    (.strike, ChatTextInputAttributes.strikethrough), (.monospace, ChatTextInputAttributes.monospace),
                    (.underline, ChatTextInputAttributes.underline), (.spoiler, ChatTextInputAttributes.spoiler), (.link, ChatTextInputAttributes.textUrl)] {
                    var all = true
                    input.inputText.enumerateAttribute(key, in: range) { value, _, _ in if value == nil { all = false } }
                    if all { selected.insert(action) }
                }
                input.inputText.enumerateAttributes(in: range) { attributes, _, _ in
                    if attributes[ChatTextInputAttributes.monospace] != nil { enabled.remove(.spoiler) }
                    if attributes[ChatTextInputAttributes.spoiler] != nil { enabled.remove(.monospace) }
                    if let block = attributes[ChatTextInputAttributes.block] as? ChatTextInputTextQuoteAttribute, case .code = block.kind {
                        enabled.remove(.spoiler)
                    }
                }
            }
        }
        if interfaceState.chatLocation.peerId?.namespace == Namespaces.Peer.SecretChat {
            enabled.subtract([.spoiler, .quote, .collapsedQuote])
        }
        return (enabled, selected)
    }

    private func whitegramFormattingAction(_ action: WhitegramFormattingAction) {
        guard let node = self.richTextInputNode, let interfaceState = self.presentationInterfaceState,
            node.isInputFirstResponder, !self.sendingTextDisabled, WhitegramTextSettings.current.formattingToolbar,
            self.whitegramFormattingToolbar?.isHidden == false,
            self.whitegramFormattingState(interfaceState: interfaceState).enabled.contains(action) else { return }
        node.applyAutocorrection()
        if action == .undo || action == .redo {
            if let editor = node.inputView as? RichTextEditorView {
                if action == .undo { editor.undo() } else { editor.redo() }
            } else {
                if action == .undo { node.inputView.undoManager?.undo() } else { node.inputView.undoManager?.redo() }
                self.chatInputTextNodeDidUpdateText()
            }
            return
        }
        if action == .clear {
            if let editor = node.inputView as? RichTextEditorView {
                editor.selectAll()
                editor.deleteBackward()
            } else if let textView = node.inputView as? UITextView {
                textView.selectedRange = NSRange(location: 0, length: textView.text.utf16.count)
                textView.insertText("")
            }
            return
        }
        if action == .selectAll {
            if let editor = node.inputView as? RichTextEditorView { editor.selectAll() }
            else {
                node.selectedRange = NSRange(location: 0, length: node.attributedText?.length ?? 0)
                self.chatInputTextNodeDidChangeSelection(dueToEditing: false)
            }
            return
        }
        if node.selectedRange.length == 0 {
            if let editor = node.inputView as? RichTextEditorView { editor.selectAll() }
            else {
                node.selectedRange = NSRange(location: 0, length: node.attributedText?.length ?? 0)
                self.chatInputTextNodeDidChangeSelection(dueToEditing: false)
            }
        }
        if action == .link {
            self.interfaceInteraction?.openLinkEditing()
            return
        }
        if action == .speak {
            if node.usesNativeRichTextEngine, let context = self.context {
                if let holder = speakText(context: context, text: node.selectedRichText()) {
                    holder.completion = { [weak self, weak holder] in
                        if self?.currentSpeechHolder === holder { self?.currentSpeechHolder = nil }
                    }
                    self.currentSpeechHolder = holder
                }
            } else {
                self._accessibilitySpeak(self)
            }
            return
        }
        let format: ChatRichTextFormatAction?
        switch action {
        case .bold: format = .bold
        case .italic: format = .italic
        case .strike: format = .strikethrough
        case .monospace: format = .monospace
        case .underline: format = .underline
        case .spoiler: format = .spoiler
        case .quote: format = .quote
        case .codeBlock: format = .code
        default: format = nil
        }
        if node.usesNativeRichTextEngine, let format {
            node.performFormatAction(format)
            return
        }
        let input = self.inputTextState
        guard input.content.isEntityExpressible() else { return }
        let key: NSAttributedString.Key?
        var value: Any?
        switch action {
        case .bold: key = ChatTextInputAttributes.bold
        case .italic: key = ChatTextInputAttributes.italic
        case .strike: key = ChatTextInputAttributes.strikethrough
        case .monospace: key = ChatTextInputAttributes.monospace
        case .underline: key = ChatTextInputAttributes.underline
        case .spoiler: key = ChatTextInputAttributes.spoiler
        case .quote, .collapsedQuote:
            key = ChatTextInputAttributes.block
            value = ChatTextInputTextQuoteAttribute(kind: .quote, isCollapsed: action == .collapsedQuote)
        case .codeBlock:
            key = ChatTextInputAttributes.block
            value = ChatTextInputTextQuoteAttribute(kind: .code(language: nil), isCollapsed: false)
        default: key = nil
        }
        self.inputMenu.back()
        self.interfaceInteraction?.updateTextInputStateAndMode { _, mode in
            if action == .clearFormatting { return (chatTextInputClearFormattingAttributes(input), mode) }
            guard let key else { return (input, mode) }
            return (chatTextInputAddFormattingAttribute(input, attribute: key, value: value), mode)
        }
    }

'''


def apply_formatting_toolbar_patches(root):
    patches = SourcePatches(root)

    def append(anchor, text):
        patches.replace("formattingToolbarEnabled", PANEL, anchor, anchor + text)

    append("    public private(set) var richTextInputNode: ChatRichTextInputNode?\n",
           "    private var whitegramFormattingToolbar: WhitegramFormattingToolbar?\n"
           "    private var whitegramFormattingToolbarHeight: CGFloat = 0.0\n"
           "    private var whitegramFormattingObservers: [NSObjectProtocol] = []\n")
    append("    override public func didLoad() {\n        super.didLoad()\n",
           "        for name in [WhitegramPreferences.updatedNotification, WhitegramLocalizationStore.changedNotification] {\n"
           "            self.whitegramFormattingObservers.append(NotificationCenter.default.addObserver(forName: name, object: nil, queue: .main) { [weak self] _ in\n"
           "                self?.updateHeight(true)\n                self?.requestLayout()\n            })\n        }\n")
    append("    deinit {\n        self.statusDisposable.dispose()\n",
           "        for observer in self.whitegramFormattingObservers { NotificationCenter.default.removeObserver(observer) }\n")
    append("    public func chatInputTextNodeDidBeginEditing() {\n",
           "        self.updateHeight(true)\n")
    append("    public func chatInputTextNodeDidFinishEditing() {\n",
           "        self.whitegramFormattingToolbar?.isHidden = true\n        self.updateHeight(true)\n")
    anchor = "        return contentHeight\n    }\n"
    patches.replace("formattingToolbarEnabled", PANEL, anchor,
                     "        self.whitegramFormattingToolbarHeight = self.whitegramUpdateFormattingToolbar(width: width, leftInset: leftInset, rightInset: rightInset, y: contentHeight, interfaceState: interfaceState)\n"
                     "        return contentHeight + self.whitegramFormattingToolbarHeight\n    }\n")
    anchor = "            if !self.bounds.size.height.isEqual(to: panelHeight) {\n"
    patches.replace("formattingToolbarEnabled", PANEL, anchor, anchor.replace("panelHeight)", "panelHeight + self.whitegramFormattingToolbarHeight)"))
    append("    public func chatInputTextNodeDidChangeSelection(dueToEditing: Bool) {\n",
           "        if self.whitegramFormattingToolbar?.isHidden == false { self.requestLayout() }\n")
    anchor = "    @objc private func slowModeButtonPressed() {\n"
    patches.replace("formattingToolbarEnabled", PANEL, anchor, METHODS + anchor)
    append("    override public func hitTest(_ point: CGPoint, with event: UIEvent?) -> UIView? {\n",
           "        if let toolbar = self.whitegramFormattingToolbar, !toolbar.isHidden, let result = toolbar.hitTest(self.view.convert(point, to: toolbar), with: event) {\n"
           "            return result\n        }\n")
    return patches.write()
