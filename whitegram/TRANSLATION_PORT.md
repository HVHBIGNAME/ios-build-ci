# Translation integration

The main Translation screen and recovered target-language/before-send catalog actions are connected to native Telegram UI.

- A global target changes automatic chat translation and the initial language of newly opened translation sheets. Explicit sheet/per-chat choices retain their native behavior where automatic translation is disabled.
- With before-send enabled, the first tap translates the draft for review. A subsequent explicit Send action sends it. Replies and send context are retained; changing them, editing the draft, leaving the chat or cancelling invalidates the pending operation.
- Telegram translation retains validated formatting/link entities. The native Google provider is supported for plain text. Before-send requests do not silently switch providers or invent translated entity offsets.
- Network failure, timeout, unsupported content or a stored unavailable on-device request leaves the original draft available. Original-once and restore-original actions are scoped to the exact draft.

Recovered keys are `wg_translationTargetLang`, `wg_translateBeforeSending`, `wg_localTranslationEnabled`, `wg_voiceTranslationEnabled`, and `wg_showSiriTranscriptionWarning` (catalog cases 264–268; see the revision-qualified feature inventory). The review-first interaction is reconstructed, not established as identical to the original IPA. Apple on-device translation and voice-translation/Siri workflows remain unconnected and are described as such in the screen.

`translation_patches.py` patches the actual composer before native enqueue, cancellation on chat exit, translation-state observation and target-language defaults. Foundation settings/draft guards live in TelegramCore, the provider adapter in TranslateUI, the composer coordinator in TelegramUI, and settings UI in SettingsUI.

Offline source checks cover syntax, call-site order, unchanged reply handling, exact patch replay and rejection of missing/ambiguous anchors. `tests/translation/run_native.py` executes six XCTest cases on the real Foundation state machine/settings/text rules, including UTF-16 scalar boundaries within emoji and combining sequences. The full Xcode build and device tests are needed for UIKit, provider results and formatting interoperability.
