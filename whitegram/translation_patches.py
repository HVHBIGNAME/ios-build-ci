"""Global translation selection and review-before-send on pinned Telegram sources."""

from pathlib import Path

from source_patches import SourcePatches


TRANSLATION_RUNTIME_FILES = {
    "WhitegramTranslationSettings.swift": "submodules/TelegramCore/Sources/WhitegramTranslationSettings.swift",
    "WhitegramTranslationDraftGuard.swift": "submodules/TelegramCore/Sources/WhitegramTranslationDraftGuard.swift",
    "WhitegramTranslationTextRules.swift": "submodules/TelegramCore/Sources/WhitegramTranslationTextRules.swift",
    "WhitegramTranslationGoogle.swift": "submodules/TelegramCore/Sources/WhitegramTranslationGoogle.swift",
    "WhitegramTranslationMessageBatch.swift": "submodules/TelegramCore/Sources/WhitegramTranslationMessageBatch.swift",
    "WhitegramTranslationService.swift": "submodules/TranslateUI/Sources/WhitegramTranslationService.swift",
    "WhitegramTranslationApple.swift": "submodules/TranslateUI/Sources/WhitegramTranslationApple.swift",
    "WhitegramTranslationSendCoordinator.swift": "submodules/TelegramUI/Sources/WhitegramTranslationSendCoordinator.swift",
    "WhitegramTranslationSettingsController.swift": "submodules/SettingsUI/Sources/WhitegramTranslationSettingsController.swift",
}
NODE = "submodules/TelegramUI/Sources/ChatControllerNode.swift"
CONTROLLER = "submodules/TelegramUI/Sources/ChatController.swift"
HISTORY = "submodules/TelegramUI/Sources/ChatHistoryListNode.swift"
STATE = "submodules/TranslateUI/Sources/ChatTranslation.swift"
SCREEN = "submodules/TranslateUI/Sources/TranslateScreen.swift"
CORE = "submodules/TelegramCore/Sources/TelegramEngine/Messages/Translate.swift"
FILE_NODE = "submodules/TelegramUI/Components/Chat/ChatMessageInteractiveFileNode/Sources/ChatMessageInteractiveFileNode.swift"
VIDEO_NODE = "submodules/TelegramUI/Components/Chat/ChatMessageInteractiveInstantVideoNode/Sources/ChatMessageInteractiveInstantVideoNode.swift"
SEND_OPTIONS = "submodules/TelegramUI/Sources/Chat/ChatMessageDisplaySendMessageOptions.swift"
SEND_PARAMS = "submodules/ChatSendMessageActionUI/Sources/ChatSendMessageActionSheetController.swift"
SEND_SCREEN = "submodules/ChatSendMessageActionUI/Sources/ChatSendMessageContextScreen.swift"

STATE_HELPER = """    private let whitegramTranslationSend = WhitegramTranslationSendCoordinator()

    func cancelWhitegramTranslation() {
        self.whitegramTranslationSend.cancel()
    }

    private func whitegramTranslationCurrentState() -> ChatPresentationInterfaceState {
        var state = self.controller?.presentationInterfaceState ?? self.chatPresentationInterfaceState
        if let input = self.textInputPanelNode {
            state = state.updatedInterfaceState { $0.withUpdatedEffectiveInputState(input.inputTextState) }
        }
        return state
    }

"""
INTERCEPT = """        if self.whitegramTranslationSend.intercept(context: self.context, state: effectivePresentationInterfaceState,
            controller: self.controller, current: { [weak self] in self?.whitegramTranslationCurrentState() },
            apply: { [weak self] replacement in
                self?.controller?.updateChatPresentationInterfaceState(interactive: true, saveInterfaceState: true, {
                    $0.updatedInterfaceState { $0.withUpdatedComposeInputState(replacement) }
                })
            }) {
            return
        }

"""


def _replace(patches: SourcePatches, path: str, before: str, after: str, count: int = 1) -> None:
    value = patches.read(path)
    applied = value.count(after)
    if applied and (applied != count or before in value.replace(after, "")):
        raise ValueError(f"translation: {path}: ambiguous partially applied edit")
    patches.replace("translation", path, before, after, count=count)


def _provider_and_voice_patches(patches: SourcePatches) -> None:
    before = """        let googleTranslate: () -> Signal<Never, TranslationError> = {
            engineExperimentalInternalTranslationService = ExperimentalGoogleTranslationServiceImpl()
            return context.engine.messages.translateMessages(messageIds: messageIdsToTranslate, fromLang: fromLang ?? "auto", toLang: toLang, enableLocalIfPossible: true)
        }
"""
    after = """        let googleTranslate: () -> Signal<Never, TranslationError> = {
            return whitegramTranslateReceivedMessages(context: context, messageIds: messageIdsToTranslate, toLang: toLang, provider: .gTranslate)
        }
"""
    _replace(patches, STATE, before, after)
    before = """        case .telegram:
            signal = context.engine.messages.translateMessages(messageIds: messageIdsToTranslate, fromLang: fromLang, toLang: toLang, enableLocalIfPossible: false)
            |> `catch` { _ -> Signal<Never, TranslationError> in
                return googleTranslate()
            }
        }
"""
    after = """        case .telegram:
            signal = context.engine.messages.translateMessages(messageIds: messageIdsToTranslate, fromLang: fromLang, toLang: toLang, enableLocalIfPossible: false)
        }
"""
    _replace(patches, STATE, before, after)
    before = """        let signal: Signal<Never, TranslationError>
        switch whiteGramOtherSettings.translationService {
"""
    after = """        let signal: Signal<Never, TranslationError>
        let whitegramSettings = WhitegramTranslationSettings.current
        if whitegramSettings.appleTranslationRequested || whitegramSettings.localTranslationRequested {
            // Apple selection is handled inside the adapter and never enters the network fallback.
            return whitegramTranslateReceivedMessages(context: context, messageIds: messageIdsToTranslate, toLang: toLang, provider: .gTranslate)
            |> `catch` { _ -> Signal<Never, NoError> in return .complete() }
        }
        switch whiteGramOtherSettings.translationService {
"""
    _replace(patches, STATE, before, after)
    for path in (STATE, HISTORY, CORE):
        before = "if let audioTranscription = message.attributes.first(where: { $0 is AudioTranscriptionMessageAttribute }) as? AudioTranscriptionMessageAttribute, !audioTranscription.text.isEmpty && !audioTranscription.isPending {"
        after = before.replace("if let audioTranscription", "if WhitegramTranslationSettings.current.translateTranscripts, let audioTranscription")
        _replace(patches, path, before, after)
    before = "if let translateToLanguage = arguments.associatedData.translateToLanguage, !text.isEmpty && arguments.incoming {"
    after = before.replace("if let translateToLanguage", "if WhitegramTranslationSettings.current.translateTranscripts, let translateToLanguage")
    _replace(patches, FILE_NODE, before, after)
    for path, interaction in ((FILE_NODE, "arguments.controllerInteraction"), (VIDEO_NODE, "item.controllerInteraction")):
        before = "guard WhiteGramOtherSettings.current.voiceTranscription else {"
        after = "guard WhitegramTranslationSettings.current.transcriptionEnabled(nativeEnabled: WhiteGramOtherSettings.current.voiceTranscription) else {"
        _replace(patches, path, before, after)
        before = "let whiteGramVoiceTranscription = WhiteGramOtherSettings.current.voiceTranscription"
        after = "let whiteGramVoiceTranscription = WhitegramTranslationSettings.current.transcriptionEnabled(nativeEnabled: WhiteGramOtherSettings.current.voiceTranscription)"
        _replace(patches, path, before, after)
        before = "if !WhiteGramOtherSettings.current.voiceTranscription, transcribedText == nil,"
        after = "if !WhitegramTranslationSettings.current.transcriptionEnabled(nativeEnabled: WhiteGramOtherSettings.current.voiceTranscription), transcribedText == nil,"
        _replace(patches, path, before, after)
        before = "let whiteGramAppleTranscription = whiteGramOtherSettings.voiceTranscription && whiteGramOtherSettings.transcriptionService == .apple"
        after = "let whiteGramAppleTranscription = WhitegramTranslationSettings.current.usesAppleTranscription(nativeEnabled: whiteGramOtherSettings.voiceTranscription, appleSelected: whiteGramOtherSettings.transcriptionService == .apple)"
        _replace(patches, path, before, after)
        before = "let whiteGramTelegramTranscription = whiteGramOtherSettings.voiceTranscription && whiteGramOtherSettings.transcriptionService == .telegram"
        after = "let whiteGramTelegramTranscription = !WhitegramTranslationSettings.current.voiceTranslationRequested && whiteGramOtherSettings.voiceTranscription && whiteGramOtherSettings.transcriptionService == .telegram"
        _replace(patches, path, before, after)
        _replace(patches, path, "if whiteGramOtherSettings.transcriptionService == .apple {", "if whiteGramAppleTranscription {")
        before = """        if shouldBeginTranscription {
            if self.transcribeDisposable == nil {
"""
        notice = f'''            if whiteGramAppleTranscription, self.transcribeDisposable == nil, WhitegramTranslationSettings.claimSiriWarning() {{
                let whitegramSiriNotice = UndoOverlayController(presentationData: presentationData, content: .universal(animation: "anim_voiceToText", scale: 0.065, colors: [:], title: "Siri / Dictation", text: WhitegramLocalization.string("transcription.siriPrivacy", baseLanguage: presentationData.strings.baseLanguageCode), customUndoText: nil, timeout: 5.0), elevatedLayout: false, position: .top, animateInAsReplacement: false, action: {{ _ in false }})
                {interaction}.presentControllerInCurrent(whitegramSiriNotice, nil)
            }}
'''
        after = before.replace("            if self.transcribeDisposable == nil {", notice + "            if self.transcribeDisposable == nil {")
        _replace(patches, path, before, after)


def _manual_provider_patches(patches: SourcePatches) -> None:
    before = "        var translatedText: (String, [MessageTextEntity])?\n"
    _replace(patches, SCREEN, before, before + "        var whitegramTranslationFailed = false\n")
    before = """        func translate(text: String, entities: [MessageTextEntity], fromLang: String?, toLang: String) -> Signal<(String, [MessageTextEntity])?, TranslationError> {
            switch self.translationService {
            case .gTranslate:
                return alternativeTranslateText(text: text, fromLang: fromLang, toLang: toLang)
            case .telegram:
                return self.context.engine.messages.translate(text: text, toLang: toLang, entities: entities, tone: self.tone)
                |> `catch` { _ -> Signal<(String, [MessageTextEntity])?, TranslationError> in
                    return alternativeTranslateText(text: text, fromLang: fromLang, toLang: toLang)
                }
            }
        }
"""
    after = """        func translate(text: String, entities: [MessageTextEntity], fromLang: String?, toLang: String) -> Signal<(String, [MessageTextEntity])?, TranslationError> {
            self.whitegramTranslationFailed = false
            let settings = WhitegramTranslationSettings.current
            if settings.appleTranslationRequested && self.tone != .neutral { return .fail(.generic) }
            if settings.appleTranslationRequested || (self.tone == .neutral && (settings.localTranslationRequested || self.translationService == .gTranslate)) {
                return whitegramTranslateDraft(context: self.context, text: text, entities: entities, toLang: toLang, provider: .gTranslate, fromLang: fromLang)
                |> map { Optional(($0.text, $0.entities)) }
                |> mapError { _ in TranslationError.generic }
            }
            // Original local dispatch uses Telegram's structured API for a requested non-neutral tone.
            return self.context.engine.messages.translate(text: text, toLang: toLang, entities: entities, tone: self.tone)
        }
"""
    _replace(patches, SCREEN, before, after)
    before = "            }, error: { error in\n" + " " * 16 + "\n            }))\n"
    after = """            }, error: { [weak self] _ in
                self?.whitegramTranslationFailed = true
                self?.updated(transition: .immediate)
            }))
"""
    _replace(patches, SCREEN, before, after, count=3)
    before = """            } else {
                maybeTranslationPlaceholder = translationPlaceholder.update(
"""
    after = """            } else if state.whitegramTranslationFailed {
                maybeTranslationText = translationText.update(
                    component: MultilineTextComponent(text: .plain(NSAttributedString(string: "Translation failed. Check the selected provider and language pair in Whitegram Translation settings, then try again. Apple requires iOS 18 and supported language models; tone changes require Telegram.", font: textFont, textColor: theme.list.itemSecondaryTextColor)), horizontalAlignment: .natural, maximumNumberOfLines: 0),
                    availableSize: CGSize(width: context.availableSize.width - (sideInset + textSideInset) * 2.0 - 30.0, height: context.availableSize.height),
                    transition: .immediate
                )
                translationTextHeight = maybeTranslationText?.size.height ?? 0.0
            } else {
                maybeTranslationPlaceholder = translationPlaceholder.update(
"""
    _replace(patches, SCREEN, before, after)
    before = "        if toLanguage == fromLanguage {\n"
    _replace(patches, SCREEN, before, "        if toLanguage == fromLanguage && !WhitegramTranslationSettings.current.hasGlobalTarget {\n")
    before = "        toLanguage = normalizeTranslationLanguage(toLanguage)\n"
    _replace(patches, SCREEN, before, "        if !WhitegramTranslationSettings.current.hasGlobalTarget { toLanguage = normalizeTranslationLanguage(toLanguage) }\n")
    before = "                        replaceText(state.translatedText?.0 ?? state.text, state.translatedText?.1 ?? state.entities)"
    _replace(patches, SCREEN, before, "                        guard let translatedText = state.translatedText else { return }\n                        replaceText(translatedText.0, translatedText.1)")
    before = '                        copyTranslation(state.translatedText?.0 ?? "", state.translatedText?.1 ?? [])'
    _replace(patches, SCREEN, before, "                        guard let translatedText = state.translatedText else { return }\n                        copyTranslation(translatedText.0, translatedText.1)")


def _send_option_patches(patches: SourcePatches) -> None:
    method = """    func sendWhitegramTranslation(messageEffect: ChatSendMessageEffect?) {
        let _ = self.whitegramTranslationSend.intercept(context: self.context, state: self.whitegramTranslationCurrentState(),
            controller: self.controller, current: { [weak self] in self?.whitegramTranslationCurrentState() },
            apply: { [weak self] replacement in
                self?.controller?.updateChatPresentationInterfaceState(interactive: true, saveInterfaceState: true, {
                    $0.updatedInterfaceState { $0.withUpdatedComposeInputState(replacement) }
                })
            }, sendTranslated: { [weak self] in
                self?.controller?.controllerInteraction?.sendCurrentMessage(false, messageEffect)
            })
    }

"""
    _replace(patches, NODE, STATE_HELPER, STATE_HELPER + method)
    anchor = "        public let canSendWhenOnline: Bool\n"
    _replace(patches, SEND_PARAMS, anchor, anchor + "        public let whitegramTranslate: ((ChatSendMessageActionSheetController.SendParameters?) -> Void)?\n")
    before = "            isMonoforum: Bool\n"
    after = "            isMonoforum: Bool,\n            whitegramTranslate: ((ChatSendMessageActionSheetController.SendParameters?) -> Void)? = nil\n"
    _replace(patches, SEND_PARAMS, before, after)
    anchor = "            self.canSendWhenOnline = canSendWhenOnline\n"
    _replace(patches, SEND_PARAMS, anchor, anchor + "            self.whitegramTranslate = whitegramTranslate\n")
    before = "                    isMonoforum: selfController.presentationInterfaceState.renderedPeer?.peer?.isMonoForum ?? false\n"
    after = """                    isMonoforum: selfController.presentationInterfaceState.renderedPeer?.peer?.isMonoForum ?? false,
                    whitegramTranslate: { [weak selfController] parameters in
                        selfController?.chatDisplayNode.sendWhitegramTranslation(messageEffect: parameters?.effect.flatMap(ChatSendMessageEffect.init))
                    }
"""
    _replace(patches, SEND_OPTIONS, before, after)
    anchor = """                if canSchedule {
                    items.append(.action(ContextMenuActionItem(
                        id: AnyHashable("schedule"),
"""
    action = """                if let translate = sendMessage.whitegramTranslate, WhitegramTranslationSettings.current.showsSendAction,
                   sendMessage.mediaPreview == nil, !sendMessage.attachment,
                   !textString.string.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                    items.append(.action(ContextMenuActionItem(
                        id: AnyHashable("whitegramTranslate"),
                        text: WhitegramLocalization.string("messageAction.withTranslation", baseLanguage: environment.strings.baseLanguageCode),
                        icon: { theme in
                            return generateTintedImage(image: UIImage(systemName: "translate"), color: theme.contextMenu.primaryColor)
                        }, action: { [weak self] _, _ in
                            guard let self else { return }
                            let parameters = ChatSendMessageActionSheetController.SendParameters(
                                effect: self.selectedMessageEffect.flatMap({ ChatSendMessageActionSheetController.SendParameters.Effect(id: $0.id) }),
                                textIsAboveMedia: self.mediaCaptionIsAbove
                            )
                            self.environment?.controller()?.dismiss()
                            translate(parameters)
                        }
                    )))
                }
"""
    _replace(patches, SEND_SCREEN, anchor, action + anchor)


def translation_patches(patches: SourcePatches) -> None:
    anchor = "    private weak var controller: ChatControllerImpl?\n"
    _replace(patches, NODE, anchor, anchor + STATE_HELPER)
    anchor = "        self.selectedMessages = chatPresentationInterfaceState.interfaceState.selectionState?.selectedIds\n"
    _replace(patches, NODE, anchor, anchor + "        self.whitegramTranslationSend.observe(chatPresentationInterfaceState)\n")
    anchor = "        if let _ = effectivePresentationInterfaceState.interfaceState.editMessage, effectivePresentationInterfaceState.interfaceState.postSuggestionState == nil {\n"
    _replace(patches, NODE, anchor, INTERCEPT + anchor)
    anchor = "    override public func viewWillDisappear(_ animated: Bool) {\n"
    _replace(patches, CONTROLLER, anchor, anchor + "        if self.isNodeLoaded { self.chatDisplayNode.cancelWhitegramTranslation() }\n")
    anchor = "            translationState = chatTranslationState(context: context, peerId: peerId, threadId: self.chatLocation.threadId)\n"
    _replace(patches, HISTORY, anchor, """            let translationThreadId = self.chatLocation.threadId
            translationState = whitegramTranslationSettingsSignal()
            |> mapToSignal { _ in
                return chatTranslationState(context: context, peerId: peerId, threadId: translationThreadId)
            }
""")
    anchor = "                    var languageCode = whiteGramOtherSettings.autoTranslate ? chatPresentationData.strings.baseLanguageCode : (translationState.toLang ?? chatPresentationData.strings.baseLanguageCode)\n"
    _replace(patches, HISTORY, anchor, "                    let defaultTranslationLanguage = whitegramTranslationTarget(defaultLanguage: chatPresentationData.strings.baseLanguageCode)\n"
             + "                    var languageCode = whiteGramOtherSettings.autoTranslate ? defaultTranslationLanguage : (translationState.toLang ?? defaultTranslationLanguage)\n")
    anchor = "        var baseLang = context.sharedContext.currentPresentationData.with { $0 }.strings.baseLanguageCode\n"
    _replace(patches, STATE, anchor, "        var baseLang = whitegramTranslationTarget(defaultLanguage: context.sharedContext.currentPresentationData.with { $0 }.strings.baseLanguageCode)\n")
    anchor = "        var toLanguage = toLanguage ?? baseLanguageCode\n"
    _replace(patches, SCREEN, anchor, "        var toLanguage = toLanguage ?? whitegramTranslationTarget(defaultLanguage: baseLanguageCode)\n")
    _provider_and_voice_patches(patches)
    _manual_provider_patches(patches)
    _send_option_patches(patches)


def apply_translation_patches(root: Path) -> dict[str, list[str]]:
    patches = SourcePatches(root)
    translation_patches(patches)
    return patches.write()
