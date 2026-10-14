# Sender-avatar online indicator

## Implemented overlay

`online_indicator_patches.apply_online_indicator_patches` adds the indicator to
`ChatMessageAvatarHeaderNodeImpl`. `ONLINE_INDICATOR_RUNTIME_FILES` installs
`cleanroom/WhitegramChatOnlineIndicator.swift` in the existing `ChatMessageItemImpl`
module. Both are registered in `compat-12.9.4.py`; the module already declares all
required dependencies.

The `showOnlineDotInChats` switch is connected through `WhitegramPortCapabilities`
and uses the recovered `s.showOnlineDotInChats` label. The existing false default
and archive schema are retained. `WhitegramAppearancePolicy` reads the canonical
value with the existing `wg_showOnlineDotInChats` legacy fallback.

Only eligible sender avatars subscribe: a named `TelegramUser`, no bot info,
not the current account, and not a service peer. Channel/group entities and
custom-letter/hidden-author avatars have no subscription. The ordinary private
chat navigation avatar is outside this patch.

Presence is read through `TelegramEngine.EngineData.Item.Peer.Presence`. Only
`.present(until:)` with `until > now` shows the dot. The signal emits true followed
by false after `until - now` seconds; a newer presence replaces the pending
expiration. Missing, expired, recently-seen, and older statuses emit false.
The first emission is immediate; later Boolean changes animate for 0.2 seconds.

The dot is 11 by 11 points at (23, 23) inside the avatar frame. Its outer ellipse
uses `theme.chatList.itemBackgroundColor`; the inner ellipse uses
`theme.chatList.onlineDotColor`, inset by 1.5 points. Its overlay follows avatar
selection, visibility, insertion/removal scaling, and theme changes.

Lifecycle integration starts subscriptions when the node loads, cancels on
disable/ineligibility/rebinding, and releases subscriptions and notification
observers on deinit. A revision rejects stale callbacks after rebinding.
Preference changes refresh eligibility, and foreground activation resubscribes
to recompute expiration after suspension. These lifecycle protections are port
integration choices; they are not claims of instruction-identical reconstruction.

## Original evidence

Original IPA SHA-256:
`bd6d3a13046d5857c1389e2d794c4c2ca44cee89bb22880004bd77f84fe29837`.

Exports are in
`recovery_20261002/campaign/continuation-20261008/` beside this build repository.
The `wgtool audit-function` exporter verifies that hash before each export.

| Image / function | Evidence |
| --- | --- |
| TelegramCore, image 46, `0x201438` | `showOnlineDotInChats` getter; original key `wg_showOnlineDotInChats` |
| TelegramUI, image 55, `0x157320c` | Eligibility, cached subscribed peer ID, clearing the disposable, engine subscription, `mapToSignal`, `distinctUntilChanged`, main-queue delivery |
| `0x1573678` | `setFrame:` with (23, 23, 11, 11) |
| `0x15736a8` | Future `.present` status emits true, then delayed false; equality with now is offline |
| `0x1573864` | First-emission flag disables initial animation |
| `0x1571a40` | 11-point image; scale and opacity animation; explicit nonanimated hiding |
| `0x1571d90` via `0x15750c0` | Outer ellipse, then 1.5-point inset inner ellipse; chat-list theme fields at offsets `0x20` and `0x120` |
| `0x1571e74` via `0x15750c8` | Animation completion hides according to current state, only when finished |

`inspect-online-dot.py` in the evidence directory independently resolves
selectors (`setFrame:`, `setHidden:`, `addSubnode:`, `CGColor`) and decodes constants
at `0x4945058` (0.2-second duration) and `0x4949050` (0.001 hidden scale).
The audit's recovered `PresentationThemeChatList` field order maps the two color
offsets to `itemBackgroundColor` and `onlineDotColor`.

## Verification (Windows, 2026-10-11)

Using `whitegram-check-env/Scripts/python.exe -B -m unittest discover` with
`-s whitegram/tests`, and `WHITEGRAM_ASSEMBLED_SOURCE` pointing to the read-only
`source-12.9.2` checkout:

- `-p test_online_indicator_patches.py -v`: 5 passed. Pristine and assembled
  source installation, write-free replay, avatar-only scope, early abort on a
  missing late anchor or duplicate target, and Swift syntax parsing.
- `-p test_full_composition.py -v`: 5 passed. Actual installer order, complete
  sequence replay, unchanged parser-error inventory, rejection of malformed
  existing receipt hooks, and unique runtime destinations.
- `-p test_settings_controls.py -v`: 4 passed. Recovered labels and existing
  settings dispatcher/control checks.
- `git diff --check`: passed (Git reported LF/CRLF conversion notices).

These are source/installer checks. No Swift compiler or Xcode is available on
this host; no new IPA was built and no device behavior was verified.

### Native build checkpoint (2026-10-13)

Revision `3625798` completed
[run 38337625690](https://github.com/HVHBIGNAME/ios-build-ci/actions/runs/38337625690).
Source validation, native suites, full app compilation and verified IPA upload
passed. The Windows-only results above remain their original dated checkpoint.

### Pending device checks

1. Install the signed `3625798` build on an iOS device.
2. Toggle the switch with a group/topic sender avatar visible. Verify immediate
   enable/disable; bots, self, service/deleted users, and hidden authors stay clear.
3. Exercise future, equal-to-now, expired, missing, and hidden/recent presence.
   Extend the online timestamp before its old expiration; the old timer must not
   hide the renewed dot.
4. Rapidly toggle the preference/rebind an avatar while updates are queued. Scroll
   away and release the header; ensure observers/subscriptions do not retain it.
5. Switch themes, select messages, hide/show avatars, and inspect story-ring/video
   avatars, including insertion/removal animations.
6. Background past the expiration and resume; verify the dot is recomputed.
