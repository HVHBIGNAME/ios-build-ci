import AccountContext
import Display
import PresentationDataUtils
import SwiftSignalKit
import TelegramCore
import TelegramPresentationData

/// Original chat-list avatar prompt: enabling changes only story-read suppression.
func whitegramOpenStoriesWithGhostPrompt(context: AccountContext, present: @escaping (ViewController) -> Void, open: @escaping () -> Void) {
    guard WhitegramContentSettings.shouldSuggestStoryGhost else { open(); return }
    let language = context.sharedContext.currentPresentationData.with { $0.strings.baseLanguageCode }
    func text(_ key: String) -> String { return WhitegramLocalization.string(key, baseLanguage: language) }
    let confirmation = WhitegramContentConfirmation(action: open)
    present(textAlertController(context: context, title: text("stories.ghostPrompt.title"), text: text("stories.ghostPrompt.text"), actions: [
        TextAlertAction(type: .genericAction, title: text("common.cancel"), action: { confirmation.resolve(confirmed: false) }),
        TextAlertAction(type: .genericAction, title: text("stories.ghostPrompt.open"), action: { confirmation.resolve(confirmed: true) }),
        TextAlertAction(type: .defaultAction, title: text("stories.ghostPrompt.enable"), action: {
            if !confirmation.resolve(confirmed: true, prepare: { WhitegramContentSettings.set(true, for: "disableStoryReadReceipts") }) {
                let message = WhitegramLocalization.string("privacy.saveFailed", baseLanguage: language, fallback: "Could not save privacy settings.")
                present(textAlertController(context: context, title: text("common.error"), text: message, actions: [TextAlertAction(type: .defaultAction, title: context.sharedContext.currentPresentationData.with { $0.strings.Common_OK }, action: {})]))
            }
        })
    ], dismissOnOutsideTap: false))
}
