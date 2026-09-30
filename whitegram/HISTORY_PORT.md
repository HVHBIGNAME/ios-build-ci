# Connected message history

This slice connects the local archive to Telegram's message context menu, adds
message/chat-scoped browsing, and retains bounded attachment metadata. The source
baseline is Telegram `release-12.9.2`, commit
`6ad963e5b62d354da79040f388ae2b9132fb17b8`; application metadata remains the parent's
`12.9.4` / `34639` integration.

## Parent integration — required

In `compat-12.9.4.py`, add these entries to `cleanroom_files`:

```python
"cleanroom/WhitegramHistoryModels.swift": "submodules/TelegramCore/Sources/WhitegramHistoryModels.swift",
"cleanroom/WhitegramHistoryCapture.swift": "submodules/TelegramCore/Sources/WhitegramHistoryCapture.swift",
"cleanroom/WhitegramHistoryPresentation.swift": "submodules/SettingsUI/Sources/WhitegramHistoryPresentation.swift",
```

The existing `WhitegramHistoryStore.swift` and `WhitegramHistoryController.swift`
install entries must copy their updated contents in the same assembly pass. The
store's model declarations and Telegram capture adapter now live in the two new
TelegramCore files, and the controller shares its rows/detail screen with the new
SettingsUI file. Installing only the two previously mapped files will not compile.

The existing `apply_history_patches(source_root)` invocation applies the new menu
hook as well as the capture hooks. Its current position after the public API and
interface adaptations is suitable. The inspected TelegramCore/SettingsUI targets
glob `Sources/**/*.swift`; TelegramUI already depends on and imports SettingsUI at
the menu hook. All imported modules are already direct dependencies of the inspected
targets.

The existing main-menu call `whitegramHistoryController(context: context)` remains
valid. Additional source-level entry points are:

```swift
whitegramMessageHistoryController(context: context, messageId: message.id)
whitegramHistoryController(context: context, scope: .peer(String(peerId.toInt64())))
whitegramHistoryController(context: context, event: .deleted)
whitegramHistoryController(context: context, event: .edited)
```

The normal message-menu action already calls the first entry point. The parent's
generated-settings `case "history"` can use the event parameter to preselect
`.deleted` for `clearDeletedCache` / `exportDeletedBackup` and `.edited` for
`clearEditedCache`; navigation itself does not clear or export anything. Import is
an account-level action on the archive root. No preference schema change is needed
for this slice.

Include the focused source checks in the parent's source-validation step and run
the Foundation tests on the Apple runner before the application build:

```text
python -B -m unittest discover -s whitegram/tests -p "test_history*.py" -v
python -B whitegram/tests/history/run_native.py
```

`WHITEGRAM_ASSEMBLED_SOURCE` must name the assembled checkout for the source checks.
The source tests are also discoverable by the parent's existing root `test_*.py`
command. `run_native.py` returns **2** when Swift is absent, and stages the exact
production store/models in a disposable SwiftPM package. It does not compile the
Telegram capture adapter or UIKit controllers; those require the application build.

## Original evidence

Evidence root: `C:\coding\telegram\whitegram\whitegram-rebuild`.

| Evidence | What it establishes |
| --- | --- |
| `menu-cases-3.1.1/MENU_CASES.md`, cases 4, 6, 9–14, 16–17 | Deleted/edited switches, received-history saving, history clearing/restoration entry, deleted-backup import/export and separate cache clearing |
| The same menu audit, cases 120–124 | Own/bot exclusions and deleted-message opacity control |
| `recovered-3.1.1/WGRecoveredPreferenceKeys.swift` | Original `wg_showDeletedMessages`, `wg_showEditedOriginalText`, `wg_saveChatHistory`, `wg_saveDeletedMessagesToBackup` keys |
| `recovered-3.1.1/native/TelegramCoreFramework-0/hooks.json`, caller `0x35dbbc`, calls `0x35f170`, `0x35f178`, `0x35f688`, `0x35f690` | Core calls into deleted-message, received-history and deleted-backup settings |
| `recovered-3.1.1/native/TelegramUIFramework-0/hooks.json`, caller `0x8d16b8`, calls `0x8d67f8`–`0x8d697c` | UI checks global history settings and parsed per-chat deleted/edited exclusions |
| The same UI hooks, caller `0x1582b08`, calls `0x1583efc`–`0x15844c4` | Sticker presentation checks deleted/edited and bot settings and constructs date/status arguments with `wgPrefixIcon` |

The recovered catalog explicitly limits these artifacts to symbols, types and call
sites rather than original Swift bodies. They support the original feature intent,
including inline presentation, but do not establish a recoverable archive schema
or complete media-retention algorithm. The schema and message-history menu action
here are clean-room integration choices, not claimed binary-identical UI behavior.

The supplied standalone public checkout at
`C:\Users\Pisun4ik\AppData\Local\Temp\opencode\wg` was absent during this pass.
Native API inspection and patch checks used the read-only assembled
`whitegram-validate-12.9.2` checkout and pristine files read from its pinned Git
commit. Neither source worktree was patched by the tests.

## Implemented behavior

### Native navigation and browsing

- Long-pressing an ordinary cloud message exposes **Message history** / **История
  сообщения**. Telegram already puts the clicked album member first; the action
  uses that message's complete `(peerId, namespace, messageId)` identity and opens
  its archive after the context menu dismisses.
- The action is available even after capture is disabled, so previously saved or
  imported versions remain reachable. An empty history explains the capture limit;
  opening the menu does not invent or capture an older version.
- Service messages, secret/local/scheduled messages and embedded-mode menus are
  excluded by the hook. Telegram's early ad-menu returns retain their own menus.
- The archive root can browse archived chats, showing captured chat names, stable
  peer IDs and matching-version counts. Chat selection preserves the current
  event/search/order filters. A message screen also links to the entire chat archive.
- Received, before-edit and deleted filters combine with text/chat/author/message-ID/
  filename search. They are value-based queries shared by display, export and clear.
- Lists show the original message time and local capture time separately, formatted
  in the UI locale and local time zone, including seconds. Users can sort newest-first
  by either time; message-specific views default to capture order.
- Tapping a record shows its full bounded text, captured author/chat names, local
  revision number, original timestamp, previous edit timestamp when available and
  attachment descriptors. Actions copy text, open all versions of the same message,
  or browse that chat's archive.
- Export and clear affect **all matching versions**, including pages beyond the
  current 100-row page. The clear confirmation freezes the query and names the
  matching count. Import reports the number of newly retained versions.
- A refresh action retries snapshot/write failures. Errors are displayed rather
  than replacing an unreadable archive with an empty one.

### Capture and metadata

- Existing received-update, explicit remote-ID/global-ID deletion and interactive
  local-ID deletion capture sites remain connected. Deletion capture runs before
  Telegram removes the message/resources.
- The remote edit and all four local edit-response variants capture the prior
  version when plain text **or attachment descriptors** change. A same-caption
  file/photo replacement is therefore retained.
- Edit capture runs after Telegram computes `updatedMedia`, including its rule to
  preserve already-unlocked paid content, and before `return .update(...)`. It
  observes the effective update rather than misclassifying that preservation as a
  media replacement.
- File-family metadata includes kind, namespaced media ID, filename, MIME type,
  declared byte size, dimensions and duration when supplied by Telegram. Photo
  metadata includes ID and largest known representation dimensions. Link previews,
  polls and other types get only their supported kind/identifier information.
- Metadata comparison omits file access references, thumbnails, cache state, poll
  votes and reactions. Such updates alone are not archived as media edits.
- Existing enable flags and own/bot capture exclusions continue to gate recording.
  Captures take no network action and do no filesystem I/O on the Postbox transaction
  thread. No Postbox message, resource-removal, read-state, PTS or update-return code
  is suppressed or replaced.

### Persistence, compatibility and isolation

- The registry key includes the normalized account directory **and account peer ID**.
  Each account uses `whitegram-history-<accountPeerId>-v1.json` in its account directory.
  Accounts with overlapping message IDs or even a reused directory get distinct
  stores and files.
- If the account-specific file is absent, a valid owned `whitegram-history-v1.json`
  is renamed to it after bounded decoding and ownership validation. Another account's
  legacy file is left for its owner. An existing account-specific file takes precedence.
- JSON remains version 1 with additive optional fields (`peerTitle`, `authorName`,
  `editedAt`, `textTruncated`, `media`). Old v1 entries decode with unknown metadata,
  not fabricated names or attachment details.
- Capture and import are first-observation-wins for an existing
  `(peer, namespace, message, event, local revision)` key. Replaying an archive neither
  rewrites its recorded text/time nor reports duplicate entries as newly added.
- Both envelope and individual-record account IDs are validated before importing.
  Namespace, canonical identity/key, timestamps and text/metadata bounds are checked
  before modifying the store. Invalid/mixed-account imports leave it unchanged.
- Writes remain serialized, atomic and protected until first device unlock. Snapshot
  flushes pending captures before returning, and transient write failures can be
  retried. Removing an account directory does not cause it to be recreated.
- Limits: 2,000 retained observations, 8 MiB encoded archive, 8 KiB of new text per
  version, 32 attachment descriptors, 512 UTF-8 bytes per saved name and 256 per MIME
  type. New text truncation preserves complete UTF-8 scalars; legacy text retains the
  prior allowance for a replacement character at the boundary. Oldest captures are
  evicted at the bounds. Received and before-edit observations may contain the same
  text because event type is part of the identity.
- Clear/import require a readable archive. A corrupt archive is reported and retained
  for recovery; normal clearing no longer silently discards a load error. After an
  external repair of a latched invalid-load error, reopen the account/app.

## Remaining gaps

- Deleted bubbles are still removed from the native conversation. Deleted versions
  are accessible through the chat archive; inline tombstones, opacity and original
  edited-text rendering have not been ported.
- No media bytes, thumbnails, resource references or media-cache pins are stored.
  Descriptors cannot play or restore an attachment, and Telegram's cache cleanup
  remains active. This is not a full media backup.
- No cloud-history backfill, Telegram conversation restoration, secret-chat capture,
  range/whole-history deletion coverage or reconstruction of never-received versions.
- No rich-text/entity history, poll-option/question history or arbitrary deep media
  serialization. Per-chat hide preferences evidenced by the original hooks are not
  implemented by these browsing filters.
- The archive is a bounded, asynchronous local observation log, not a transactional
  Postbox backup. Crash-before-write loss and multi-device local-revision collisions
  are not resolved by first-observation-wins import.
- UIKit/device behavior and Apple SDK type/link correctness require the parent build.

## Files and verification

| Owned file | Role |
| --- | --- |
| `history_patches.py` | Exact staged capture/menu patches, legacy-hook upgrade, final inventory validation |
| `cleanroom/WhitegramHistoryStore.swift` | Serialized Foundation persistence, migration, account isolation, scoped operations |
| `cleanroom/WhitegramHistoryModels.swift` | Entries, attachment metadata, full message identity, query/sort and UTF-8 bounds |
| `cleanroom/WhitegramHistoryCapture.swift` | TelegramCore/Postbox capture and metadata adapter |
| `cleanroom/WhitegramHistoryController.swift` | Root/chat/message archive browsing and import/export/clear |
| `cleanroom/WhitegramHistoryPresentation.swift` | Localized time/metadata presentation, shared rows and version detail screen |
| `tests/test_history_patches.py` | Read-only source, idempotence, failure atomicity, API and parser checks |
| `tests/history/WhitegramHistoryStoreTests.swift` | 14 native persistence/replay/isolation/limit/failure tests |
| `tests/history/WhitegramHistoryQueryTests.swift` | 5 native scope/search/time-order/UTF-8 tests |
| `tests/history/run_native.py` | Disposable native test host using unmodified production sources |
| `HISTORY_PORT.md` | Evidence, scope and parent integration contract |

Windows checks use
`C:\Users\Pisun4ik\AppData\Local\Temp\opencode\whitegram-check-env\Scripts\python.exe`.
The focused checks compare pristine and assembled source, replay without writes,
reject missing/ambiguous/partly installed hooks before any write, and verify native
mutation/cleanup code is retained. Swift syntax checks cover all five production
files, both native test files and the four patched native files against their
baseline parser diagnostics.

Observed results for this slice:

| Check | Result |
| --- | --- |
| Focused history source/API/replay/failure-atomicity suite | 15 passed, no skips |
| Existing `HistoryIntegrationTests` and `MenuIntegrationTests` | 5 passed, no skips |
| Owned Swift sources and native test sources | 7 parsed, no diagnostics |
| Patched native Swift sources | 4 checked, no additional parser diagnostics |
| Scoped `git diff --check` | Passed |
| Native Foundation runner | Unavailable: Swift missing; exit 2 |

The native runner was invoked and reported that Swift is unavailable. The 19 native
XCTest cases are supplied but **have not executed on this host**; source/parser
checks do not establish their runtime assertions or full iOS compilation.
