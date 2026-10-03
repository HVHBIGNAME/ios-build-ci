# Original Whitegram contracts and parity audit

## Scope and reference identity

This audit accounts for **333 menu cases, 76 additional screen/type structures,
246 state fields, 135 argument fields, and 342 recovered preference literals**.
It is a source/evidence inventory, not a claim that the client matches the original.

- Original: `C:\coding\telegram\whitegram\Whitegram Beta 3.1.1 (12.9.2).ipa`.
- Independently verified SHA-256:
  `bd6d3a13046d5857c1389e2d794c4c2ca44cee89bb22880004bd77f84fe29837`.
- Actual `Payload/Telegram.app/Info.plist`: **12.9.2 (71)**, `Whitegram`,
  `ph.telegra.Telegraph`, minimum iOS 13.0, SDK `iphoneos26.2`.
- This matches the reported screenshot version. Screenshot pixels were not
  independently examined, so it does not verify screenshot layout or active language.
- Telegram source reference: `release-12.9.2`,
  `6ad963e5b62d354da79040f388ae2b9132fb17b8`. Port metadata `12.9.4/34639`
  is a different version label, not evidence of a newer source baseline.
- Audited repository HEAD: `dba65e0a2c3b573f5f92a68807b9bc5771e6514c` plus
  working changes. The parent-reported successful build `36953914277` covers
  the committed baseline, not the evolving working tree.
- SQLite `images` lookup establishes **46 = TelegramCore**, **55 = TelegramUI**.
  Addresses below are image-relative native addresses, not source line numbers.

The initial inventory evidence index was captured at **2026-10-02 04:03:51 UTC**.
Other workers continued editing. Validation/test reports include per-file hashes
and drift lists; this is not an atomic snapshot or validation of all later changes.

## Reading the machine-readable inventory

`inventory.json` is a normalized assessment table. Its `rows` tuples explicitly
identify every case/key and its family/status. Families supply an `assigned_owner`,
current source paths, remaining work and precise blockers. `additional_types`
accounts for every one of the 76 original descriptors.

The `evidence_index` and `expanded_inventory` references resolve under the roots
declared in that JSON. The expanded artifact joins every assessment to the
original case block/callsites, associated-value encoding, state type, callbacks,
exact literal candidates, source mentions/hashes and contract overrides. It is
standalone JSON for downstream aggregation. New artifacts live under:

`C:\Users\Pisun4ik\AppData\Local\Temp\opencode\whitegram-parity-20261002\audit-evidence`

- `inventory-evidence-01.json`: immutable original/current evidence index.
- `inventory-expanded-02.json`: complete joined row/type assessments.
- `inventory-validation-02.json`: integrity checks, counts and later source drift.
- `original-localization.json`: 1,597 bound translations and 26 ordered sections.
- `checks-current-01.json` and `checks-current-01-0.log` through `-5.log`: complete
  current source-check results, input hashes and test logs.

Status **I** means an identifiable source consumer is connected, not exact parity.
**P** includes real narrower behavior or substantive implementation awaiting
integration. **A** means no connected original consumer was identified in the
bounded source/alias inspection. **B** records an external/device requirement
alongside any code gap. **S** is presentation-only and receives no feature credit.
There are 29 headers and 30 text rows; the operational denominator is **274**,
not 333. Dynamic status text is evaluated on its producer. The 76 types are not
76 independent working functions.

The old `FEATURE_COVERAGE.json` supplies identities, aliases and leads from
revision `6d8f529`; none of its status counts are reused as current results.
Name-matched preference/callback associations remain candidates. Missing literal
matches do not rule out inline Swift strings. Unknown defaults/ranges are `null`;
generated state defaults are never substituted for missing native evidence.

## Recovered main-menu order and localization

`55:0xdfc39c` constructs the following 26 sections. Indices are zero-based.
These are the built-in Russian titles; exact descriptions, ru/uk/en values,
localization keys, store callsites and section-array addresses are in the export.

| Index | Built-in Russian title | Icon | Localization key |
| ---: | --- | --- | --- |
| 0 | О Whitegram | `person.fill` | `section.about` |
| 1 | Внешний вид | `paintbrush.fill` | `section.appearance` |
| 2 | Уведомления | `bell.fill` | `section.notifications` |
| 3 | Liquid Glass | `drop.fill` | `section.liquidGlass` |
| 4 | Сообщения | `message.fill` | `section.messages` |
| 5 | Камера | `camera.fill` | `section.camera` |
| 6 | Режим призрака | `eye.slash.fill` | `section.ghost` |
| 7 | Конфиденциальность | `lock.fill` | `section.privacy` |
| 8 | Информация | `info.circle.fill` | `section.info` |
| 9 | Дополнительно | `slider.horizontal.3` | `section.misc` |
| 10 | Разделы меню | `eye.trianglebadge.exclamationmark.fill` | `section.interface` |
| 11 | Вкладки | `rectangle.3.group.fill` | `section.tabs` |
| 12 | Локальные звезды | `star.fill` | `section.stars` |
| 13 | Шрифты | `textformat` | `section.fonts` |
| 14 | Перевод | `globe` | `section.translation` |
| 15 | Улучшенный трафик | `network.badge.shield.half.filled` | `section.antiCensorship` |
| 16 | VirusTotal | `checkmark.shield.fill` | `section.virusTotal` |
| 17 | Смена голоса | `waveform.badge.mic` | `section.voiceChanger` |
| 18 | Плеер | `music.note` | `section.player` |
| 19 | Радио | `dot.radiowaves.left.and.right` | `radio.menuTitle` |
| 20 | Функции Whitegram | `telegram_sphere` | `h.features` |
| 21 | Иконки | `square.grid.2x2.fill` | `section.icons` |
| 22 | Плагины | `puzzlepiece.extension.fill` | `h.plugins` |
| 23 | Локализация | `character.bubble` | `section.localization` |
| 24 | Сессии | `clock.fill` | `section.sessions` |
| 25 | Все настройки | `list.bullet` | `section.all` |

The original row item-builder is `55:0xddbe18..0xde4f5c`: 333 enum cases,
282 unique code blocks. Enum order and generated port section numbers are not
proof of runtime section layout. `settings-entry-builder.asm` exports the separate
conditional builder at `55:0xde9d44..0xdf8778`; all its row predicates have not
been decoded. Section-ID array addresses are preserved, not presented as decoded
sets. The main row builder can add special rows outside this section array.

Localization was recovered by a strict constant/store evaluator, not by matching
nearby strings. It symbolically summarizes only the required Swift calls and
rejects unexpected instructions. Dictionary initializer `55:0x324f5e4` reaches
constructor `0x32620c4`. `0x32624b4` selects Ukrainian index 1, English index 2,
and default/Russian index 0. **All 1,597 three-language entries match the parent's
independent bounded-emulation recovery**, not just selected samples.

`WGLocalization.s` (`55:0x324f240`) checks custom/localization dictionaries before
falling back to these built-ins. Dictionary binding recovery does not establish
the label assigned to every row, or the text of a remote/custom screenshot.

### Original visibility conditions established so far

- Main entry `55:0xe1bd24` calls `55:0xdfd284`; the full menu requires
  `WGBetaAccessStore.state(userId:) == 1` (**allowed**). Core enum descriptor
  `46:0xece894` distinguishes unknown, allowed and denied. The fallback controller
  and every eligibility transition still need recovery.
- The 26-section array contains **no AI category**. AI types/menu cases survive
  in metadata. Routine `46:0x20c724` removes Gemini/Groq configuration and marks
  `wg_aiSectionRetired`. Its existence does not prove invocation in every
  historical installation state. Preserve current user data while deciding
  historical UI compatibility; do not blindly replay a destructive migration.
- The inspected port's `implemented`/`availableOnly` filters suppress unsupported
  categories/rows; the all-settings view substitutes explanatory text. Neither
  behavior reproduces original visibility or closes a missing consumer.

## Verified value/storage contracts

These are **getter contracts** unless stated otherwise. A fallback is not proof
of a slider range. Native constants/selectors are recorded in `native-data-01.json`
and `native-data-02.json`; full machine-readable overrides are in `inventory.json`.

| Property | Original contract | Evidence in image 46 | Current reconciliation needed |
| --- | --- | --- | --- |
| `stickerSizeScale` | Double; loaded zero becomes 1.0 | `0x1f8e28` | Public zero-hides semantics and new appearance hook need explicit migration/integration. |
| `photoCompressionQuality` | Double; loaded zero becomes 0.7 | `0x202784`, constant `0xd62180` | Media reader now 0.7; generated state remains 0.8. Preserve explicitly saved old values. |
| `backCameraPreset` | String fallback `1080p` | `0x200690 -> 0x213448` | New reader uses original strings; earlier AVFoundation strings need aliases. |
| `backCameraFPS` | Int; zero becomes 30 | `0x2008f8` | New reader 30; 24 FPS compatibility is an earlier-port option. |
| `roundVideoBitrate` | String fallback `medium` | `0x200d70` | Current camera writes low/medium/high; archive still permits numeric strings only. |
| `useTelegramCameraSettings` | Absent value examines legacy custom-camera keys | `0x200438` | New reader implements conditional default; not simply always true. |
| `localStarsCount` | Int64; zero becomes 9999 | `0x201828` | Generated type repaired, default zero; new display reader 9999 is uninstalled at index time. |
| `activeWhitegramAccountId` | Optional Int64; missing/invalid becomes nil | `0x1f4768` | Generated UI state is Bool; resolve symbolic UI field and preserve numeric account IDs. |
| `deletedMessagesOpacity` | Double; missing default 0.45; clamp 0.01...1 | `0x204124`, constants `0xd62188/0xd62190` | New history policy matches; generated state is 0.6. |
| `musicPlaybackSpeed` | Double; default 1; clamp 0.1...3 | `0x209aec`, constant `0xd55fa8` | New reader matches; archive permits 0.25...4. |
| `musicCrossfadeEnabled` | Missing value defaults true | `0x209d94`, absent branch `0x209e64` | New reader true; generated state false. |
| `musicCrossfadeDuration` | Int; missing default 3 | `0x209f0c` | New reader 3; generated state 0. Original range not established here. |
| `musicEqualizerBands` | Exactly ten Float values, otherwise ten zeros | `0x20a180` | New reader requires ten; archive accepts 1...32 and different gains. |
| `tabBarScale` | Double; zero becomes 100 | `0x2046dc` | Generated state 1.0; units must be reconciled. |
| `tabBarWidthScale` | Double; zero becomes 100 | `0x204884` | New hook divides percentage by 100; generated state 1.0. |
| `particleSpeed` / `particleDensity` | Int; missing default 1 | `0x208a9c` / `0x208c08` | Generated defaults zero; no connected renderer at index time. |
| `voiceChangerTimbre` / `voiceChangerClarity` | Nonfinite becomes zero; clamp −100...100 | `0x20befc` / `0x20c27c`, helpers `0x212884/0x213060` | Bounds match local controls; acoustic coefficients are not proved. |
| `geminiUseProxy` | Missing value defaults true | `0x20d0f8`, absent branch `0x20d1c4` | Generated default false; unavailable proxy must not silently become Direct. |
| `showSiriTranscriptionWarning` | Getter unconditionally true | `0x20e0d0` | Dismissal is distinct state, not the generated false default. |

`previewRevision` and `activeWhitegramAccountId` have unresolved symbolic UI
field encodings. A generator's fallback to Bool is not evidence for that type.
For the latter, the SGSettings symbol explicitly contains `s5Int64VSg`, and the
getter's Optional discriminator verifies nil behavior. The specific UI field
still requires independent symbolic-reference resolution.

New camera code also records native leads for 4k/1080p/720p, 30/60 FPS,
low/medium/high bitrate mappings and 2560-pixel photo export. Those worker-recovered
consumer contracts are not all independently re-derived by this audit. They must
be checked together with capture device support, MultiCam limits, original output
dimensions, metadata cleanup and legacy queued resources.

## Important semantic differences

### Translation

The original `wg_localTranslationEnabled` path is **Google client-side HTTPS**,
not Apple/offline translation. Independent exports show:

1. `46:0x7d1008` reads that setting and branches according to text/input/tone state.
2. The selected path tails to `0x7d30a8`, which builds a signal for nonempty text.
3. HTTP builder `0x7d3388` constructs `https`, `translate.googleapis.com`,
   `/translate_a/single` (`0x7d3504` / `0x7d351c`).

An Apple provider should use a separate new option. The key name alone must not
change its original network meaning. Current global-target/review-before-send
work is substantive, but original tone/entity/send-state behavior and voice/Siri
flows need dedicated comparison. The services worker located the one-time
`wg_siriTranscriptionWarningDismissed` overlay; this audit independently verified
the always-true getter, not every overlay callsite.

### History, content and privacy

The baseline separate archive preserves received text/metadata, not the original
inline tombstone/edit-entity lifecycle. New Postbox attribute/policy/runtime code
appeared during the audit. Original cache-clear categories, repeated server
delete versus explicit second delete, media ownership and backup codecs require
their own fixtures. Existing capture filters must not be assumed equivalent to
original display rules without tracing those consumers.

Global suppression already has native RPC hooks. New per-chat ghost, read-on-action,
protected-content/spoiler and view-once components require their full native caller
integration. Test global/per-chat priority, queued receipts, discussions, secret
chat service actions, recording, media expiration and Photos failures separately.
`alwaysOnline` cannot certify background execution when iOS suspends the process.

### Plugins, voice and accounts

- Plugin ZIP import and send/request interception are now real code, with runtime
  files imported through the plugin map. The latest hook check passes. Original
  restart/boot lifecycle, language providers, Python/native/web hosts and arbitrary
  screen API compatibility remain separate work. Later contribution APIs were
  added after the row snapshot and are explicitly listed as drift.
- Local voice PCM DSP is not music EQ/crossfade, a remote voice conversion path,
  video/call audio adaptation or selective profanity bleeping. Whole-recording
  beep/silence is an extra opt-in port behavior, not timestamped word censoring.
- Account list/add/switch is not session transfer. New Telethon/tdata/ZIP/Keychain,
  bot authorization, frozen-account and quick-switcher implementations need
  installer/BUILD integration, verified archive fixtures and native authorization.

### Backend: recoverable code versus unavailable state

`https://whitegram.click` at `46:0xdebda0` is a verified literal, **not proof of the
API request root**. New `WhitegramBackendProtocol.swift` uses
`api.whitegram.heypainservice.online`; the original URL-construction/signing flow
must justify that independently. The older reconstructed `WGServerConfig` using
`wg.example.com` is not deployment evidence.

`native-data-02.json` preserves 85 selected route/provider literals and addresses.
Request shape, signing, pinning, cache namespaces and decoder fields are code
contracts that can be recovered. Live account eligibility, signed sessions,
blacklist/scammer datasets, registration data, active announcements, profile
content and station/service availability cannot be inferred from the IPA.

New auth/profile/status/radio/traffic clients are substantive work. Do not claim
their absent native UI or unavailable server data is implemented by a model, an
endpoint constant, a generic request method or a synthetic successful response.
No service was contacted and no user data or credentials were requested.

## Current verification and handoff priorities

Existing offline checks were rerun at **04:16:29–04:16:54 UTC**:

| Check | Result |
| --- | --- |
| Top-level Python source/integration suite | **143 tests; 1 failure, 11 errors** |
| Service parser/contracts | Pass: 16 production + 7 test Swift files; 68 XCTest methods supplied, not run |
| Settings-transfer parser/contracts | Pass: 10 production + 3 test files; 30 XCTest methods supplied, not run |
| Plugin hook composition | Pass: both tested history-capture orders, 24 callsites in 9 files, syntax/unchanged input/anchor rejection |
| Plugin parser | Pass: 18 source/test Swift files |
| Voice source suite | Pass: 13 tests against complete assembled reference |
| Inventory integrity and localization comparison | Pass: all 333/76 identities and all 1,597 language arrays |

The top-level failures are concrete, assigned handoff items:

1. **History:** old in-memory fixtures omit
   `submodules/TelegramCore/Sources/Account/AccountManager.swift`, newly read by
   `_native_retention_patches`. All 11 errors are this `KeyError`. Update fixtures
   and expected paths for the expanded operation; it does not mean the real
   assembled tree lacks the file.
2. **Audio:** `WhitegramPlayerSettingsController.swift` calls the context/state
   convenience initializer without `import PresentationDataUtils`; its source
   integration test fails. Include the corresponding BUILD dependency as needed.

`content_control_patches.py` changed during this test run. Full logs and before/after
hashes are preserved; the run is not certification of every later edit. Earlier
96-test/16-hook-callsite passing results describe an older worktree and are
superseded for current verification. An initial audit logging attempt failed on
Windows console encoding; the logger was fixed and the complete rerun above is
the recorded result.

Parent integration priorities:

1. Fix the two failing check groups and complete current runtime-file maps,
   entrypoints and dependencies. The evidence index enumerates missing installer
   files; later maps must be checked again rather than blindly replaying that list.
2. Exercise the actual complete patch order, particularly shared Network request
   hooks (accounts/plugins), message deletion/edit hooks (history/plugins/content),
   and media/player/appearance changes. A narrow capture-only composition pass
   does not validate all new transformations.
3. Reconcile generated defaults, archive rules, live readers and migrations for
   the verified native contracts. Preserve explicitly saved earlier-port values.
4. Integrate exact main-menu/localization data, then recover outstanding row
   predicates and bindings. Do not inflate coverage with hidden controls or headers.
5. Run parent-owned native Swift/XCTest/IPA checks and feature-specific device
   comparisons. No native build, XCTest execution, app launch or network test was
   performed by this audit worker.

## Reproducibility

All audit scripts are in the role evidence directory and write only new artifacts
there. `prepare_inventory.py` reads native metadata and indexes source mentions;
it does not execute the installer. `validate_inventory.py` joins the explicit
assessment table, validates owner/identity/literal/type references, compares the
independent localization recovery and records source drift. `run_checks.py`
captures existing offline suite logs and fingerprints. `probe.py` verifies the
IPA hash/Info.plist and captures source provenance.

Use new output names on rerun; original evidence and earlier exports remain
unchanged. `audit.json` is the concise handoff, and `inventory.json` owns the
machine-readable remaining work and assignments.
