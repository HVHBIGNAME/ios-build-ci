# Contact online history

Source increment, 2026-10-16, included in [build 34642](BUILD_34642.md).
Native CI and release compilation passed; physical-device comparison remains pending.

## Recovered observations

The retained 3.1.1 audit indexes `TelegramCoreFramework` as image 46:

- `SGOnlineHistoryEntry` exposes `peerId: Int64`, `peerName: String`, optional
  `peerUsername`, `isOnline`, `isContact` and `timestamp: Double`.
- `SGOnlineHistoryStore.append` at `0x1ea09c` compares a peer's previous online
  state (`0x1ea0f8`–`0x1ea10c`) and skips an unchanged state. Its append path caps
  the array at `0x7d0` (2000) entries and invokes the JSON persistence helper.
- The capture path at `0x9a4b14` checks `Transaction.isPeerContact`, resolves
  the peer's display name and username, takes `Date().timeIntervalSince1970`
  at `0x9a4c1c`–`0x9a4c20`, and appends at `0x9a4c7c`.
- A second capture call is indexed at `0x3622fc`; its complete policy has not
  been revalidated in this increment. Prior research recorded 50-row UI pages.

These are static observations from the retained `audit-full-3.1.1` SQLite
index and `native/image-046.asm.gz`, not device observations. The audit's
original IPA path is currently absent, so fresh SHA verification and fresh
disassembly export could not be performed. The historical audit identifies
IPA SHA-256 `ecc05aeff70eb2cc692ffcc07d0ee9c35a23b39b82b91d0803de1b54a10d0d6d`.

## Installed behavior

- `online_history_patches.py` hooks `updatePeerPresences` (API user responses)
  and `updatePeerPresencesClean` (status updates). Both run after Telegram's
  existing presence merge and pass only the accepted peer IDs. Existing
  min-status handling, own-account exclusion and last-activity merging remain
  in place.
- Capture requires `onlineHistoryEnabled` and contact membership. It records
  explicit API online/offline statuses, using the local observation time.
  Recently/last-week/last-month/empty statuses do not invent offline events.
  Expiry timers and typing activity do not synthesize history.
- `WhitegramOnlineHistoryStore` serializes access, suppresses repeated states
  per peer (also after reload), retains the latest 2000 observations and
  publishes main-thread change notifications. Invalid archives are reported
  and preserved until an explicit clear. Error logging excludes entry data.
- The screen offers name/username/ID search, per-contact selection by tapping
  an event, local-calendar date filtering, day groups, 50-row pages, live
  refresh, an enable switch and account-wide clear with confirmation.
- The generated catalog routes `onlineHistoryEnabled`, `onlineHistoryView`
  and `onlineHistoryClear` to these consumers. `trackLastOnline` and
  `saveReadDates` remain unresolved; this increment does not enable them.

## Deliberate differences and remaining parity work

Storage is account-scoped under `WhitegramOnlineHistory.v1.<accountId>` in
UserDefaults, with a versioned JSON envelope and UUID row identities. The
original shared `wg_onlineHistory_v2` archive is not automatically assigned to
an account or imported. The old enable preference is read as a fallback.
This schema and isolation choice are not claims of original-format parity.
Account logout does not currently purge this separate archive automatically.

The new ItemList screen is a functional reconstruction; exact original layout,
all capture-path policy details, hidden-status behavior and original-format
migration remain unverified. Capturing while the client is suspended or offline
is limited to the updates Telegram actually supplies later.

## Verification

- Root Python suite: **309 passed**, no skips, with the assembled/public source
  environment variables set. Six new checks cover original/assembled patch
  application, replay, no changes to native merge logic, atomic failure,
  drift rejection, source syntax and catalog wiring.
- Seven XCTest cases in `tests/history/WhitegramOnlineHistoryTests.swift` cover
  transition replay/reload, account isolation, cap/filter/page behavior,
  pending-write/clear ordering, corruption preservation, foreign-account
  rejection and invalid observations. The existing history native CI runner
  now includes these actual production store/query sources.
- Native invocation on this Windows host returned **2: Swift unavailable**.
  Subsequently GitHub run `38892851238` passed its native Swift suites (including
  the history runner) and full TelegramCore/SettingsUI release compilation on macOS.
- Catalog routing count: 52 unconnected rows, down from 55. This is not a
  runtime parity or completion percentage.

Device checks after a new native build:

1. Enable capture; exercise online/offline transitions from a test contact.
   Repeated status updates must not duplicate the latest state.
2. Confirm noncontacts, own status and privacy-redacted statuses do not create
   records. Exercise both initial user sync and explicit presence updates.
3. Restart and switch accounts; verify isolation, ordering, filters and pages.
4. Clear from both settings and the history screen; verify all account pages
   are removed, another account is retained, and new events can be recorded.
5. Disable capture, change language/theme and test iPad presentation.

## USB checkpoint

During this session usbmux briefly listed the connected iPhone, but it was
absent by the lockdown/application-version probe and subsequent enumeration.
PnP still listed the Apple USB interfaces. Installed WhiteGram version and
pairing state were not obtained. This does not establish a driver incompatibility
or failed Trust confirmation; earlier pairing-directory checks used wrong paths.
