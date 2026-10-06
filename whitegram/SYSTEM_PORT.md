# RAM and local-notification runtime

## Original evidence

The implementation uses the supplied Whitegram Beta 3.1.1 (12.9.2) IPA with
SHA-256 `bd6d3a13046d5857c1389e2d794c4c2ca44cee89bb22880004bd77f84fe29837`.
Focused exports and the reproducible constants reader are in
`recovery_20261002/campaign/continuation-20261006/` in the local recovery workspace.

| Behavior | Original image and address |
| --- | --- |
| RAM label installation/font/color/layer | UI 55: `0x364b1b8`, `0x364b48c` |
| RAM label padding, timer, sample and placement | UI 55: `0x3646f8c`, `0x364b580`, `0x364b7a8`, `0x364b8d8` |
| Notification admission and 500-entry deduplication | UI 55: `0x6ac74` |
| Notification title/body and request payload | UI 55: `0x6b3ac`, `0x6b878` |
| Notification, background and persistence getters | Core 46: `0x1f7ee0`, `0x1f7fec`, `0x1f8160` |
| Background gate and managed audio acquisition/release | UI 55: `0x581e3c`, `0x58208c`, `0x581fb8` |
| Silent WAV and periodic check | UI 55: `0x55ac84`, `0x55a640` |

The constants reader resolves Objective-C selectors as well as numeric data:
`2000.0` is the RAM label's **layer z-position**, not a corner radius.

## Preferences and UI

| Catalog row | Stored key | Absent-value default |
| --- | --- | --- |
| `showRAMUsage` | `showRAMUsage` | false |
| `whitegramNotifications` | `whitegramNotificationsEnabled` | false |
| `persistentNotifications` | `persistentNotificationsEnabled` | false |
| `backgroundKeepAlive` | `backgroundKeepAlive` | **true** |

Explicit saved values take precedence over the original `wg_` mirrors and defaults.
Enabling notifications invokes the existing application notification-registration
flow. The Notifications menu opens catalog section 11; its information footer uses
the recovered localization entry. The RAM switch is in Miscellaneous.

## Runtime

- **RAM:** `Window1` owns the overlay. It reads `TASK_VM_INFO.phys_footprint`,
  checks the returned word count, truncates bytes to binary MB, and samples every
  second in the common run-loop modes. The label uses nine-point bold monospaced
  digits, original insets/alpha, and pixel-aligned status-bar/safe-area positioning.
  Disabling it stops its timer; window destruction releases its observers/view.
- **Local notifications:** the authorized account's existing notification stream
  feeds each received batch into the system notification center. Admission checks
  foreground state, the native notify flag, incoming/scheduled-self-chat status,
  mute flags and content restrictions. Titles include peer/author/topic context.
  Native message formatting, hidden previews, app lock and spoiler redaction govern
  the body. Requests retain the original `wg_local_<account>_<peer>_<namespace>_<id>`
  identifier, account/peer/message payload and topic grouping, with a 0.1-second
  trigger. Account IDs remain exact strings rather than floating-point numbers.
- **Lifecycle:** reservation tickets invalidate callbacks after foregrounding,
  disabling or reading a message. A failed submission can retry; an old callback
  cannot complete a newer reservation. Deduplication follows the recovered
  500-entry reset, and pending submissions have a separate 500-entry admission
  limit. Read cleanup matches account, peer and message namespace. Persistence
  exempts delivered Whitegram notifications from automatic read cleanup.
- **Background execution:** the master switch, background preference and lifecycle
  jointly control a silent one-second, mono, 8 kHz, 16-bit PCM loop. It uses
  Telegram's managed audio session, yields to other managed audio, handles
  interruption/reset and retries failed starts after 15 seconds. The temporary
  background-task identifier is ended on playback, cancellation or expiration.
  `SharedWakeupManager` keeps the primary account's service/worker connections
  active while background audio is available. Its online-presence policy remains
  the existing foreground/privacy policy.

`system_patches.py` installs eight production sources and patches `WindowContent`,
`ApplicationContext`, `AppDelegate` and `SharedWakeupManager`. It stages changes
through `SourcePatches`, rejects mixed/duplicate hooks and writes only after all
anchors validate. The normal compatibility installer includes the source map,
patch entrypoint and inferred BUILD dependencies.

## Verification and remaining comparison work

The Python system suite checks syntax, module boundaries, live hook placement,
read-only composition, replay, duplicate anchors and fail-before-write behavior.
The full installer suite also exercises its position among the other feature
patches.

`tests/system/run_native.py` runs 21 XCTest cases on macOS using copies of the
production Foundation/Darwin sources. It tests exact identifiers, stale callbacks,
read isolation, bounded deduplication, defaults, preview policy, pixel placement,
a real process-memory query and AVFoundation decoding of the silent WAV. The
workflow runs this suite before the full Xcode/Bazel IPA build. A Windows syntax
pass is not an Apple compiler or device result.

Original communication-intent/avatar/media-attachment enrichment is not yet
ported. The original direct-call audit finds the persistence getter in the settings
builder; this port explicitly connects the advertised switch to local read
cleanup. Those differences must be included in original-versus-port device
comparison rather than counted as complete notification parity.

Device checks still cover permission denial/provisional authorization, app-lock
previews, mute/topic/account navigation, persistent dismissal, RAM placement under
different status bars, audio handoff/calls, and actual background longevity under
iOS suspension and low-power conditions.
