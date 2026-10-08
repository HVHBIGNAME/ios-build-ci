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
| Recovery silent WAV and 15-second retry | UI 55: `0x55ac84`, `0x55a640` |
| Persistent one-second watchdog, 1.5-second fallback and WAV | UI 55: `0x582628`, `0x58208c`, `0x58318c` |
| Persistent interruption/reset, secondary-audio hint and lease renewal | UI 55: `0x583510`, `0x583700`, `0x583084`, `0x5833b4` |
| Own-player activity and background service ownership | UI 55: `0x437e6c`, `0x437ed0`, `0x508788`, `0x512d08` |
| Cached media, reply/mention subtitle, communication intent and cached avatar | UI 55: `0x6c1b8`, `0x6cb28`, `0x6cf38`, `0x6e7dc`, `0x6ea08` |
| Custom-emoji presentation normalization | UI 55: `0x6e3e4` |

The constants reader resolves Objective-C selectors as well as numeric data:
`2000.0` is the RAM label's **layer z-position**, not a corner radius.

The 2026-10-08 continuation exports both audio classes, their callers and the
notification helpers under `recovery_20261002/campaign/continuation-20261008/`.
`export-keepalive.py` verifies the same IPA hash and annotates selector references,
import pointers and audio ivar offsets. The native persistent volume constant is
Float32 `0.03` (`0x49534a8`); the PCM samples remain zero. The JPEG quality at
`0x4946cb8` is `0.8`. The separate recovery player uses volume zero.

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
  Cached photo/file previews and sender/group avatars are encoded as JPEG at 0.8;
  no notification-specific media downloads are started. iOS 15 communication
  intents preserve sender, group/topic recipients and images. Earlier systems or
  failed intent updates use a cached avatar attachment when there is no media
  attachment. Temporary copies are disposed after the submission callback.
  Reply-to-self and mention subtitles follow the original Russian/English branch,
  and custom-emoji text receives the original emoji-presentation normalization.
- **Lifecycle:** reservation tickets invalidate callbacks after foregrounding,
  disabling or reading a message. A failed submission can retry; an old callback
  cannot complete a newer reservation. Deduplication follows the recovered
  500-entry reset, and pending submissions have a separate 500-entry admission
  limit. Accepted submissions are included in pending-request cancellation:
  a successful `add` callback does not mean the delayed trigger has fired. Read
  cleanup matches account, peer and message namespace. Persistence exempts
  delivered Whitegram notifications from automatic read cleanup, while already
  read requests still awaiting delivery are cancelled.
- **Background execution:** the master switch, background preference and lifecycle
  jointly control silent one-second, mono, 8 kHz, 16-bit PCM loops. The persistent
  path uses Telegram's managed session, a one-second watchdog, a direct-session
  fallback after 1.5 seconds, and dynamic mixing when other apps play audio. The
  independent recovery path runs only without managed audio and retries every
  15 seconds with mixing enabled. Both resume after interruption end without
  requiring `.shouldResume`. The persistent background lease is renewed on
  expiry and ended on cancellation. Actual media playback and calls suppress
  keepalive acquisition; a yielded managed holder cannot restart over recording.
  `SharedWakeupManager` keeps the primary account's service-task ownership while
  the background gate is on, including recovery gaps. The original worker and
  online-presence policies are preserved.

`system_patches.py` installs eleven production sources and patches `WindowContent`,
`ApplicationContext`, `AppDelegate` and `SharedWakeupManager`. It stages changes
through `SourcePatches`, rejects mixed/duplicate hooks and writes only after all
anchors validate. The normal compatibility installer includes the source map,
patch entrypoint and inferred BUILD dependencies.

## Verification and remaining comparison work

The Python system suite checks syntax, module boundaries, live hook placement,
read-only composition, replay, duplicate anchors and fail-before-write behavior.
The full installer suite also exercises its position among the other feature
patches.

`tests/system/run_native.py` schedules 40 XCTest cases on macOS using copies of the
production Foundation/Darwin sources and audio controller. It tests exact identifiers, stale callbacks,
read isolation, bounded deduplication, defaults, preview policy, pixel placement,
a real process-memory query and AVFoundation decoding of the silent WAV. A
deterministic audio host exercises both retry intervals, a missing managed
callback, fallback failure, recording/call handoff, expired leases, interruption,
reset, late player callbacks and complete destruction. These controller checks
do not simulate the iOS audio daemon or prove background longevity. The
workflow runs this suite before the full Xcode/Bazel IPA build. A Windows syntax
pass is not an Apple compiler or device result.

The original direct-call audit finds the persistence getter in the settings
builder; this port explicitly connects the advertised switch to local read
cleanup. The port also uses generation guards, suspends retries while an explicit
interruption is in progress, prevents direct audio from taking an unrelated
managed session, and uses Telegram's managed temporary-file storage instead of
the original loose temporary JPEG directory. Lock/hidden-preview/secret-media and
media-spoiler guards apply before image/intent enrichment; overlapping text
spoilers are merged before redaction. These are intentional integration guards,
not claims of instruction-for-instruction equivalence.

The 2026-10-07 successful IPA predates the 2026-10-08 corrections. Until a new
native run is recorded, its result must not be used as verification of these files.

Device checks still cover permission denial/provisional authorization, app-lock
previews, mute/topic/account navigation, persistent dismissal, RAM placement under
different status bars, audio handoff/calls, and actual background longevity under
iOS suspension and low-power conditions.
