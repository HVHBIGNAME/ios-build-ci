# Settings and local actions checkpoint

Initial base commit: `b80eb28f928430a4bc80e5846c2b46957c1f4bd6`. Native verification and subsequent source increments are qualified below; none establishes full-client parity.

## Native checkpoint: `f738ee1`

The first increment was committed as `6907822`. Native run `38016100878` found two upload-cancellation ordering failures in the existing backend transport. `f738ee1` defers completion until URLSession invalidation and adds early/repeated cancellation coverage. [Run 38017177549](https://github.com/HVHBIGNAME/ios-build-ci/actions/runs/38017177549) then passed the source checks, all native suites, release IPA build and packaged-artifact verification.

Downloaded artifact: `C:/coding/telegram/whitegram/build-f738ee1/WhiteGram.ipa`, **74,709,608 bytes**, SHA-256 `222906ef5269807c0f3696304b6c68588a4b97b6fb6fae5cf82ec268179fc2ef`. Independent local `verify_ipa.py` verification passed CRC, arm64, version/build, all six extension identities, 13 alternate icons and exact committed plugin SDK bytes. This is an unsigned IPA; device interaction/visual parity has not been tested.

The local-only verification statements below describe the initial snapshot before this native checkpoint.

## Following increment: about links and chat-list visibility

- Four recovered `tg://` destinations are now actions in both All Settings/search and About. They use the active account's internal URL resolver. No link is opened automatically and no membership change is performed by the implementation work.
- `hideChatListTitle` and `hideChatListPremiumBadge` now reach both the component title model and legacy title view. A saved legacy `hideChatListPremiumStatus` is also honored. Only the text/status is hidden: the activity, passcode and proxy actions are retained. The original unfiltered title is retained for restoration.
- `hideSponsoredProxyChannel` filters only additional `.proxy` entries; PSA and ordinary chat rows remain. Pin offsets are calculated from the filtered entries. Preferences trigger title/list recomputation without requiring a Postbox update.
- Original evidence: UI `0xe06d84/0xe06e00/0xe06e7c/0xe06ef8` (links), row dispatch `0xe28c78/0xe28c58/0xe28c38/0xe28c18`, UI `0x16b2a4c..0x16b2acc` (component title), `0x1becd58/0x1bed408` (legacy title/status), `0x180e11c` (proxy-only filtering). Exports are in the continuation evidence directory.
- Local validation: **254 Python tests passed** on the assembled candidate; **434 Swift files, zero new parser diagnostics**. Full installer replay passed. These latest changes require a new native run; the `f738ee1` artifact predates them.
- Latest snapshot `routes-f738ee1-worktree2.json`: 123 switches, 76 disclosures, 11 sliders, two checkboxes, four links, one preview, 22 information rows, 29 header descriptors and **65 fallback rows** (57 interactive catalog rows plus eight text/value rows). These remain routing classifications, not a behavioral parity percentage.

## Implemented

- Generic settings now render 11 numeric controls directly: sticker size, tab height/width, JPEG quality, deleted-message opacity, playback speed, local Stars, and four local voice parameters. Values use their existing runtime policies, percentage conversions, finite bounds, and voice-preset reset behavior.
- Front/back camera rows select the actual `videoMessageCamera` preference. Location selection opens the existing map picker; the original location toggle reaches the installed map consumer.
- Media, transfer, player, voice and appearance settings with existing local consumers use direct switches. Mutually exclusive glass/bubble selections use the same atomic change builders as their specialized controllers.
- Search and filtered sections retain populated section headers. Explicit help rows use recovered localization and respect the description preference. The message-preview row renders the existing native chat preview.
- Diagnostics displays actual system/process metrics, copies the report, and exports copies of the available application/short logs through the system share sheet. Export files have a unique temporary directory and remain retained through sharing.
- Unlimited-sticker settings connect all four recent-sticker insertion sites, favorite insertion, and favorite-limit feedback. Original local limits are **999 recent / 9999 favorite**. Default/premium limits are propagated through all three asynchronous favorite-insertion paths. GIF limits and explicit removal paths are preserved. This does not change Telegram's server-side limits or certify cross-device synchronization behavior.
- The message context menu supports local shortening and expansion. Original eligibility is more than 15 newline-separated lines **or** more than 1000 Swift characters. The action keeps the first 15 lines and appends an ellipsis, clipping entities in UTF-16 units. Even a long single line follows this original line-based rule. The persisted message text stays intact; a backward-compatible attribute flag drives rendering. Expansion remains available after the menu setting is disabled. Translation, pending edits, previews and message-option views are protected from incompatible offsets.

## Original evidence

Read-only exports under `recovery_20261002/campaign/continuation-20261008/` verify IPA SHA-256 `bd6d3a13046d5857c1389e2d794c4c2ca44cee89bb22880004bd77f84fe29837` before disassembly:

- `recent-sticker-store.asm`: Core `0x470618..0x470620`, 20 versus 999.
- `favorite-sticker-store.asm`: Core `0x4fb4e8`, 9999 versus supplied limit.
- `favorite-sticker-limit.asm`: Core `0x96ee64..0x96eef0`, local favorite-limit feedback and override.
- `shorten-consumer.asm`: UI `0x312ed0..0x31329c`, newline splitting, 15-line / 1000-character thresholds, persistent expansion and enable flag.
- `shorten-implementation.asm`: UI `0x320314..0x3206ac`, prefix, ellipsis and clipped entities.
- `shorten-transaction-body.asm`: UI `0x3206ac..0x3206f8`, local message-attribute transaction.

The recovered `wh.shortenMenu` string mentions AI, but the inspected action above is a local line-prefix operation. No AI service is invoked or claimed by this implementation.

## Installation and verification

Fresh candidate: `C:/coding/telegram/whitegram/recovery_20261002/candidate-controls-20261009`, checked out at Telegram `6ad963e5b62d354da79040f388ae2b9132fb17b8`.

- Pinned public overlay: **594 files applied**, no discarded hunks.
- Current compatibility installer: completed, including all new Swift sources and both patch modules.
- Python source/integration suite against the fresh candidate: **250 tests passed**.
- Full installer ordering, per-stage replay, and complete-sequence byte-identical replay passed. The shortening insertion uses a separate menu anchor to preserve history and VirusTotal insertions.
- Swift syntax comparison: **431 files, zero new parser diagnostics**.
- Added native regressions to the existing appearance, history and localization runners for sticker bounds, shortening thresholds/entity clipping, and settings filtering. **These native tests have not run on this Windows host; `swiftc` is unavailable.**

Local artifacts:

- `controls-public-report.json`
- `controls-syntax-report.json`
- `routes-b80eb28-worktree1.json` (records changed source paths and hashes)

## Remaining scope

The generic snapshot still contains **72 fallback rows**, including **64 interactive catalog rows** and eight text/value rows. A route or control is not proof of a complete runtime consumer, and a fallback is not proof of absence elsewhere in the app. Current classifications are: 120 switches, 76 disclosures, 11 sliders, two checkboxes, one preview, 22 information rows, 29 header descriptors, and 72 fallbacks.

Remaining investigations include profile/appearance effects and backgrounds, alternative list/header layouts, original icon controls, composer formatting and mixed-script/Zalgo behavior, online/read-date tracking, profile data cards, original about links, and additional screen/plugin contracts from the full inventory. The known inactive original `hideBottomTabBar` must not be relabeled as the public fork's compact panel.

Full Swift/Xcode compilation, original-versus-port device interaction, live backend-dependent behavior, and visual parity are outstanding. This checkpoint must not be described as “all functions completed.”
