# Translation integration

Current handoff: [parity/services.json](parity/services.json). The ready, read-only source baseline is `C:/coding/telegram/whitegram/source-12.9.2`, Telegram revision `6ad963e5b62d354da79040f388ae2b9132fb17b8` with the recovered baseline overlay. Windows checks validate source transformations and syntax; native execution remains an Apple-host check.

## Original contracts recovered

Original evidence comes from `whitegram-rebuild/audit-full-3.1.1`, image 46 (Core) and image 55 (UI). Bounded exports are in `recovery_20261002/campaign/services/`; each export verifies the original IPA SHA-256.

- **`localTranslationEnabled` means Google client-side HTTPS**, `https://translate.googleapis.com/translate_a/single`, not offline/Apple translation. Core `0x7d1008 → 0x7d30a8 → 0x7d3388` dispatches this for the eligible neutral text request. Non-neutral tone requests use Telegram's structured API.
- **`translateBeforeSending` adds With Translation to the send-options menu**. UI `0x29aa99c` requires both this flag and local translation, plus nonempty text. It does not intercept every normal Send tap. The action retains the selected effect, installs translated text and calls native send (`0x151bc4`, `0x1523b0`, `0x1526f0`). The original provider-failure outcome sends the unchanged text.
- Outgoing automatic target selection (`0x59d84c`) first honors a stored target. Otherwise it uses the device language; if the detected draft language matches it, it chooses English, or Russian when the device language is English. Incoming translation keeps the native per-chat/default language rules.
- **`voiceTranslationEnabled` selects Apple speech transcription**, not merely translation of existing transcript text. The verified `wh.voiceTranslation` localization describes Apple Speech, and native action consumers are `0x1dde24c` and `0x1e062e4`. The port connects this flag to voice/video-note button availability, trial bypass and the existing Apple transcription branches. Existing native transcription settings apply when this original flag is off.
- **The Siri warning getter is always true** (`46:0x20e0d0`). Independent `wg_siriTranscriptionWarningDismissed` controls the one-time notice; UI `0x1e06498/0x1e064b0` stores dismissal before presenting the original localized informational overlay. A stale saved `showSiriTranscriptionWarning = false` cannot suppress it.

These findings supersede the older coverage inventory's interpretation of before-send and voice-translation labels.

## Runtime map

Import all nine entries from `translation_patches.TRANSLATION_RUNTIME_FILES`:

| Source in `whitegram/cleanroom` | Destination |
| --- | --- |
| `WhitegramTranslationSettings.swift` | `submodules/TelegramCore/Sources/WhitegramTranslationSettings.swift` |
| `WhitegramTranslationDraftGuard.swift` | `submodules/TelegramCore/Sources/WhitegramTranslationDraftGuard.swift` |
| `WhitegramTranslationTextRules.swift` | `submodules/TelegramCore/Sources/WhitegramTranslationTextRules.swift` |
| `WhitegramTranslationGoogle.swift` | `submodules/TelegramCore/Sources/WhitegramTranslationGoogle.swift` |
| `WhitegramTranslationMessageBatch.swift` | `submodules/TelegramCore/Sources/WhitegramTranslationMessageBatch.swift` |
| `WhitegramTranslationService.swift` | `submodules/TranslateUI/Sources/WhitegramTranslationService.swift` |
| `WhitegramTranslationApple.swift` | `submodules/TranslateUI/Sources/WhitegramTranslationApple.swift` |
| `WhitegramTranslationSendCoordinator.swift` | `submodules/TelegramUI/Sources/WhitegramTranslationSendCoordinator.swift` |
| `WhitegramTranslationSettingsController.swift` | `submodules/SettingsUI/Sources/WhitegramTranslationSettingsController.swift` |

`translation_patches(patches: SourcePatches)` composes in memory; `apply_translation_patches(root)` writes only after counted anchors validate. Apply after the public/compatibility baseline. It patches eleven files: `ChatControllerNode`, `ChatController`, `ChatHistoryListNode`, `ChatTranslation`, `TranslateScreen`, Core's engine `Translate.swift`, interactive file/video nodes, `ChatMessageDisplaySendMessageOptions`, `ChatSendMessageActionSheetController`, and `ChatSendMessageContextScreen`.

The send-parameter extension adds an optional `whitegramTranslate` callback, default nil, rather than changing the shared send-mode enum or other callers. The parent owns source copying, BUILD dependencies, top-level composition and catalog routes.

## Behavior and retained fixes

- Normal Send is unaffected by the original menu flag. With Translation uses explicit send intent and revalidates the exact account, chat, draft, reply, forwarding state, selected effect and other send context before entering native send. Changing context, leaving the chat, backgrounding or cancelling invalidates the queued action. A still-current draft is sent unchanged if the provider fails, as in the original. Invalid/unsupported source structure or failed entity round-trip remains available for editing.
- The recovered port's review-first mode remains available as **`translationReviewBeforeSending`**, a separate opt-in Bool. First normal Send translates for review; a later tap sends. Its failures retain the draft, and Original Once / Restore Original are scoped to the exact snapshot.
- `WhitegramTranslationTextRules.validRange` retains the UTF-16 fix: endpoints may lie at Unicode scalar boundaries inside a combining/ZWJ sequence, but may not split surrogate pairs. Protected URLs, mentions, code and entity payloads are verified, and translated formatting boundaries are reconstructed from actual segment lengths.
- The progress object remains typed **`ViewController?`**, preserving the native `OverlayStatusController` factory compatibility fix.
- Google uses bounded ephemeral URLSession networking, no cookies/cache/shared credentials, redirect refusal, and cancellation that wins over an undelivered result. Formatted segments are submitted serially. Limits are 4,096 input UTF-16 units, 16,384 result units and 1 MiB response JSON. Literal `null` text is not discarded; malformed segments cannot produce a partial-success string.
- Manual sheets surface failures and only copy/replace a real result. Google/Apple text translation handles protected spans; Telegram handles requested formal/casual tone. HTTP failures never silently select a different provider.
- Successful received-message translations write a separate `TranslationMessageAttribute` only while the source stable version and settings still match. Poll options/solutions and completed transcripts are supported; original message/audio/transcript data stays intact. Rich-message structures require Telegram's structured API.
- Optional **Apple text translation** uses the new `translationUseApple` key, iOS 18 `TranslationSession`, `LanguageAvailability`, explicit system language-model download permission, checked response IDs, timeout and cancellation. It never falls back to a network provider. This is additional functionality, not the original local key.

## Preferences and integration APIs

| Key | Type/default and meaning |
| --- | --- |
| `localTranslationEnabled` | Original Bool, false; Google client-side text translation |
| `translateBeforeSending` | Original Bool, false; With Translation send-menu action, requires local translation |
| `translationTargetLang` | Original optional String; absent/empty selects automatic/native rules |
| `voiceTranslationEnabled` | Original Bool, false; Apple voice/video-note speech transcription |
| `showSiriTranscriptionWarning` | Original compatibility value; effective getter is always true |
| `siriTranscriptionWarningDismissed` | Original Bool, false; mirror `wg_siriTranscriptionWarningDismissed` |
| `translationUseApple` | New Bool, false; optional Apple text translation |
| `translationReviewBeforeSending` | New Bool, false; retained review-first normal-send mode |
| `translationTranslateTranscripts` | New Bool, true; translation of completed transcript text, independent of speech recognition |

Each key has a `wg_` mirror. Add the new keys and the original dismissal to the parent's archive/schema. Preserve explicitly saved provider/target values; do not reinterpret the original local key as Apple. The existing `translateMessagesEnabled` mirror remains parent-owned.

Public integration:

```swift
whitegramTranslationSettingsController(context: AccountContext) -> ViewController
whitegramTranslateDraft(context:text:entities:toLang:provider:fromLang:) -> Signal<WhitegramTranslationResult, WhitegramTranslationFailure>
whitegramTranslateVoiceText(context:text:toLang:) -> Signal<WhitegramTranslationResult, WhitegramTranslationFailure>
whitegramTranslationTarget(defaultLanguage: String) -> String
whitegramTranslationSettingsSignal() -> Signal<WhitegramTranslationSettings, NoError>
```

Dependencies: TelegramCore's Postbox/SwiftSignalKit; TranslateUI's AccountContext/TelegramCore/TelegramUIPreferences; TelegramUI's ChatInterfaceState, ChatPresentationInterfaceState, TextFormat, TranslateUI, Display, PresentationDataUtils, OverlayStatusController and SwiftSignalKit; SettingsUI's ItemListUI/PresentationDataUtils/TelegramPresentationData/TranslateUI. `ChatSendMessageActionUI` and both interactive media-node targets use TelegramCore's settings/localization. SDK frameworks include Foundation/CoreFoundation, UIKit, NaturalLanguage, SwiftUI and Translation (availability/weak linking must retain the iOS 13 deployment target). Apple Speech remains in the baseline LocalAudioTranscription implementation; the app requires its existing speech-permission description.

## Verification

On Windows, set `WHITEGRAM_ASSEMBLED_SOURCE=C:/coding/telegram/whitegram/source-12.9.2`, then run:

```text
C:/coding/telegram/whitegram/whitegram-check-env/Scripts/python.exe -B -m unittest discover -s whitegram/tests -p test_translation_patches.py -v
```

Nine source tests check actual patched call-site order, no draft/reply clearing, optional send callback/effect, Apple/Siri consumers, syntax parity, exact replay and missing/duplicate/late-anchor rejection without changing the reference.

`tests/translation/run_native.py` supplies **19 XCTest methods** on production settings/state-machine/text rules/Google code in a uniquely owned temporary SwiftPM host. Fixtures intercept every HTTP URL. They cover surrogate/scalar boundaries, protected spans, original send/voice defaults, outgoing target selection, Unicode wire data, response limits and cancellation. **Native XCTest, Swift type checking, UIKit/SwiftUI/Speech device execution and live provider access were not run on Windows.** Parent verification must exercise permission/download prompts, text-field round trips, original send outcomes, native voice/video-note transcription and cross-module BUILD linkage.
