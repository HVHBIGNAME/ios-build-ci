# Integrated Whitegram source port

## Inputs

- Telegram source: `release-12.9.2`, commit `6ad963e5b62d354da79040f388ae2b9132fb17b8`.
- Public WhiteGram delta: `db18308774f863074278feedc4df4507b0fb174e` against `release-12.6.2`.
- Application metadata: version `12.9.4`, build `34639`. The source baseline remains Telegram **12.9.2**.

The build pipeline is `apply-public-overlay.sh` → `compat-12.9.4.py` → validation → `configure.py` → the Telegram Bazel/Xcode build → `postprocess.py`.

`compat-12.9.4.py` installs the clean-room implementations and applies the runtime, public API, appearance, interface, history, plugin-event, Swift syntax, voice and plugin-resource patches. Services and plugin UI implementations are installed under `SettingsUI/Sources/Whitegram/`. Preferences, history capture/storage, plugin event delivery, ghost controls and voice processing belong to TelegramCore; the fork bridge belongs to TelegramUIPreferences; font registration belongs to Display.

## Integration completed

### Privacy and local state

- Ghost controls cover online presence, typing/recording/uploads, ordinary and encrypted read state, discussion/Saved Messages reads, content reads, story views and bulk mention/reaction/poll-read operations.
- Personal mention and reaction/poll requests still produce a local completion value when suppressed. This allows Telegram to clear pending actions and unread tags; no synthetic server PTS is generated.
- Bulk mention operations recheck the setting after fetching a page. Repeated bulk reaction/poll requests check it at subscription time.
- New secret-chat content acknowledgements are omitted when suppressed. Already-queued acknowledgements preserve their protocol sequence slots using no-op service actions on layers 46/73/101/144, or an empty ID vector on layer 8.
- The receipt inventory regression check covers all message/channel/story `read*` calls in TelegramCore except featured-sticker read state. It is a source-coverage check, not a packet-capture test. In-flight requests and activity sent by other clients remain outside these local gates.

### Message archive

- Incoming cloud-message capture, remote deletion/edit updates, local deletion and all four local edit-response variants are connected.
- Original text is captured before mutation/removal. A received message must already be available locally to be archived.
- The archive UI supports filtering, searching, category clearing and JSON import/export. Limits are 2,000 entries, an 8 MiB archive and approximately 8 KiB of text per entry.
- This is a local text/metadata archive. It does not restore Telegram conversations or archive secret-chat/media payloads.
- Transient write failures are tracked separately from invalid archive-load errors and can be retried when taking a snapshot.
- The message context menu opens versions of the selected message, including album members. Per-chat/message queries, attachment metadata, original/capture-time sorting and scoped clearing/export are connected.
- Media-only edits are captured after resolving effective media. Archive files and legacy migration are account-specific; imports preserve the first observation of each version.

### Plugin events and chat appearance

- Plugins can observe incoming, queued, sent, edited/deleted messages and chat visibility. Delivery is account-scoped, bounded, permission-checked and deferred past Postbox commits. These observation callbacks do not cancel or rewrite Telegram operations.
- Recovered settings-page/row registration and current-chat APIs are connected. Dynamic controls have registration replacement, callback invalidation and lifecycle cleanup.
- Seven recovered appearance switches open a native preview/settings screen: borders/color, transparent/semitransparent bubbles, typing/message character counts, service timestamps and business-bot panel visibility. Open chats refresh after changes.
- All new Swift files and patch modules are installed by the assembler. The appearance regression fixtures exercise both unpatched and already-installed sources; plugin hooks reject ambiguous partially patched inputs.

### Settings and menu

- The app initializes the fork-settings bridge before constructing the application UI. Service credential migration is scheduled on a background queue.
- Shared preference changes refresh the corresponding chat/tab/story observers asynchronously on main.
- Main-menu entries now reach the implemented history, plugins, fonts, icons, voice, AI, VirusTotal, account, public-fork and generated settings screens.
- The main menu offers implemented categories. The full recovered catalog remains available with unconnected options represented as informational rows.
- Compact chat-list and compact tab-panel options open the public fork's controls, including its restart notices.
- SettingsUI controllers explicitly import `PresentationDataUtils` for the target's `ItemListController(context:state:)` initializer.

The feature-specific documents describe the supported behavior and remaining limits: [public APIs](PUBLIC_API_REVIEW.md), [appearance](APPEARANCE_PORT.md), [history](HISTORY_PORT.md), [plugins](PLUGIN_RUNTIME.md), [services](SERVICES_PORT.md), and [voice](VOICE_PORT.md). [Feature coverage](FEATURE_COVERAGE.md) audits all 333 catalog rows at starting revision `6d8f529`; its counts deliberately exclude the subsequent history/plugin/appearance work.

## Fresh-tree verification

A new detached worktree was created from the pinned Telegram commit, then processed by `port_public.py --apply`, `compat-12.9.4.py` and `configure.py`.

| Check | Observed result |
| --- | --- |
| Public overlay | 594 files applied; no unresolved conflicts |
| Overlay breakdown | 370 added, 141 merged, 57 ported, 1 restored translation component, 25 reviewed resolutions |
| Separate build metadata | 13 entries handled outside the runtime overlay |
| Fresh compatibility pass | 71 imports and 103 BUILD dependencies added |
| Repeated compatibility pass | Completed successfully; no additional imports/dependencies |
| Python appearance/history/public API/runtime integration | 84 passed, no skips |
| Python voice integration | 13 passed, no skips |
| JavaScript SDK/bootstrap/hooks | 51 passed |
| Full Swift syntax comparison | 210 files; zero additional parser diagnostics against target HEAD |
| Plugin syntax check | 12 implementation/test files parsed |
| Plugin/history patch composition | 16 event callsites; both application orders and repeat checks passed |
| Service syntax/contracts | 9 production and 4 test files passed |
| Tracked patch whitespace | `git diff --check` passed |

The final syntax pass uses tree-sitter 0.25.2 / tree-sitter-swift 0.7.3. `swift_syntax_patches.py` expresses the inherited Objective-C function casts using equivalent local type aliases and parenthesizes optional casts. Empty list-controller arguments use `NSNull()`. These forms avoid parser ambiguities without changing the callback signatures or optional defaults.

Windows verification artifacts are under `%TEMP%\opencode\whitegram-validate-12.9.2`:

- `whitegram-port-report.json`
- `whitegram-runtime-report.json`
- `whitegram-syntax-report.json`

### Repeating local checks

From the build repository, set these variables to the assembled target and pinned public checkout:

```powershell
$env:WHITEGRAM_ASSEMBLED_SOURCE = "<assembled-target>"
$env:WHITEGRAM_PUBLIC_SOURCE = "<public-checkout>"
$env:WHITEGRAM_APPEARANCE_SOURCE = $env:WHITEGRAM_ASSEMBLED_SOURCE
$env:WHITEGRAM_VOICE_SOURCE = $env:WHITEGRAM_ASSEMBLED_SOURCE
$env:WHITEGRAM_VOICE_PUBLIC_SOURCE = $env:WHITEGRAM_PUBLIC_SOURCE
python -B -m unittest discover -s whitegram/tests -p "test_*.py" -v
python -B -m unittest discover -s whitegram/tests/voice -p "test_*.py" -v
node --test whitegram/tests/plugins/bootstrap.test.cjs whitegram/tests/plugins/hooks.test.cjs
python -B whitegram/tests/plugins/check_swift_syntax.py
python -B whitegram/tests/plugins/check_hook_patches.py "$env:WHITEGRAM_ASSEMBLED_SOURCE"
python -B whitegram/tests/services/check_sources.py --target "$env:WHITEGRAM_ASSEMBLED_SOURCE"
python -B whitegram/validate_port.py "$env:WHITEGRAM_ASSEMBLED_SOURCE" --report "<report-directory>/syntax.json"
```

Install the parser pair from `requirements-checks.txt` in the Python environment first.

## Apple build checkpoint

Revision **`0ff81e131933267d2789499eda140188eae49ea8`** successfully completed [run 36661099276](https://github.com/HVHBIGNAME/ios-build-ci/actions/runs/36661099276), including all native service, plugin, history and voice suites, the full app build and IPA upload. Swift and Xcode remain unavailable on the Windows host.

The downloaded unsigned IPA is `C:\coding\telegram\whitegram\build-0ff81e1\WhiteGram.ipa` (73,098,319 bytes), SHA-256 `6e0f2904eb503ccb010f52581c62bd0f70aab6a3a1e288299566df143ce79b77`. Verification confirmed ZIP integrity, arm64, 12.9.4/34639, all six extension identities, 13 alternate icons and exact committed plugin SDK bytes. `whitegram/verify_ipa.py` now performs these checks in CI; Bazel product names such as `WidgetExtension.appex` are correctly distinguished from bundle ID suffixes such as `.Widget`.

### Settings transfer increment

The four settings backup/import actions are connected through the full/searchable catalog. Their explicit port-format archive validates fields before applying partial updates, excludes credentials/runtime state and refreshes public-fork mirrors. `localStarsCount` is corrected to the original `Int64` type with a read migration for earlier Boolean records. See [SETTINGS_TRANSFER_PORT.md](SETTINGS_TRANSFER_PORT.md).

Ten production files and three native test files pass the local syntax/boundary checks. The 29 new settings-transfer XCTest cases require the next macOS run. They are not part of the already downloaded `0ff81e1` IPA.

`.github/workflows/build.yml` runs the Python/JavaScript/source checks and native service, plugin storage/HTTP/preferences/event-hub, history, and voice runners before building the IPA. Every native runner executes even if another fails, then the stage fails if any failed. The Foundation plugin host uses separate TelegramCore and SettingsUI targets to retain the production import boundary. Missing Swift fails the native stage. The source-validation JSON is uploaded as a separate artifact; Bazel outputs are cached across runs.

Run `36517261194` exposed three compile defects corrected and verified by `36661099276`: bounded plugin reads use the older-compatible `InputStream` API; history watching passes `anchor` in the public Postbox signature's order; VirusTotal's SHA-256 field no longer shadows `NSObject.hash`. New increments require their own full builds. On-device checks of privacy packets, archive persistence, plugin lifecycle, appearance, font/icon selection, and recording/preview/send remain to be run.
