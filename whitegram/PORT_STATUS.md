# Integrated Whitegram source port

## Inputs

- Telegram source: `release-12.9.2`, commit `6ad963e5b62d354da79040f388ae2b9132fb17b8`.
- Public WhiteGram delta: `db18308774f863074278feedc4df4507b0fb174e` against `release-12.6.2`.
- Application metadata: version `12.9.4`, build `34639`. The source baseline remains Telegram **12.9.2**.

The build pipeline is `apply-public-overlay.sh` → `compat-12.9.4.py` → validation → `configure.py` → the Telegram Bazel/Xcode build → `postprocess.py`.

`compat-12.9.4.py` installs the clean-room implementations and applies the runtime, public API, appearance, interface, history, Swift syntax, voice and plugin-resource patches. Services and plugin implementations are installed under `SettingsUI/Sources/Whitegram/`. Preferences, history storage, ghost controls and voice processing belong to TelegramCore; the fork bridge belongs to TelegramUIPreferences; font registration belongs to Display.

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

### Settings and menu

- The app initializes the fork-settings bridge before constructing the application UI. Service credential migration is scheduled on a background queue.
- Shared preference changes refresh the corresponding chat/tab/story observers asynchronously on main.
- Main-menu entries now reach the implemented history, plugins, fonts, icons, voice, AI, VirusTotal, account, public-fork and generated settings screens.
- The main menu offers implemented categories. The full recovered catalog remains available with unconnected options represented as informational rows.
- Compact chat-list and compact tab-panel options open the public fork's controls, including its restart notices.
- SettingsUI controllers explicitly import `PresentationDataUtils` for the target's `ItemListController(context:state:)` initializer.

The feature-specific documents describe the supported behavior and remaining limits: [public APIs](PUBLIC_API_REVIEW.md), [appearance](APPEARANCE_PORT.md), [plugins](PLUGIN_RUNTIME.md), [services](SERVICES_PORT.md), and [voice](VOICE_PORT.md).

## Fresh-tree verification

A new detached worktree was created from the pinned Telegram commit, then processed by `port_public.py --apply`, `compat-12.9.4.py` and `configure.py`.

| Check | Observed result |
| --- | --- |
| Public overlay | 594 files applied; no unresolved conflicts |
| Overlay breakdown | 370 added, 141 merged, 57 ported, 1 restored translation component, 25 reviewed resolutions |
| Separate build metadata | 13 entries handled outside the runtime overlay |
| Fresh compatibility pass | 71 imports and 103 BUILD dependencies added |
| Repeated compatibility pass | Completed successfully; no additional imports/dependencies |
| Python appearance/public API/runtime integration | 47 passed, no skips |
| Python voice integration | 13 passed, no skips |
| JavaScript SDK/bootstrap | 36 passed |
| Full Swift syntax comparison | 196 files; zero additional parser diagnostics against target HEAD |
| Plugin syntax check | 9 implementation/test files parsed |
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
node --test whitegram/tests/plugins/bootstrap.test.cjs
python -B whitegram/tests/plugins/check_swift_syntax.py
python -B whitegram/tests/services/check_sources.py --target "$env:WHITEGRAM_ASSEMBLED_SOURCE"
python -B whitegram/validate_port.py "$env:WHITEGRAM_ASSEMBLED_SOURCE" --report "<report-directory>/syntax.json"
```

Install the parser pair from `requirements-checks.txt` in the Python environment first.

## Apple build checkpoint

Swift and Xcode are unavailable on this Windows host. Both native runners were invoked and reported the missing toolchain; their runtime assertions have **not** passed locally. No new IPA has been produced by this integration pass.

`.github/workflows/build.yml` now runs the Python/JavaScript/source checks and native service, plugin storage/HTTP/preferences, and voice runners before building the IPA. The Foundation plugin host uses separate TelegramCore and SettingsUI targets to retain the production import boundary. Missing Swift fails the native stage. The source-validation JSON is uploaded as a separate artifact.

The macOS workflow still needs to execute for this revision. Its full app build must establish Apple SDK type correctness, dependencies and linking. UIKit/JavaScriptCore integration and on-device checks of privacy packets, archive persistence, plugin lifecycle, font/icon selection, and recording/preview/send also remain to be run.
