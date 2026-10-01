"""Global translation selection and review-before-send on pinned Telegram sources."""

from pathlib import Path

from source_patches import SourcePatches


TRANSLATION_RUNTIME_FILES = {
    "WhitegramTranslationSettings.swift": "submodules/TelegramCore/Sources/WhitegramTranslationSettings.swift",
    "WhitegramTranslationDraftGuard.swift": "submodules/TelegramCore/Sources/WhitegramTranslationDraftGuard.swift",
    "WhitegramTranslationTextRules.swift": "submodules/TelegramCore/Sources/WhitegramTranslationTextRules.swift",
    "WhitegramTranslationService.swift": "submodules/TranslateUI/Sources/WhitegramTranslationService.swift",
    "WhitegramTranslationSendCoordinator.swift": "submodules/TelegramUI/Sources/WhitegramTranslationSendCoordinator.swift",
    "WhitegramTranslationSettingsController.swift": "submodules/SettingsUI/Sources/WhitegramTranslationSettingsController.swift",
}
NODE = "submodules/TelegramUI/Sources/ChatControllerNode.swift"
CONTROLLER = "submodules/TelegramUI/Sources/ChatController.swift"
HISTORY = "submodules/TelegramUI/Sources/ChatHistoryListNode.swift"
STATE = "submodules/TranslateUI/Sources/ChatTranslation.swift"
SCREEN = "submodules/TranslateUI/Sources/TranslateScreen.swift"

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


def _replace(patches: SourcePatches, path: str, before: str, after: str) -> None:
    value = patches.read(path)
    applied = value.count(after)
    if applied and (applied != 1 or before in value.replace(after, "")):
        raise ValueError(f"translation: {path}: ambiguous partially applied edit")
    patches.replace("translation", path, before, after)


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


def apply_translation_patches(root: Path) -> dict[str, list[str]]:
    patches = SourcePatches(root)
    translation_patches(patches)
    return patches.write()
