# Profile actions, personal-message emphasis and primary-icon previews

Source increment for build 34643. Native/device verification is pending.

## Original evidence

The original IPA now resides at
`Whitegram Beta 3.1.1 (12.9.2) - no-sub-check.ipa`. REA and a local read-only
probe independently verified its SHA-256 as
`ecc05aeff70eb2cc692ffcc07d0ee9c35a23b39b82b91d0803de1b54a10d0d6d`.
Retained `audit-full-3.1.1` image 55 is TelegramUIFramework.

- `ChatMessageItemView.setupItem` at `0x1640474` checks the deleted-message
  path first. The emphasis branch (`0x1640544`) requires `highlightMentions`
  and Incoming, then checks `ConsumablePersonalMentionMessageAttribute` or a
  `TextMention` for the account's peer ID. It does not search message text.
- The emphasis alpha loads from `0x494ea48`, read directly from the verified
  original Mach-O as **0.55**. The separate semi-transparent-bubble constant
  at `0x49471e8` is **0.7**.
- The original profile-header path at `0x7ff4e0` chooses **72** rather than
  **58** points for the round-action row. Its getter at Core `0x1fa1b8`
  falls back to `roundProfileButtons` when the action setting is absent.
- Recovered localization describes `roundProfileButtons` as a horizontally
  scrolling, reorderable account strip. That feature is distinct and remains
  unimplemented; changing only corner radii would not implement it.

## Implementation

- `WhitegramHistoryRuntime.displayOpacity` preserves deletion-opacity
  precedence, then applies the recovered personal-mention rule. Read/consumed
  state does not remove the metadata match. Nonmatching and outgoing messages
  keep opacity 1.0. Reused items are reset by the existing item setter.
- The existing history-preference signal and display-only stable-version
  invalidation refresh visible items when emphasis is toggled. No message
  text, entities, server version or read state is written by this display path.
- `roundProfileActionButtons` uses a 72-point row with separate circular masks,
  labels below the circles, and geometry recalculated during collapse and
  size changes. Disabling restores the native 58-point layout. The existing
  profile appearance signal includes the new policy flags.
- The action preference has the original unset-parent fallback; an explicit
  false wins. The unsupported account-strip control is not exposed as complete.
- Circle diameter (up to 48 points) and label spacing are reconstruction choices;
  exact original glass rendering, all cover/music combinations and device layout
  comparison remain pending.

## Confirmed preview bug and robustness fixes

The Home Screen primary icon was fixed in 34641, but AppDelegate still supplied
`BlueIcon` as the Default preview in appearance settings. It now supplies
`WhitegramPrimaryPreview`. `primary_icon.py` installs the recovered light/dark
rasters in TelegramUI's image catalog as well as the existing main icon target.
No blue default artwork is substituted into that preview.

Both profile button-width calculations formerly divided by the count even when
it was zero. The new shared calculation returns zero for empty/invalid rows and
does not emit negative widths. This is source-level hardening, not a diagnosis
of the supplied CloudKit crash.

Online-history validation now rejects finite but out-of-calendar-range dates
before they reach the screen's DateFormatter/Calendar. The existing corrupted
archive preservation behavior remains intact.

## Checks and remaining work

- Local root Python suite: **316 passed**, no skips.
- Installation/replay, cross-pass appearance composition, exact native-handler
  preservation, missing/ambiguous-anchor rollback and source syntax are checked.
- The native appearance runner includes recovered alpha/fallback semantics,
  nonmatching/outgoing cases, live-policy invalidation, width conservation,
  zero-count/narrow rows, circular collapse and disabled-layout restoration.
- The history native suite includes an oversized finite-date archive regression.
- Native compilation/tests and physical-device behavior must be recorded after
  they run. Source tests are not evidence that every remaining feature is complete.

All three available user IPS files (October 5, 14 and 15) identify build 34639
and the same CloudKit exception stack. No crash report from build 34642 was
found among those files; the iPhone was unavailable through usbmux during this
increment. The existing disabled-CloudKit build configuration remains required.
