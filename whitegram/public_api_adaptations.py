"""Counted adaptations of WhiteGram db18308774 to Telegram release-12.9.2.

Run after the public three-way merge and compatibility imports. API evidence and
the provenance of the restored translation helpers are in PUBLIC_API_REVIEW.md.
"""

from pathlib import Path

from source_patches import SourcePatches


CHAT = "submodules/TelegramUI/Components/Chat/"
TRANSLATE_SCREEN = "submodules/TranslateUI/Sources/TranslateScreen.swift"
CHAT_LIST_CONTROLLER = "submodules/ChatListUI/Sources/ChatListController.swift"
PASSKEYS_SCREEN = "submodules/TelegramUI/Components/Settings/PasskeysScreen/Sources/PasskeysScreen.swift"


def adapt_message_reactions(patches: SourcePatches) -> None:
    for node, message in (
        ("ChatMessageBubbleItemNode", "target.message"),
        ("ChatMessageAnimatedStickerItemNode", "item.message"),
        ("ChatMessageStickerItemNode", "item.message"),
    ):
        # Include the fork's switch arm: upstream already contains wrapped calls.
        patches.replace(
            "double-tap-reaction-engine-message",
            f"{CHAT}{node}/Sources/{node}.swift",
            f"        case .reaction:\n            if canAddMessageReactions(message: {message}) {{",
            f"        case .reaction:\n            if canAddMessageReactions(message: EngineMessage({message})) {{",
            count=2,
        )


def adapt_translation_button(patches: SourcePatches) -> None:
    path = CHAT + "ChatMessageBubbleItemNode/Sources/ChatMessageBubbleItemNode.swift"
    patches.replace(
        "translation-share-button-signature",
        path,
        "message: item.message, account: item.context.account, disableComments: true, isTranslate: true)",
        "message: EngineMessage(item.message), accountPeerId: item.context.account.peerId, disableComments: true, isTranslate: true)",
    )
    patches.replace(
        "translation-message-update-transition",
        path,
        "        item.controllerInteraction.expandedTranslationMessageStableIds.insert(item.message.stableId)\n"
        "        item.controllerInteraction.requestMessageUpdate(item.message.id, false)",
        "        item.controllerInteraction.expandedTranslationMessageStableIds.insert(item.message.stableId)\n"
        "        item.controllerInteraction.requestMessageUpdate(item.message.id, false, nil)",
    )
    patches.replace(
        "translation-message-update-transition",
        path,
        "                    item.controllerInteraction.expandedTranslationMessageStableIds.remove(item.message.stableId)\n"
        "                }\n"
        "                item.controllerInteraction.requestMessageUpdate(item.message.id, false)",
        "                    item.controllerInteraction.expandedTranslationMessageStableIds.remove(item.message.stableId)\n"
        "                }\n"
        "                item.controllerInteraction.requestMessageUpdate(item.message.id, false, nil)",
    )


def adapt_community_selection(patches: SourcePatches) -> None:
    patches.replace(
        "community-selection-release",
        CHAT_LIST_CONTROLLER,
        "                    if case .community = peer {\n"
        "                        self.openCommunityView(communityId: peer.id)\n"
        "                        self.chatListDisplayNode.mainContainerNode.currentItemNode.clearHighlightAnimated(true)\n"
        "                        return\n"
        "                    }",
        "                    if case .community = peer {\n"
        "                        self.openCommunityView(communityId: peer.id)\n"
        "                        self.chatListDisplayNode.mainContainerNode.currentItemNode.clearHighlightAnimated(true)\n"
        "                        releasePeerSelection()\n"
        "                        return\n"
        "                    }",
    )


def adapt_passkey_credential_identity(patches: SourcePatches) -> None:
    patches.replace(
        "passkey-credential-removal-identity",
        PASSKEYS_SCREEN,
        "            guard self.passkeysData?.contains(where: { $0.id == id }) == true else {\n"
        "                return\n"
        "            }\n"
        "            let _ = component.context.engine.auth.deletePasskey(id: id).startStandalone()",
        "            guard let passkey = self.passkeysData?.first(where: { $0.id == id }) else {\n"
        "                return\n"
        "            }\n"
        "            let _ = component.context.engine.auth.deletePasskey(id: passkey.id).startStandalone()",
    )
    patches.replace(
        "passkey-credential-removal-identity",
        PASSKEYS_SCREEN,
        "            #if compiler(>=6.2)\n"
        "            if #available(iOS 26.0, *), let passkey = self.passkeysData?.first(where: { $0.id == id }) {",
        "            #if compiler(>=6.2)\n"
        "            if #available(iOS 26.0, *) {",
    )


# These helpers were unchanged in the public fork, so a delta-only merge does
# not restore their files after upstream deleted them. Keep their implementations
# with their only remaining consumer; all dependencies already exist in TranslateUI.
# Source: db18308774, TranslateUI/Sources/{LanguageSelectionController,
# PlayPauseIconComponent}.swift and TranslateScreen.swift's final private class.
TRANSLATION_HELPERS = r"""private final class LanguageSelectionControllerArguments {
    let context: AccountContext
    let updateLanguageSelected: (String) -> Void

    init(context: AccountContext, updateLanguageSelected: @escaping (String) -> Void) {
        self.context = context
        self.updateLanguageSelected = updateLanguageSelected
    }
}

private enum LanguageSelectionControllerSection: Int32 {
    case languages
}

private enum LanguageSelectionControllerEntry: ItemListNodeEntry {
    case language(Int32, PresentationTheme, String, String, Bool, String)

    var section: ItemListSectionId {
        switch self {
        case .language:
            return LanguageSelectionControllerSection.languages.rawValue
        }
    }

    var stableId: Int32 {
        switch self {
        case let .language(index, _, _, _, _, _):
            return index
        }
    }

    static func ==(lhs: LanguageSelectionControllerEntry, rhs: LanguageSelectionControllerEntry) -> Bool {
        switch lhs {
        case let .language(lhsIndex, lhsTheme, lhsTitle, lhsSubtitle, lhsValue, lhsCode):
            if case let .language(rhsIndex, rhsTheme, rhsTitle, rhsSubtitle, rhsValue, rhsCode) = rhs, lhsIndex == rhsIndex, lhsTheme === rhsTheme, lhsTitle == rhsTitle, lhsSubtitle == rhsSubtitle, lhsValue == rhsValue, lhsCode == rhsCode {
                return true
            } else {
                return false
            }
        }
    }

    static func <(lhs: LanguageSelectionControllerEntry, rhs: LanguageSelectionControllerEntry) -> Bool {
        return lhs.stableId < rhs.stableId
    }

    func item(presentationData: ItemListPresentationData, arguments: Any) -> ListViewItem {
        let arguments = arguments as! LanguageSelectionControllerArguments
        switch self {
        case let .language(_, _, title, subtitle, value, code):
            return LocalizationListItem(presentationData: presentationData, id: code, title: title, subtitle: subtitle, checked: value, activity: false, loading: false, editing: LocalizationListItemEditing(editable: false, editing: false, revealed: false, reorderable: false), sectionId: self.section, alwaysPlain: false, action: {
                arguments.updateLanguageSelected(code)
            }, setItemWithRevealedOptions: { _, _ in }, removeItem: { _ in })
        }
    }
}

private func languageSelectionControllerEntries(theme: PresentationTheme, strings: PresentationStrings, selectedLanguage: String, languages: [(String, String, String)]) -> [LanguageSelectionControllerEntry] {
    var entries: [LanguageSelectionControllerEntry] = []

    var index: Int32 = 0
    for (code, title, subtitle) in languages {
        entries.append(.language(index, theme, title, subtitle, code == selectedLanguage, code))
        index += 1
    }

    return entries
}

private struct LanguageSelectionControllerState: Equatable {
    enum Section {
        case original
        case translation
    }

    var section: Section
    var fromLanguage: String
    var toLanguage: String
}

public func languageSelectionController(context: AccountContext, forceTheme: PresentationTheme? = nil, fromLanguage: String, toLanguage: String, completion: @escaping (String, String) -> Void) -> ViewController {
    let statePromise = ValuePromise(LanguageSelectionControllerState(section: .translation, fromLanguage: fromLanguage, toLanguage: toLanguage), ignoreRepeated: true)
    let stateValue = Atomic(value: LanguageSelectionControllerState(section: .translation, fromLanguage: fromLanguage, toLanguage: toLanguage))
    let updateState: ((LanguageSelectionControllerState) -> LanguageSelectionControllerState) -> Void = { f in
        statePromise.set(stateValue.modify { f($0) })
    }

    let actionsDisposable = DisposableSet()

    let presentationData = context.sharedContext.currentPresentationData.with { $0 }
    let interfaceLanguageCode = presentationData.strings.baseLanguageCode

    var dismissImpl: (() -> Void)?

    let arguments = LanguageSelectionControllerArguments(context: context, updateLanguageSelected: { code in
        updateState { current in
            var updated = current
            switch updated.section {
            case .original:
                updated.fromLanguage = code
            case .translation:
                updated.toLanguage = code
            }
            return updated
        }
    })

    let enLocale = Locale(identifier: "en")
    var languages: [(String, String, String)] = []
    var addedLanguages = Set<String>()
    for code in popularTranslationLanguages {
        if let title = enLocale.localizedString(forLanguageCode: code) {
            let languageLocale = Locale(identifier: code)
            let subtitle = languageLocale.localizedString(forLanguageCode: code) ?? title
            let value = (code, title.capitalized, subtitle.capitalized)
            if code == interfaceLanguageCode {
                languages.insert(value, at: 0)
            } else {
                languages.append(value)
            }
            addedLanguages.insert(code)
        }
    }

    for code in supportedTranslationLanguages {
        if !addedLanguages.contains(code), let title = enLocale.localizedString(forLanguageCode: code) {
            let languageLocale = Locale(identifier: code)
            let subtitle = languageLocale.localizedString(forLanguageCode: code) ?? title
            let value = (code, title.capitalized, subtitle.capitalized)
            if code == interfaceLanguageCode {
                languages.insert(value, at: 0)
            } else {
                languages.append(value)
            }
        }
    }

    let signal = combineLatest(queue: Queue.mainQueue(), context.sharedContext.presentationData, statePromise.get())
    |> map { presentationData, state -> (ItemListControllerState, (ItemListNodeState, Any)) in
        var presentationData = presentationData
        if let forceTheme {
            presentationData = presentationData.withUpdated(theme: forceTheme)
        }
        let controllerState = ItemListControllerState(presentationData: ItemListPresentationData(presentationData), title: .sectionControl([presentationData.strings.Translate_Languages_Original, presentationData.strings.Translate_Languages_Translation], 1), leftNavigationButton: ItemListNavigationButton(content: .none, style: .regular, enabled: false, action: {}), rightNavigationButton: ItemListNavigationButton(content: .text(presentationData.strings.Common_Done), style: .bold, enabled: true, action: {
            completion(state.fromLanguage, state.toLanguage)
            dismissImpl?()
        }), backNavigationButton: ItemListBackButton(title: presentationData.strings.Common_Back))

        let selectedLanguage: String
        switch state.section {
        case .original:
            selectedLanguage = state.fromLanguage
        case .translation:
            selectedLanguage = state.toLanguage
        }

        let listState = ItemListNodeState(presentationData: ItemListPresentationData(presentationData), entries: languageSelectionControllerEntries(theme: presentationData.theme, strings: presentationData.strings, selectedLanguage: selectedLanguage, languages: languages), style: .blocks, animateChanges: false)

        return (controllerState, (listState, arguments))
    }
    |> afterDisposed {
        actionsDisposable.dispose()
    }

    let controller = ItemListController(context: context, state: signal)
    controller.titleControlValueChanged = { value in
        updateState { current in
            var updated = current
            if value == 0 {
                updated.section = .original
            } else {
                updated.section = .translation
            }
            return updated
        }
    }
    controller.alwaysSynchronous = true
    controller.navigationPresentation = .modal

    dismissImpl = { [weak controller] in
        controller?.dismiss(animated: true, completion: nil)
    }

    return controller
}

enum PlayPauseIconNodeState: Equatable {
    case play
    case pause
}

private final class PlayPauseIconNode: ManagedAnimationNode {
    private let duration: Double = 0.35
    private var iconState: PlayPauseIconNodeState = .play

    init() {
        super.init(size: CGSize(width: 40.0, height: 40.0))

        self.trackTo(item: ManagedAnimationItem(source: .local("anim_playpause"), frames: .range(startFrame: 0, endFrame: 0), duration: 0.01))
    }

    func enqueueState(_ state: PlayPauseIconNodeState, animated: Bool) {
        guard self.iconState != state else {
            return
        }

        let previousState = self.iconState
        self.iconState = state

        switch previousState {
        case .pause:
            switch state {
            case .play:
                if animated {
                    self.trackTo(item: ManagedAnimationItem(source: .local("anim_playpause"), frames: .range(startFrame: 41, endFrame: 83), duration: self.duration))
                } else {
                    self.trackTo(item: ManagedAnimationItem(source: .local("anim_playpause"), frames: .range(startFrame: 0, endFrame: 0), duration: 0.01))
                }
            case .pause:
                break
            }
        case .play:
            switch state {
            case .pause:
                if animated {
                    self.trackTo(item: ManagedAnimationItem(source: .local("anim_playpause"), frames: .range(startFrame: 0, endFrame: 41), duration: self.duration))
                } else {
                    self.trackTo(item: ManagedAnimationItem(source: .local("anim_playpause"), frames: .range(startFrame: 41, endFrame: 41), duration: 0.01))
                }
            case .play:
                break
            }
        }
    }
}

final class PlayPauseIconComponent: Component {
    let state: PlayPauseIconNodeState
    let tintColor: UIColor?
    let size: CGSize

    init(state: PlayPauseIconNodeState, tintColor: UIColor?, size: CGSize) {
        self.state = state
        self.tintColor = tintColor
        self.size = size
    }

    static func ==(lhs: PlayPauseIconComponent, rhs: PlayPauseIconComponent) -> Bool {
        if lhs.state != rhs.state {
            return false
        }
        if lhs.tintColor != rhs.tintColor {
            return false
        }
        if lhs.size != rhs.size {
            return false
        }
        return true
    }

    final class View: UIView {
        private var component: PlayPauseIconComponent?
        private var animationNode: PlayPauseIconNode

        override init(frame: CGRect) {
            self.animationNode = PlayPauseIconNode()

            super.init(frame: frame)

            self.addSubview(self.animationNode.view)
        }

        required init?(coder: NSCoder) {
            fatalError("init(coder:) has not been implemented")
        }

        func update(component: PlayPauseIconComponent, availableSize: CGSize, transition: ComponentTransition) -> CGSize {
            if self.component?.state != component.state {
                self.component = component

                self.animationNode.enqueueState(component.state, animated: true)
            }

            self.animationNode.customColor = component.tintColor

            let animationSize = component.size
            let size = CGSize(width: min(animationSize.width, availableSize.width), height: min(animationSize.height, availableSize.height))
            self.animationNode.view.frame = CGRect(origin: CGPoint(x: floor((size.width - animationSize.width) / 2.0), y: floor((size.height - animationSize.height) / 2.0)), size: animationSize)

            return size
        }
    }

    func makeView() -> View {
        return View(frame: CGRect())
    }

    func update(view: View, availableSize: CGSize, state: EmptyComponentState, environment: ComponentFlow.Environment<Empty>, transition: ComponentTransition) -> CGSize {
        return view.update(component: self, availableSize: availableSize, transition: transition)
    }
}

private final class GiftViewContextReferenceContentSource: ContextReferenceContentSource {
    private let controller: ViewController
    private let sourceView: UIView

    init(controller: ViewController, sourceView: UIView) {
        self.controller = controller
        self.sourceView = sourceView
    }

    func transitionInfo() -> ContextControllerReferenceViewInfo? {
        return ContextControllerReferenceViewInfo(referenceView: self.sourceView, contentAreaInScreenSpace: UIScreen.main.bounds)
    }
}

"""


def adapt_translation_sheet(patches: SourcePatches) -> None:
    patches.replace(
        "translation-sheet-helper-imports",
        TRANSLATE_SCREEN,
        "import TelegramUIPreferences\nimport Markdown\n",
        "import TelegramUIPreferences\nimport ItemListUI\nimport ManagedAnimationNode\nimport Markdown\n",
    )
    anchor = "private let translateToTag = GenericComponentViewTag()"
    previous_helpers = TRANSLATION_HELPERS.replace("ComponentFlow.Environment<Empty>", "Environment<Empty>")
    if previous_helpers in patches.read(TRANSLATE_SCREEN):
        patches.replace("translation-sheet-restored-helpers", TRANSLATE_SCREEN, previous_helpers, TRANSLATION_HELPERS)
    patches.replace(
        "translation-sheet-restored-helpers",
        TRANSLATE_SCREEN,
        "import ViewControllerComponent\n\n" + anchor,
        "import ViewControllerComponent\n\n" + TRANSLATION_HELPERS + anchor,
    )
    # Reopening after language selection must keep the caller's whole-chat action.
    patches.replace(
        "translation-sheet-language-callback",
        TRANSLATE_SCREEN,
        "let controller = TranslateScreen(context: context, forceTheme: forceTheme, text: text, entities: entities, canCopy: canCopy, fromLanguage: fromLang, toLanguage: toLang, ignoredLanguages: ignoredLanguages, replaceText: replaceText)",
        "let controller = TranslateScreen(context: context, forceTheme: forceTheme, text: text, entities: entities, canCopy: canCopy, fromLanguage: fromLang, toLanguage: toLang, ignoredLanguages: ignoredLanguages, replaceText: replaceText, translateChat: translateChat)",
    )


def apply_public_api_adaptations(root: Path) -> dict[str, list[str]]:
    patches = SourcePatches(root)
    adapt_message_reactions(patches)
    adapt_translation_button(patches)
    adapt_community_selection(patches)
    adapt_passkey_credential_identity(patches)
    adapt_translation_sheet(patches)
    return patches.write()
