"""Backport the 3.2 Return-key policy to both composer engines and captions."""

from source_patches import SourcePatches

PANEL = "submodules/TelegramUI/Components/Chat/ChatTextInputPanelNode/Sources/ChatTextInputPanelNode.swift"
CAPTION = "submodules/AttachmentTextInputPanelNode/Sources/AttachmentTextInputPanelNode.swift"
INPUT = "submodules/TelegramUI/Components/Chat/ChatInputTextNode/Sources/ChatInputTextNode.swift"
SEAM = "submodules/TelegramUI/Components/Chat/ChatInputTextNode/Sources/ChatRichTextInputNode.swift"
NATIVE = "submodules/TelegramUI/Components/Chat/ChatRichTextEditorComposer/Sources/RichTextEditorChatInputNode.swift"
EDITOR = "submodules/TelegramUI/Components/RichTextEditor/Sources/RichTextEditorUIKit/RichTextEditorView.swift"
CANVAS = "submodules/TelegramUI/Components/RichTextEditor/Sources/RichTextEditorUIKit/Canvas/DocumentCanvasView.swift"
INSERT = "submodules/TelegramUI/Components/RichTextEditor/Sources/RichTextEditorUIKit/Canvas/DocumentCanvasView+UITextInput.swift"
LEGACY_KEYS = "submodules/TelegramUI/Components/Chat/ChatInputTextNode/ChatInputTextViewImpl/Sources/ChatInputTextViewImpl.m"
PATHS = (PANEL, CAPTION, INPUT, SEAM, NATIVE, EDITOR, CANVAS, INSERT, LEGACY_KEYS)


def _validate_declarations(patches):
    declarations = {
        PANEL: (("private var whitegramReturnKeyObserver:", 1), ("private func whitegramUpdateReturnKey()", 1)),
        CAPTION: (("private var whitegramReturnKeyObserver:", 1), ("private func whitegramUpdateReturnKey()", 1)),
        INPUT: (("public private(set) var whitegramHandlingHardwareReturn", 1),),
        SEAM: (("var returnKeyType: UIReturnKeyType", 2),),
        NATIVE: (("public var returnKeyType: UIReturnKeyType", 1), ("self.editorView.onSoftwareReturn =", 1)),
        EDITOR: (("public var onSoftwareReturn:", 1), ("public var returnKeyType: UIReturnKeyType", 1)),
        CANVAS: (("var onSoftwareReturn:", 1), ("var returnKeyType: UIReturnKeyType", 1), ("private(set) var handlingHardwareReturn", 1)),
    }
    for path, expected in declarations.items():
        text = patches.read(path)
        for declaration, count in expected:
            if text.count(declaration) != count:
                raise ValueError(f"sendOnReturnKey: {path}: duplicate or partial declaration: {declaration}")


def apply_return_key_patches(root):
    patches = SourcePatches(root)

    def replace(path, before, after):
        patches.replace("sendOnReturnKey", path, before, after)

    replace(INPUT, "public final class ChatInputTextView: ChatInputTextViewImpl, UITextViewDelegate, NSLayoutManagerDelegate, NSTextStorageDelegate {\n",
            "public final class ChatInputTextView: ChatInputTextViewImpl, UITextViewDelegate, NSLayoutManagerDelegate, NSTextStorageDelegate {\n"
            "    public private(set) var whitegramHandlingHardwareReturn = false\n")
    replace(INPUT, "            return self.customDelegate?.chatInputTextNodeShouldReturn(modifierFlags: modifierFlags) ?? true\n",
            "            self.whitegramHandlingHardwareReturn = true\n"
            "            defer { self.whitegramHandlingHardwareReturn = false }\n"
            "            if self.markedTextRange != nil || (self.customDelegate?.chatInputTextNodeShouldReturn(modifierFlags: modifierFlags) ?? true) {\n"
            "                self.insertText(\"\\n\")\n"
            "            }\n            return false\n")
    replace(LEGACY_KEYS, "        plainReturn,\n        cmdReturn\n",
            "        plainReturn,\n        [UIKeyCommand keyCommandWithInput:@\"\\r\" modifierFlags:UIKeyModifierShift action:@selector(handleReturn:)],\n        cmdReturn\n")

    replace(SEAM, "    var keyboardInputView: UIView? { get set }\n",
            "    var keyboardInputView: UIView? { get set }\n    var returnKeyType: UIReturnKeyType { get set }\n")
    anchor = "    var keyboardInputView: UIView? {\n        get { return self.textInputNodeImpl.textView.inputView }\n"
    replace(SEAM, anchor, "    var returnKeyType: UIReturnKeyType {\n"
            "        get { return self.textInputNodeImpl.textView.returnKeyType }\n"
            "        set {\n            guard self.textInputNodeImpl.textView.returnKeyType != newValue else { return }\n"
            "            self.textInputNodeImpl.textView.returnKeyType = newValue\n"
            "            if self.textInputNodeImpl.textView.isFirstResponder { self.reloadInputViews() }\n        }\n    }\n\n" + anchor)
    anchor = "    public var keyboardInputView: UIView? {\n"
    replace(NATIVE, anchor, "    public var returnKeyType: UIReturnKeyType {\n"
            "        get { self.editorView.returnKeyType }\n        set { self.editorView.returnKeyType = newValue }\n    }\n\n" + anchor)
    anchor = "        self.editorView.onHardwareReturn = { [weak self] modifierFlags in\n"
    replace(NATIVE, anchor, "        self.editorView.onSoftwareReturn = { [weak self] in\n"
            "            guard WhitegramTextSettings.current.sendOnReturnKey else { return true }\n"
            "            return self?.storedDelegate?.chatInputTextNodeShouldReturn(modifierFlags: []) ?? true\n        }\n\n" + anchor)
    anchor = "    public var onHardwareReturn: ((UIKeyModifierFlags) -> Bool)? { didSet { canvas.onHardwareReturn = onHardwareReturn } }\n"
    replace(EDITOR, anchor, anchor + "    public var onSoftwareReturn: (() -> Bool)? { didSet { canvas.onSoftwareReturn = onSoftwareReturn } }\n"
            "    public var returnKeyType: UIReturnKeyType {\n        get { canvas.returnKeyType }\n        set {\n"
            "            guard canvas.returnKeyType != newValue else { return }\n            canvas.returnKeyType = newValue\n"
            "            if canvas.isFirstResponder { canvas.reloadInputViews() }\n        }\n    }\n")
    anchor = "    var onHardwareReturn: ((UIKeyModifierFlags) -> Bool)?\n"
    replace(CANVAS, anchor, anchor + "    var onSoftwareReturn: (() -> Bool)?\n"
            "    var returnKeyType: UIReturnKeyType = .default\n    private(set) var handlingHardwareReturn = false\n")
    anchor = '         UIKeyCommand(input: "\\r", modifierFlags: .command, action: #selector(handleReturnKey(_:))),\n'
    replace(CANVAS, anchor, anchor + '         UIKeyCommand(input: "\\r", modifierFlags: .shift, action: #selector(handleReturnKey(_:))),\n')
    replace(CANVAS, "         // keyCommands, so it still inserts a newline via insertText.\n",
            "         // keyCommands; insertText consults the separate software-Return hook.\n")
    replace(CANVAS, '        if onHardwareReturn?(modifierFlags) ?? true { insertText("\\n") }\n',
            '        handlingHardwareReturn = true\n        defer { handlingHardwareReturn = false }\n'
            '        if markedRange != nil || (onHardwareReturn?(modifierFlags) ?? true) { insertText("\\n") }\n')
    anchor = "        clearStructuralSelections()\n        // Caret on an image's gap cursor"
    replace(INSERT, anchor, '        if text == "\\n", selFrom == selTo, !handlingHardwareReturn, onSoftwareReturn?() == false { return }\n' + anchor)

    old = """            if let context = self.context, context.sharedContext.currentChatSettings.with({ $0 }).sendWithCmdEnter {
                if modifierFlags.contains(.command) {
                    shouldSendMessage = true
                }
            } else {
                if modifierFlags.isEmpty {
                    shouldSendMessage = true
                }
            }
"""
    replace(PANEL, old, """            let commandMode = self.context?.sharedContext.currentChatSettings.with({ $0 }).sendWithCmdEnter ?? false
            shouldSendMessage = WhitegramTextSettings.current.sendOnHardwareReturn(
                hasModifiers: !modifierFlags.isEmpty, commandPressed: modifierFlags.contains(.command), sendWithCommand: commandMode)
""")
    anchor = "        self.updateActivity()\n        var cleanText = text\n"
    replace(PANEL, anchor, """        let legacyInput = richTextInputNode.inputView as? ChatInputTextView
        if WhitegramTextSettings.current.sendOnSoftwareReturn(replacement: text, selectionLength: range.length,
            hasMarkedText: legacyInput?.markedTextRange != nil, handlingHardwareReturn: legacyInput?.whitegramHandlingHardwareReturn ?? false),
            !self.chatInputTextNodeShouldReturn(modifierFlags: []) {
            return false
        }

""" + anchor)

    old = """        if self.actionButtons.sendButton.supernode != nil && !self.actionButtons.sendButton.isHidden && !self.actionButtons.sendButton.alpha.isZero {
            self.sendButtonPressed()
        }
        return false
"""
    replace(CAPTION, old, """        if WhitegramTextSettings.current.sendOnReturnKey && modifierFlags.isEmpty,
            self.actionButtons.sendButton.supernode != nil && !self.actionButtons.sendButton.isHidden && !self.actionButtons.sendButton.alpha.isZero {
            self.sendButtonPressed()
            return false
        }
        return true
""")
    anchor = "    public func chatInputTextNode(shouldChangeTextIn range: NSRange, replacementText text: String) -> Bool {\n"
    replace(CAPTION, anchor, anchor + """        if WhitegramTextSettings.current.sendOnSoftwareReturn(replacement: text, selectionLength: range.length,
            hasMarkedText: self.textInputNode?.textView.markedTextRange != nil,
            handlingHardwareReturn: self.textInputNode?.textView.whitegramHandlingHardwareReturn ?? false),
            !self.chatInputTextNodeShouldReturn(modifierFlags: []) {
            return false
        }
""")
    for path, property_name, assign, update in (
        (PANEL, "richTextInputNode", "\n        richTextInputNode.keyboardAppearance = keyboardAppearance\n",
         "        self.richTextInputNode?.returnKeyType = WhitegramTextSettings.current.sendOnReturnKey ? .send : .default\n"),
        (CAPTION, "textInputNode", "\n        textInputNode.keyboardAppearance = keyboardAppearance\n",
         "        let type: UIReturnKeyType = WhitegramTextSettings.current.sendOnReturnKey ? .send : .default\n"
         "        if let node = self.textInputNode, node.textView.returnKeyType != type {\n"
         "            node.textView.returnKeyType = type\n            if node.isFirstResponder() { node.textView.reloadInputViews() }\n        }\n"),
    ):
        access = property_name + (".returnKeyType" if path == PANEL else ".textView.returnKeyType")
        replace(path, assign, assign + f"        {access} = WhitegramTextSettings.current.sendOnReturnKey ? .send : .default\n")
        anchor = "    deinit {\n"
        replace(path, anchor, "    private var whitegramReturnKeyObserver: NSObjectProtocol?\n\n"
                "    private func whitegramUpdateReturnKey() {\n" + update + "    }\n\n" + anchor)
        cleanup = ("        self.tooltipController?.dismiss()\n        self.currentEmojiSuggestion?.disposable.dispose()\n"
                   if path == PANEL else "    deinit {\n")
        replace(path, cleanup, cleanup + "        if let observer = self.whitegramReturnKeyObserver { NotificationCenter.default.removeObserver(observer) }\n")
        registration = "        if self.whitegramReturnKeyObserver == nil {\n"
        registration += "            self.whitegramReturnKeyObserver = NotificationCenter.default.addObserver(forName: WhitegramPreferences.updatedNotification, object: nil, queue: .main) { [weak self] _ in\n"
        registration += "                self?.whitegramUpdateReturnKey()\n            }\n        }\n"
        anchor = ("    private func loadTextInputNode(useNative: Bool = false) {\n"
                  if path == PANEL else "    public func loadTextInputNodeIfNeeded() {\n")
        replace(path, anchor, anchor + registration)
    _validate_declarations(patches)
    return patches.write()
