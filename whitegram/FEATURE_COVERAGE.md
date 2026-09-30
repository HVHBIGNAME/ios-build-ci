# Whitegram feature coverage — starting-revision audit

**Baseline: `6d8f529232b4633045f10fb04bc1ad7f18fe50ac` (`whitegram-source-12.9.4`).**

Of **333 catalog rows**, **61 are implemented and connected in source**, **67 are partial**, and **205 are absent** under the definitions below. Concurrent history, plugin-hook/event, and appearance work is **excluded** from these counts.

The complete row-by-row inventory is [FEATURE_COVERAGE.json](FEATURE_COVERAGE.json). Every row includes its key, order, section, control kind, recovered evidence, source/runtime evidence, missing behavior, and next implementation priority/task. Shared evidence records contain concrete file/line references; they are not capability-table assertions.

## Revision and evidence boundaries

| Input | Audited identity |
| --- | --- |
| Port repository | `6d8f529232b4633045f10fb04bc1ad7f18fe50ac`; clean when first inspected |
| Public WhiteGram | `db18308774f863074278feedc4df4507b0fb174e` |
| Telegram source | **12.9.2**, `6ad963e5b62d354da79040f388ae2b9132fb17b8` |
| Application metadata | **12.9.4 / 34639**; does not change the source baseline |
| Original 3.1.1 IPA | SHA-256 `bd6d3a13046d5857c1389e2d794c4c2ca44cee89bb22880004bd77f84fe29837` |
| Verification performed here | Static connectivity/evidence audit and inventory consistency checks |

Source roots used in the JSON:

- `port`: `C:\Users\Pisun4ik\AppData\Local\Temp\opencode\telegram-ios-private`
- `assembled`: `C:\Users\Pisun4ik\AppData\Local\Temp\opencode\whitegram-validate-12.9.2`
- `public`: `C:\Users\Pisun4ik\AppData\Local\Temp\wg`
- `original`: `C:\coding\telegram\whitegram\whitegram-rebuild`

Port line references are **revision-qualified**. Other agents changed some of these files after the initial read; inspect their baseline with `git show 6d8f529:<path>`. Assembled/public trees were read-only throughout this audit. No application build, existing test suite, device run, or service request was performed.

### What the statuses mean

- **Implemented and connected (I):** a reachable control/action has an installed downstream consumer implementing its identifiable function. Exact original visuals/defaults and device correctness remain unverified.
- **Partial (P):** a relevant subset exists, but original scope, semantics, persistence compatibility, or catalog binding remains incomplete.
- **Absent (A):** no connected implementation of the original row was found. State properties, catalog switches, unavailable controls, and unrelated stock features do not qualify.

Structural rows are included for reconciliation, not counted as working features:

| Population | Rows | I | P | A |
| --- | ---: | ---: | ---: | ---: |
| Entire catalog | **333** | **61** | **67** | **205** |
| Operational rows, excluding headers/text | **274** | **61** | **37** | **176** |
| Headers | 29 | 0 | 29 | 0 |
| Text rows, including dynamic status | 30 | 0 | 1 | 29 |

The one partial text row is `virusTotalStatusRow`: it has real hash-request status, but not the complete original connection/scan workflow. Headers render with generated wording. Every catalog `labelsVerified` value is still false.

## Coverage by catalog section

Sections and order ranges follow the generated catalog. Section 16 is especially heterogeneous; its later rows should not all be assigned to an accounts implementation.

| Section | Orders | Audit group | I | P | A |
| ---: | --- | --- | ---: | ---: | ---: |
| 0 | 0–2 | Previews | 0 | 0 | 3 |
| 1 | 3–14 | Messages/history | 0 | 9 | 3 |
| 2 | 15–18 | History caches | 0 | 3 | 1 |
| 3 | 19–41 | Appearance | 2 | 3 | 18 |
| 4 | 42–46 | Camera | 2 | 2 | 1 |
| 5 | 47–76 | Settings item visibility | 23 | 2 | 5 |
| 6 | 77–82 | Information display | 2 | 2 | 2 |
| 7 | 83–91 | Tabs/stories/feed | 3 | 2 | 4 |
| 8 | 92–133 | Miscellaneous/chat/media | 8 | 6 | 28 |
| 9 | 134–144 | Bubbles | 1 | 1 | 9 |
| 10 | 145–151 | Glass/content restrictions | 0 | 1 | 6 |
| 11 | 152–156 | Notifications/background | 0 | 1 | 4 |
| 12 | 157–166 | Ghost/presence/receipts | 8 | 1 | 1 |
| 13 | 167–171 | Privacy/content | 1 | 1 | 3 |
| 14 | 172–176 | Local Stars | 0 | 1 | 4 |
| 15 | 177–182 | Fonts | 3 | 2 | 1 |
| 16 | 183–245 | Sessions and extended miscellaneous | 2 | 3 | 58 |
| 17 | 246–249 | Presence/read-date tracking | 0 | 1 | 3 |
| 18 | 250–253 | Analytics/logs | 0 | 1 | 3 |
| 19 | 254–258 | Icon packs | 0 | 1 | 4 |
| 20 | 259–262 | Plugins | 0 | 3 | 1 |
| 21 | 263–268 | Translation | 0 | 2 | 4 |
| 22 | 269–270 | Anti-censorship | 0 | 1 | 1 |
| 23 | 271–274 | VirusTotal | 1 | 3 | 0 |
| 24 | 275–285 | Voice/remote/bleep/presets | 0 | 5 | 6 |
| 25 | 286–292 | Custom voice/calls | 0 | 5 | 2 |
| 26 | 293–301 | Gemini/Groq | 5 | 2 | 2 |
| 27 | 302–320 | Whitegram profile/data features | 0 | 1 | 18 |
| 28 | 321–331 | Music player/settings portability | 0 | 1 | 10 |
| 29 | 332 | Generic item header | 0 | 1 | 0 |
| **Total** | **0–332** | | **61** | **67** | **205** |

## Concrete mismatches worth acting on

| Key/family | Baseline evidence | Consequence |
| --- | --- | --- |
| `foldersAtBottom` | Public `WhiteGramChatFolderSettings.swift:10,22–35`, settings control at `WhiteGramSettingsController.swift:2047–2055`, actual layout at `ChatListControllerNode.swift:1256–1305`; no folder bridge in `WhitegramForkBridge.swift` | **P:** existing renderer/control can be reused; add shared-key read/write/notification binding and catalog routing. |
| `localStarsCountSlider`, `localStarsCountCustom` | Port `generated/WhitegramSettingsState.swift:98` declares `localStarsCount: Bool`; original `TelegramCoreFramework-0/symbols.json:4998–5012` identifies `SGSettings.localStarsCount: Int64`, getter **`0x201828`** | **A:** fix the concrete type error before implementing the count controls/consumer. |
| `stickerSizeAction`, `stickerSizeSlider` | Original assembly `001f8e28-c980d53afe.asm:24–26` selects **1.0 when stored value is zero**; bridge clamps to 0…1 and public renderer hides ordinary stickers at zero | **P:** recover the actual range/default policy; public slider semantics are not an exact port. |
| `hideWallet` | `PeerInfoSettingsItems.swift:179–181` unconditionally skips `wallet`; target-HEAD diff also shows removal of My TON | **P:** there is suppression, but no reversible setting consumer. |
| `hideSearchBar` | Bridge maps to `hideSearchButton`; `TabBarContollerNode.swift:345` controls the tab search button, while `ChatListControllerNode.swift:2034` still enables navigation search | **P:** verify the original surface and implement it explicitly. |
| `hideBottomTabBar` | Bridge maps to public `compactPanel` | **P:** compact-menu navigation is the implemented alternative; original hidden-bar semantics remain unverified. |
| `hideReactions` | Bridge maps to `channelPostReactions`; consumer checks broadcast channel type | **P:** no demonstrated original-scope equivalence across personal/group/channel messages. |
| `hidePhoneNumber` | Only `settingsEditingItems` phone disclosure is guarded (`PeerInfoSettingsItems.swift:465`) | **P:** recover the original callers before widening the scope. |
| `cameraSettingsButton` | Routes to general chat settings; original method audit has FPS/preset/wide-angle/bitrate selectors | **P:** choosing front/back does not finish the camera settings screen. |
| `showDeletedMessages`, `showEditedOriginalText` | Capture flows into `whitegram-history-v1.json`; deletions still proceed and there is no baseline inline retained-message/edit-history renderer | **P:** text archive capture is real, original chat presentation/restoration is incomplete. |
| `voiceBleepEnabled` | Original `transcribeAndBleep`/`process(oggPath:)`; port adds `voiceBleepWholeRecording` | **A:** selective word censoring is absent; full-recording tone replacement has different semantics. |
| `myIconPacks`, `createIconPack` | Only bundled launcher icon selection is implemented | **A:** original pack management/creation remains absent. |

The JSON records additional storage-name differences explicitly, including `fontHistory` versus recovered `wg_customFontHistory`, `whitegramProfileReactionsEnabled` versus `wg_profileReactionsEnabled`, and generated effect aliases. A matching generated property name is not a verified persistence contract.

## Highest-priority parent implementation families

These are substantive remaining families outside the concurrently owned history/plugin/appearance work. `P1` means next implementation/repair; `P2` means a larger feature or unresolved original contract; `P3` means wording/presentation/parity validation. The JSON includes per-row priorities and a machine-readable version of this backlog.

### 1. Translation policy and before-send integration — P1

**Keys:** `localTranslationEnabled`, `translationTargetLang`, `translateBeforeSending`, `voiceTranslationEnabled`, `siriTranscriptionWarning`.

- `TranslateUI/Sources/ChatTranslation.swift:195–209` uses the Google service in its `enableLocalIfPossible` branch. Wire the real local/Apple service with the recovered enable/availability policy.
- Automatic translation uses UI base language (`ChatHistoryListNode.swift:2169–2171`). Add the recovered global target selector and thread it through received-message and send-time translation.
- Integrate asynchronous translation at **`TelegramUI/Sources/ChatControllerNode.swift:4849`, `sendCurrentMessage`**, before draft clearing/enqueue. Preserve replies, entities, cancellation and error behavior from the recovered workflow.
- Extend actual transcription output into voice translation; implement the original Siri warning/dismissal state. Public transcription alone does not implement that workflow.

**Original anchors:** menu cases 264–268; `wg_localTranslationEnabled`, `wg_translationTargetLang`, `wg_translateBeforeSending`, `wg_voiceTranslationEnabled`, `wg_showSiriTranscriptionWarning`.

### 2. Content controls and message actions — P1

**Keys:** `saveProtectedContent`, `removeSpoilers`, `bypassContentRestrictions`, `keepBannedChats`, `saveViewOnceMedia`, `readOnAction`, `saveToFavoritesInMenu`, `warnBeforeCall`.

- Recover exact original policy scope, then connect it to **`TelegramCore/Sources/Utils/MessageUtils.swift:393–419`**, `PeerUtils.swift:257–259`, and the actual text/media spoiler consumers.
- Add the original message-to-Saved-Messages context action in **`ChatInterfaceStateContextMenus.swift`**. The public `privateAddToFavorites` / `channelSaveToFavorites` options at line 1030 control **sticker** favorites. A real forwarding helper already exists at `ChatController.swift:3501–3502`.
- Reproduce action-triggered read exceptions at the original actions; current ghost suppression has no `readOnAction` consumer.
- Add call confirmation before actual launch (`ChatController.swift:3530–3555`) and cover the other recovered call entry points.
- Coordinate view-once/banned-content retention with the history owner; recover its original lifecycle rather than changing unrelated deletion behavior.

### 3. Outgoing media, complete camera settings and transfer scheduling — P1

**Keys:** `cleanMetadataOnSend`, `sendLargePhotos`, `photoQualitySlider`, `alwaysSendHD`, `cameraSettingsButton`, `rememberLastCamera`, `staticZoom`, `maxDownloadSpeed`, `sendAcceleration`, `downloadAccelPicker`.

- Apply recovered metadata, image dimension and compression policies in **`LegacyMediaPickerUI/Sources/LegacyMediaPickers.swift`** and **`MediaPickerUI/Sources/MediaPickerScreen.swift`**. Existing JPEG export at lines 398–416 is a concrete starting point; cover edited images and original/file sends according to original scope.
- Original `WGCameraSettingsController` methods include **`backPresetChanged` (`0xcab8c8`), `backFPSChanged` (`0xcab900`), `frontPresetChanged` (`0xcaba2c`), `frontFPSChanged` (`0xcabaa8`), `wideAngleChanged` (`0xcabb08`), `bitrateChanged` (`0xcabc24`)**. Implement their real capture/encoder consumers.
- Record the actually switched camera when remembering is enabled; current saved starting-camera selection is not that behavior.
- Connect recovered acceleration modes to **`TelegramCore/Sources/Network/MultipartFetch.swift:496–583`** and **`MultipartUpload.swift:119–156`**. Existing stock concurrency is not a setting consumer; original mode values/parameters must be recovered before choosing replacements.

### 4. Accounts and session portability — P1

**Keys:** `keychainAccounts`, `accountTransfer`, `botAccounts`, `keepUnavailableAccounts`, `accountSwitcherEnabled`.

Baseline **`cleanroom/WhitegramAccountsSettingsController.swift:101–140`** only lists numeric account-record IDs, switches the current account, and starts ordinary auth.

Implement the original models/codecs and integrate them with **`TelegramCore/Sources/Account/Account.swift`**, `AccountManager/AccountManagerImpl.swift`, and `TelegramEngine/Auth`:

- `PortableAccount(dcId, authKey, userId, name, phone)`, `readTelethonSession`, `writeTelethonSession`, and `makeSessionBackup` are preserved in original symbols.
- Original transfer controller has **`importSessionFiles` (`0xc86708`), `importTDataFolder` (`0xc86890`), and `exportAccounts` (`0xc91958`)**.
- Add actual session Keychain backup/list/restore and bot-token login/progress/error handling.
- Recreate `WGFrozenAccountsStore.markFrozen/clear/entry/isFrozen/allFrozenAccountIds` with the recovered account/peer/reason/time fields, then integrate unavailable-account retention and the original switcher.

### 5. Complete the original service workflows — P1

Existing service request builders are usable starting points:

- **VirusTotal:** extend `WhitegramVirusTotalService.swift` / controller with original `extractTarget`, `extractAllTargets`, `testConnection`, `scanIP`, `scanUrl`, `scanFile` and progress. Current code performs only **GET `/api/v3/files/{sha256}`**. Connect message-context targets in `ChatInterfaceStateContextMenus.swift`.
- **Gemini/Groq:** extend `WhitegramAIService.swift` / controller with original persisted chat/reply/history behavior. Original `WGGeminiChatViewController` has `cancelReply`, `sendTapped`, `clearHistoryTapped`; recovered keys include `wg_geminiChatHistory_v5` and `wg_groqChatHistory_v5`. Current requests contain one user message and screen state is in memory.
- **Voice:** implement original `fetchVoices`, `changeVoice`, `changeVideoAudio` and real remote credential/status handling. Selective bleeping needs transcription word timings, profanity matching and segment masking/re-encoding. Calls need a separate real-time audio adapter.
- Recover provider-proxy request/authentication contracts before implementing `geminiUseProxy`, `groqUseProxy`, `voiceChangerUseProxy`. Current URLSession/system networking does not consume those flags.

### 6. Music player DSP — P1

**Keys:** `playbackSpeedSlider`, `playbackPitchFollowsSpeed`, `crossfadeEnabled`, `crossfadeSlider`, `equalizerEnabled`, `equalizerOpen`, `stopAfterVoiceMessage`.

- Wire recovered music speed/pitch behavior into **`TelegramUI/Sources/SharedMediaPlayer.swift:183–241,416–454`** and **`MediaPlayer/Sources/MediaPlayerAudioRenderer.swift`**.
- Crossfade needs overlapping audio/mixing and real transition/cancellation behavior, not a duration value stored beside the current player.
- Original EQ has reset/preset/editor methods and **`musicEqualizerBands: [Float]`**. Implement its numeric band model and actual audio chain.
- Gate voice-message auto-next at playback completion. Recover the separate `bassEffect` consumer before deciding whether it belongs in audio DSP or visual response.

### 7. Settings portability, diagnostics and notifications — P1/P2

- Implement `exportSettings`, `importSettings`, `saveSettingsToKeychain`, `restoreSettingsFromKeychain` around **`WhitegramPreferences.swift`**, with original format/key mapping and observer/primitive-mirror refresh. History JSON and API-key Keychain storage are separate features. The service credential adapter requires secret exclusion even after a migration failure.
- Implement `exportSystemLogs`, `showRAMUsage`, `analyticsStaticRow` using actual data. Original `WGApiUsageStats.record(path:)`, `counts(days:)`, `total(days:)` and `wg_analyticsEvents_v2` are evidence leads.
- `menuLanguagePicker` needs an independent Whitegram language resolver/loader; baseline menus follow Telegram's ru/en selection.
- Recover original notification triggers/payloads, persistent scheduling and keepalive lifecycle. `whitegramNotificationsEnabled`, `persistentNotificationsEnabled`, `backgroundKeepAlive` have no consumers. The recovered `wg_keepalive_silence.wav` is a lead, not a complete lifecycle specification.

### 8. Whitegram profile/data services — P2

The entire section 27 remains operationally absent, alongside related photo-wall/photos/style/scammer options in earlier sections.

Implement original-compatible data/authentication/cache/update contracts for lyric/quote/wall/photo-wall/badge/scene, profile reactions, streaks, rich presence and data cards, then connect the original profile controllers. Share presentation work with the appearance owner.

- Scammer protection has a concrete original manager with `publicKeyBytes`, `snapshotURLBytes`, `refreshIfNeeded`, `isScammer(peerId:)`; reproduce the signed-snapshot flow.
- Profile reactions use recovered **`wg_profileReactionsEnabled`**, not a guessed generated key spelling.
- Rich Whitegram presence is distinct from Telegram online-status suppression.
- `sources/WhitegramConfig/WGServerConfig.swift` contains reconstructed path leads and a **`wg.example.com` placeholder**. It does not supply an installed original backend or verified request envelopes. Original response/authentication semantics still need recovery.

## Evidence lookup and inventory integrity

For each JSON row with order `n`:

- `original_evidence.case = n` resolves to `original/menu-cases-3.1.1/MENU_CASES.md`, line **`n + 11`**, including original code address/control type.
- Original state/callback candidates are at `original/menu-map-3.1.1/MENU_MAP.md`, line **`n + 14`**.
- Baseline port descriptor is `whitegram/generated/WhitegramSettingsCatalog.swift`, line **`n + 29`**.
- `original_evidence.keys` contains only exact strings found in `recovered-3.1.1/WGRecoveredPreferenceKeys.swift`. An empty list means no literal asserted here, not that the original had no setting.
- `source_runtime_evidence` resolves to the JSON evidence dictionary's concrete installed file/line references. `R_NONE` explains the negative-search scope; it never counts a generated state property as implementation.

The inventory was checked for 333 unique keys; exact baseline order/section/kind agreement; original case/key existence; evidence-reference resolution; and count reconciliation. No temporary audit script or application source change is part of this deliverable.

## Remaining uncertainty and re-audit boundary

- Source connectivity is established for the I rows; native builds, packet behavior, picker presentation, audio output and device lifecycle are not certified by this audit.
- Original strings, defaults, ranges and conditional UI have not all been recovered. Conservative P classifications explicitly flag unresolved semantic scope or replacement algorithms.
- Native getter/type evidence takes precedence over generated state assumptions. `localStarsCount` is a demonstrated mismatch; other suspect generated fields should receive the same treatment before use.
- The 333 rows include scaffolding and do not enumerate every original API. The original menu map lists **76 additional screen/type structures**, including radio, chat locks, API status, localization and plugin-language surfaces. These require their own integration coverage; header counts cannot close them.
- Re-audit the final history/plugin/appearance revision and its freshly assembled source after those owners finish. Their newly observed files and edits were deliberately not credited to baseline `6d8f529`.
