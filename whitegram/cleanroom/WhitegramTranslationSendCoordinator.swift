import Foundation
import UIKit
import SwiftSignalKit
import TelegramCore
import TelegramUIPreferences
import AccountContext
import ChatInterfaceState
import ChatPresentationInterfaceState
import Display
import PresentationDataUtils
import OverlayStatusController
import TextFormat
import TranslateUI

struct WhitegramTranslationDraftSnapshot: Equatable {
    let state: ChatPresentationInterfaceState
    let settings: WhitegramTranslationSettings
    let provider: WhiteGramOtherTranslationService

    init(_ state: ChatPresentationInterfaceState) {
        self.state = state
        self.settings = WhitegramTranslationSettings.current
        self.provider = WhiteGramOtherSettings.current.translationService
    }

    static func == (lhs: WhitegramTranslationDraftSnapshot, rhs: WhitegramTranslationDraftSnapshot) -> Bool {
        let left = lhs.state.interfaceState
        let right = rhs.state.interfaceState
        return lhs.settings == rhs.settings && lhs.provider == rhs.provider
            && lhs.state.accountPeerId == rhs.state.accountPeerId
            && lhs.state.chatLocation == rhs.state.chatLocation
            && lhs.state.subject == rhs.state.subject
            && lhs.state.currentSendAsPeerId == rhs.state.currentSendAsPeerId
            && lhs.state.focusedPollAddOptionMessageId == rhs.state.focusedPollAddOptionMessageId
            && lhs.state.inputTextPanelState.mediaRecordingState == rhs.state.inputTextPanelState.mediaRecordingState
            && lhs.state.isNotAccessible == rhs.state.isNotAccessible
            && lhs.state.peerIsBlocked == rhs.state.peerIsBlocked
            && lhs.state.sendPaidMessageStars == rhs.state.sendPaidMessageStars
            && lhs.state.acknowledgedPaidMessage == rhs.state.acknowledgedPaidMessage
            && left.composeInputState == right.composeInputState
            && left.replyMessageSubject == right.replyMessageSubject
            && left.composeDisableUrlPreviews == right.composeDisableUrlPreviews
            && left.forwardMessageIds == right.forwardMessageIds
            && left.forwardOptionsState == right.forwardOptionsState
            && left.editMessage == right.editMessage
            && left.postSuggestionState == right.postSuggestionState
            && left.mediaDraftState == right.mediaDraftState
            && left.selectionState == right.selectionState
            && left.silentPosting == right.silentPosting
            && left.sendMessageEffect == right.sendMessageEffect
    }
}

final class WhitegramTranslationSendCoordinator {
    private let draftGuard = WhitegramTranslationDraftGuard<WhitegramTranslationDraftSnapshot>()
    private let disposable = MetaDisposable()
    private var progress: ViewController?
    private var prompt: ViewController?
    private var promptId: UUID?
    private var readCurrent: (() -> ChatPresentationInterfaceState?)?
    private var observers: [NSObjectProtocol] = []

    init() {
        self.observers.append(NotificationCenter.default.addObserver(forName: UIApplication.willResignActiveNotification, object: nil, queue: .main) { [weak self] _ in
            self?.cancel()
        })
        self.observers.append(NotificationCenter.default.addObserver(forName: WhitegramPreferences.updatedNotification, object: nil, queue: .main) { [weak self] _ in
            guard let self, let state = self.readCurrent?() else { return }
            self.observe(state)
        })
    }

    deinit {
        self.disposable.dispose()
        for observer in self.observers { NotificationCenter.default.removeObserver(observer) }
        let progress = self.progress
        let prompt = self.prompt
        DispatchQueue.main.async {
            progress?.dismiss()
            prompt?.dismiss()
        }
    }

    func observe(_ state: ChatPresentationInterfaceState) {
        if self.draftGuard.observe(WhitegramTranslationDraftSnapshot(state)) {
            self.stopPresentation()
            self.disposable.set(nil)
        }
    }

    func cancel() {
        self.draftGuard.cancel()
        self.disposable.set(nil)
        self.readCurrent = nil
        self.stopPresentation()
    }

    private func stopPresentation() {
        self.promptId = nil
        self.prompt?.dismiss()
        self.prompt = nil
        self.progress?.dismiss()
        self.progress = nil
    }

    /// Returning true consumes this tap. Only a later user tap may enter Telegram's send path.
    func intercept(context: AccountContext, state: ChatPresentationInterfaceState, controller: ViewController?, current: @escaping () -> ChatPresentationInterfaceState?, apply: @escaping (ChatTextInputState) -> Void) -> Bool {
        let snapshot = WhitegramTranslationDraftSnapshot(state)
        guard snapshot.settings.beforeSending else {
            self.cancel()
            return false
        }
        self.observe(state)
        self.readCurrent = current
        if self.draftGuard.isReviewed(snapshot) { return false }
        if self.draftGuard.isPending { return true }

        let interfaceState = state.interfaceState
        // These are separate native operations, not a new text message from the composer.
        if interfaceState.editMessage != nil || interfaceState.postSuggestionState != nil
            || interfaceState.mediaDraftState != nil || state.inputTextPanelState.mediaRecordingState != nil
            || state.focusedPollAddOptionMessageId != nil {
            return false
        }
        if case .customChatContents = state.subject { return false }
        let input = interfaceState.composeInputState
        if input.content.isEmpty { return false }
        guard let controller else { return true }

        if snapshot.settings.localTranslationRequested {
            self.showFailure(.localUnavailable, context: context, controller: controller, snapshot: snapshot, current: current)
            return true
        }
        guard input.content.isEntityExpressible() else {
            self.showFailure(.unsupportedContent, context: context, controller: controller, snapshot: snapshot, current: current)
            return true
        }
        guard let target = snapshot.settings.resolvedTarget(baseLanguage: state.strings.baseLanguageCode, supportedLanguages: supportedTranslationLanguages) else {
            self.showFailure(.invalidTarget, context: context, controller: controller, snapshot: snapshot, current: current)
            return true
        }
        let source = convertMarkdownToAttributes(expandedInputStateAttributedString(input.inputText))
        if !WhitegramTranslationTextRules.hasText(source.string) { return false }
        let entities = generateTextEntities(source.string, enabledTypes: .all, currentEntities: generateChatInputTextEntities(source, maxAnimatedEmojisInText: 0))
        self.start(context: context, controller: controller, snapshot: snapshot, source: source, entities: entities, target: target, current: current, apply: apply)
        return true
    }

    private func start(context: AccountContext, controller: ViewController, snapshot: WhitegramTranslationDraftSnapshot, source: NSAttributedString, entities: [MessageTextEntity], target: String, current: @escaping () -> ChatPresentationInterfaceState?, apply: @escaping (ChatTextInputState) -> Void) {
        self.stopPresentation()
        let id = self.draftGuard.begin(snapshot)
        let progress = OverlayStatusController(theme: snapshot.state.theme, type: .loading(cancelled: { [weak self] in self?.cancel() }))
        self.progress = progress
        controller.present(progress, in: .window(.root))
        self.disposable.set((whitegramTranslateDraft(context: context, text: source.string, entities: entities, toLang: target, provider: snapshot.provider)
        |> deliverOnMainQueue).start(next: { [weak self, weak controller] result in
            guard let self, self.draftGuard.isCurrent(id, snapshot: snapshot) else { return }
            guard let controller, let state = current() else { self.cancel(); return }
            self.observe(state)
            let live = WhitegramTranslationDraftSnapshot(state)
            guard self.draftGuard.finish(id, snapshot: live) else { return }
            self.stopPresentation()
            let restored = chatInputStateStringWithAppliedEntities(result.text, entities: result.entities)
            let replacement = ChatTextInputState(inputText: restored)
            let expanded = expandedInputStateAttributedString(replacement.inputText)
            let roundTripEntities = generateTextEntities(expanded.string, enabledTypes: .all, currentEntities: generateChatInputTextEntities(expanded, maxAnimatedEmojisInText: 0))
            guard expanded.string == result.text,
                  Self.sameEntities(roundTripEntities, result.entities) else {
                self.showFailure(.invalidEntities, context: context, controller: controller, snapshot: snapshot, current: current)
                return
            }
            apply(replacement)
            guard let installed = current() else { return }
            let expected = WhitegramTranslationDraftSnapshot(state.updatedInterfaceState { $0.withUpdatedComposeInputState(replacement) })
            let reviewed = WhitegramTranslationDraftSnapshot(installed)
            guard reviewed == expected else { return }
            self.draftGuard.markForReview(reviewed)
            self.showReady(context: context, controller: controller, original: snapshot, reviewed: reviewed, target: target, current: current, apply: apply)
        }, error: { [weak self, weak controller] error in
            guard let self, self.draftGuard.isCurrent(id, snapshot: snapshot) else { return }
            guard let controller, let state = current() else { self.cancel(); return }
            self.observe(state)
            guard self.draftGuard.finish(id, snapshot: WhitegramTranslationDraftSnapshot(state)) else { return }
            self.stopPresentation()
            self.showFailure(error, context: context, controller: controller, snapshot: snapshot, current: current)
        }))
    }

    private static func sameEntities(_ lhs: [MessageTextEntity], _ rhs: [MessageTextEntity]) -> Bool {
        var remaining = rhs
        for entity in lhs {
            guard let index = remaining.firstIndex(of: entity) else { return false }
            remaining.remove(at: index)
        }
        return remaining.isEmpty
    }

    private func showFailure(_ failure: WhitegramTranslationFailure, context: AccountContext, controller: ViewController, snapshot: WhitegramTranslationDraftSnapshot, current: @escaping () -> ChatPresentationInterfaceState?) {
        self.stopPresentation()
        let id = UUID()
        self.promptId = id
        let alert = textAlertController(context: context, title: "Translation Not Sent", text: failure.message + "\n\nUse Original Once skips translation for this exact draft on your next Send tap.", actions: [
            TextAlertAction(type: .defaultAction, title: "Keep Editing", action: {}),
            TextAlertAction(type: .genericAction, title: "Use Original Once", action: { [weak self] in
                guard let self, self.promptId == id, let state = current(), WhitegramTranslationDraftSnapshot(state) == snapshot else { return }
                self.draftGuard.markForReview(snapshot)
                self.promptId = nil
            })
        ])
        self.prompt = alert
        controller.present(alert, in: .window(.root))
    }

    private func showReady(context: AccountContext, controller: ViewController, original: WhitegramTranslationDraftSnapshot, reviewed: WhitegramTranslationDraftSnapshot, target: String, current: @escaping () -> ChatPresentationInterfaceState?, apply: @escaping (ChatTextInputState) -> Void) {
        let id = UUID()
        self.promptId = id
        let language = Locale(identifier: reviewed.state.strings.baseLanguageCode).localizedString(forIdentifier: target) ?? target
        let alert = textAlertController(context: context, title: "Translation Ready", text: "Translated with \(reviewed.provider.title) to \(language). Review the draft, then tap Send again. Nothing has been sent.", actions: [
            TextAlertAction(type: .defaultAction, title: "Review Draft", action: {}),
            TextAlertAction(type: .genericAction, title: "Restore Original", action: { [weak self] in
                guard let self, self.promptId == id, let state = current(), WhitegramTranslationDraftSnapshot(state) == reviewed else { return }
                self.draftGuard.cancel()
                self.promptId = nil
                apply(original.state.interfaceState.composeInputState)
            })
        ])
        self.prompt = alert
        controller.present(alert, in: .window(.root))
    }
}
