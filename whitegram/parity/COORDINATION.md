# Parent integration contracts

The parent recovered all **1597 localization keys**, each with original Russian/Ukrainian/English values, by bounded emulation of original image 55 initializer `0x324f5e4`. The source is `whitegram/generated/WhitegramLocalizationStrings.swift`; exact source reference and reproduction script are `whitegram/recover_localization.py`. Treat these as original strings, not generated translations.

Parent installs `WhitegramLocalizationStrings.swift`, `WhitegramLocalizationPack.swift`, `WhitegramLocalizationStore.swift`, and `WhitegramLocalization.swift` in TelegramCore. UI code can use:

```swift
WhitegramLocalization.string("s.actualOriginalKey", baseLanguage: presentationData.strings.baseLanguageCode)
WhitegramLocalization.format("key.withNumberedPlaceholders", ["value1", "value2"], baseLanguage: languageCode)
```

Omitting baseLanguage uses the selected Whitegram language / original `wg_tgBaseLanguageCode` mirror. Unknown keys return the supplied optional `fallback:` or the key. Prefer keys verified in the recovered table. Original pack format is `.wglocalizations`, colon-separated entries with `# name:`, `# author:` and `# language:` headers. Stored entries are JSON in Documents/wg_localization.json with the original three metadata preference keys.

The parent owns shared catalog routes, main menu, generated state/schema, generic preference/archive changes, notifications/diagnostics and this localization layer. Worker reports must list their integration requirements; no worker should edit these shared files.

Original screenshots match the audited IPA's 12.9.2 (71). The active original 26-category menu excludes the retired AI category; the original still contains AI classes and catalog cases. Preserve the user's existing AI data while resolving menu eligibility from original evidence.

## Recovered durable workspace and parent integration

- Working repository is now `C:/coding/telegram/whitegram/ios-build-ci`. The old Temp tree was lost; source and work-in-progress changes were recovered from snapshot `4c1f4e72a035ef11a38c293cc968be744902c4d9`.
- Read-only assembled baseline: `C:/coding/telegram/whitegram/source-12.9.2`. Public reference: `C:/coding/telegram/whitegram/whitegram-public`. Recovery/evidence tooling remains in `C:/coding/telegram/whitegram/whitegram-rebuild`.
- Campaign/ready manifest: `C:/coding/telegram/whitegram/recovery_20261002/campaign/reference-ready.json`. Python: `C:/coding/telegram/whitegram/whitegram-check-env/Scripts/python.exe`.
- Parent has connected localization to the main menu and generated row labels, added live refresh, and routed `menuLanguagePicker`. `hideDescriptions` binds to the original `hideSettingsDescriptions` preference.
- Parent schema work: 0.7 photo quality; 9999 Int64 Stars; optional exact Int64 active account ID; 100-percent tab defaults; default-on three-second crossfade; 0.1..3 playback rate; exactly ten -12..12 EQ gains; low/medium/high plus prior numeric bitrate choices; wide-camera flag; download mode 0..3; synchronized menu-language index/code; two-times sticker bridge support. The 50..150 percent archive bounds follow current appearance controls, not a recovered getter range.
- Camera migration now consults `WhitegramMediaSettings.current.videoMessageCamera` in the shared bridge before public settings can overwrite a legacy selection.
- Parent fixed the history/plugin composition fixture to include the real `Network/Network.swift` and `TelegramRootController.swift` sources. The two-order/replay regression now passes. Full installer composition and all 51 JavaScript tests pass; native Swift checks remain pending.
- Backend/traffic registries and patch entrypoints are now installed. Services' additional Boolean keys and recovered absent-provider/model defaults are registered in the shared schema/state. Account-bound provider-proxy adapters still need to consume the backend's new transport contract.
- Player validation requires `WHITEGRAM_PLAYER_SOURCE`; it is now set in CI so its nine source integration tests run rather than skip. The existing native player runner is scheduled with `--require-swift`.
- Parent fixed whole-installer replay, including upgraded per-chat receipt/presence guards, ad observers, account/plugin request callbacks and startup initialization. `SourcePatches.replace` accepts explicitly declared complete upgraded forms; mixed/duplicate receipt forms still fail. The full sequence now has its own byte-identical replay regression.
- Parent narrowed account request/callback anchors in `account_patches.py` without changing emitted Swift, and added both-order account/plugin composition coverage. Preserve these replay fixes when continuing that module.
- The history catalog's six actions now invoke `whitegramHistoryActionController` with the exact enum case. The main Icons entry again opens the native app-icon selector; `myIconPacks`/`createIconPack` retain their separate manager route. The original `customSettingsIcons`/`showOriginalTelegramIcons` toggles are no longer incorrectly reported as implemented by that manager.
- The generated absent-value defaults now include deleted-message opacity 0.45 and particle speed/density 1. Existing stored values are retained. The backend native runner is scheduled in CI alongside the new player runner.
- Public-source publication: parent moved the backend application signing key out of Swift and fixture constants into `WHITEGRAM_BACKEND_APPLICATION_KEY` private build configuration. The existing key was provisioned as a repository Actions secret from the hash-verified local IPA. Preserve configuration loading and synthetic test keys; do not reintroduce embedded key bytes into source/evidence files committed to Git.
